-- Task 12: el profesor gestiona cursos y estudiantes desde la app, con foto opcional y registro biométrico.
--   - teacher y admin crean/editan cursos y estudiantes e inscriben estudiantes en cursos (admin sigue
--     siendo el único que borra cursos, salones y cámaras).
--   - teacher y admin eliminan estudiantes (RPC delete_student, que redacta la auditoría).
--   - foto opcional: bucket privado "student-photos" (solo teacher/admin) + students.photo_path.
--   - biometría: la web sube 3-8 fotos del rostro a private.enrollment_captures; el nodo de visión las pide
--     con su llave de dispositivo, calcula el embedding EN LOCAL y confirma con complete_enrollment, que
--     BORRA las fotos. Los embeddings nunca llegan a la base de datos.

-- ---------------------------------------------------------------------------
-- Columnas nuevas de students
-- ---------------------------------------------------------------------------

alter table public.students
  add column photo_path text check (char_length(photo_path) <= 200),
  add column enrollment_status text not null default 'none'
    check (enrollment_status in ('none', 'pending', 'enrolled', 'failed')),
  add column enrollment_updated_at timestamptz;

-- Con permisos por columna, un profesor no puede marcar a un estudiante como "enrolled" a mano
-- ni tocar presence/last_event_at (los escriben triggers y RPCs security definer).
revoke insert, update on public.students from authenticated;
grant insert (full_name, student_code, email, photo_path) on public.students to authenticated;
grant update (full_name, student_code, email, is_active, photo_path) on public.students to authenticated;

-- ---------------------------------------------------------------------------
-- Políticas: teacher y admin gestionan cursos, estudiantes e inscripciones
-- ---------------------------------------------------------------------------

drop policy "courses: admin crea" on public.courses;
drop policy "courses: admin edita" on public.courses;
create policy "courses: teacher/admin crean" on public.courses
  for insert to authenticated with check ((select private.has_any_role('admin', 'teacher')));
create policy "courses: teacher/admin editan" on public.courses
  for update to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher')));

drop policy "students: admin crea" on public.students;
drop policy "students: admin edita" on public.students;
create policy "students: teacher/admin crean" on public.students
  for insert to authenticated with check ((select private.has_any_role('admin', 'teacher')));
create policy "students: teacher/admin editan" on public.students
  for update to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher')));

drop policy "course_students: admin crea" on public.course_students;
drop policy "course_students: admin edita" on public.course_students;
drop policy "course_students: admin borra" on public.course_students;
create policy "course_students: teacher/admin crean" on public.course_students
  for insert to authenticated with check ((select private.has_any_role('admin', 'teacher')));
create policy "course_students: teacher/admin borran" on public.course_students
  for delete to authenticated using ((select private.has_any_role('admin', 'teacher')));

-- ---------------------------------------------------------------------------
-- delete_student: ahora también para teacher
-- ---------------------------------------------------------------------------

create or replace function public.delete_student(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_personal constant text[] := array['full_name', 'email', 'student_code', 'photo_path'];
begin
  if not private.has_any_role('admin', 'teacher') then
    raise exception 'solo un administrador o profesor puede eliminar estudiantes' using errcode = '42501';
  end if;
  if p_student_id is null then
    raise exception 'p_student_id es obligatorio' using errcode = '22023';
  end if;

  -- enrollment_captures se borra en cascada: no queda ninguna foto de rostro pendiente.
  delete from public.students where id = p_student_id;
  if not found then
    raise exception 'estudiante desconocido' using errcode = '22023';
  end if;

  update public.audit_log
     set old_data = private.redact_personal(old_data, v_personal),
         new_data = private.redact_personal(new_data, v_personal)
   where table_name = 'students'
     and record_id = p_student_id::text;

  insert into public.audit_log (actor_id, action, table_name, record_id)
  values ((select auth.uid()), 'STUDENT_DELETE', 'students', p_student_id::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- Foto opcional del estudiante: bucket privado, solo teacher/admin
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('student-photos', 'student-photos', false, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "student-photos: teacher/admin leen" on storage.objects
  for select to authenticated
  using (bucket_id = 'student-photos' and (select private.has_any_role('admin', 'teacher')));
create policy "student-photos: teacher/admin suben" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'student-photos' and (select private.has_any_role('admin', 'teacher')));
create policy "student-photos: teacher/admin reemplazan" on storage.objects
  for update to authenticated
  using (bucket_id = 'student-photos' and (select private.has_any_role('admin', 'teacher')))
  with check (bucket_id = 'student-photos' and (select private.has_any_role('admin', 'teacher')));
create policy "student-photos: teacher/admin borran" on storage.objects
  for delete to authenticated
  using (bucket_id = 'student-photos' and (select private.has_any_role('admin', 'teacher')));

-- ---------------------------------------------------------------------------
-- Registro biométrico: fotos temporales que solo lee el nodo de visión
-- ---------------------------------------------------------------------------

create table private.enrollment_captures (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  image      bytea not null check (octet_length(image) between 1000 and 400000),
  created_at timestamptz not null default now()
);
create index enrollment_captures_student_idx on private.enrollment_captures (student_id);
alter table private.enrollment_captures enable row level security;
revoke all on private.enrollment_captures from public, anon, authenticated;

-- La web envía 3-8 fotos JPEG en base64 (ya reducidas en el navegador). Reemplaza un envío anterior.
create or replace function public.submit_enrollment(p_student_id uuid, p_images text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_img   text;
  v_bytes bytea;
begin
  if not private.has_any_role('admin', 'teacher') then
    raise exception 'solo un administrador o profesor puede registrar biometría' using errcode = '42501';
  end if;
  if coalesce(array_length(p_images, 1), 0) not between 3 and 8 then
    raise exception 'se esperan entre 3 y 8 fotos' using errcode = '22023';
  end if;
  if not exists (select 1 from public.students where id = p_student_id and is_active) then
    raise exception 'estudiante desconocido o inactivo' using errcode = '22023';
  end if;

  delete from private.enrollment_captures where student_id = p_student_id;
  foreach v_img in array p_images loop
    begin
      v_bytes := decode(v_img, 'base64');
    exception when others then
      raise exception 'foto con formato incorrecto' using errcode = '22023';
    end;
    -- Solo JPEG (firma FF D8 FF): el navegador exporta canvas.toBlob('image/jpeg').
    if substring(v_bytes from 1 for 3) <> '\xffd8ff'::bytea then
      raise exception 'solo se aceptan fotos JPEG' using errcode = '22023';
    end if;
    insert into private.enrollment_captures (student_id, image) values (p_student_id, v_bytes);
  end loop;

  update public.students
     set enrollment_status = 'pending', enrollment_updated_at = now()
   where id = p_student_id;
  insert into public.audit_log (actor_id, action, table_name, record_id)
  values ((select auth.uid()), 'ENROLLMENT_SUBMIT', 'students', p_student_id::text);
end;
$$;

-- Nodo de visión: hasta 3 estudiantes pendientes con sus fotos (base64). Las fotos siguen en la base
-- hasta que complete_enrollment las borre, así un fallo del nodo no pierde el registro.
create or replace function public.pending_enrollments()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid := private.authenticate_device();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('studentId', s.id, 'images', imgs.images))
      from (
        select id from public.students
         where enrollment_status = 'pending'
         order by enrollment_updated_at
         limit 3
      ) s
      cross join lateral (
        select jsonb_agg(encode(c.image, 'base64') order by c.created_at) as images
          from private.enrollment_captures c
         where c.student_id = s.id
      ) imgs
     where imgs.images is not null
  ), '[]'::jsonb);
end;
$$;

-- Nodo de visión: resultado del registro. Borra SIEMPRE las fotos; el embedding queda solo en el nodo.
create or replace function public.complete_enrollment(p_student_id uuid, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid := private.authenticate_device();
begin
  if p_student_id is null or p_ok is null then
    raise exception 'p_student_id y p_ok son obligatorios' using errcode = '22023';
  end if;
  delete from private.enrollment_captures where student_id = p_student_id;
  update public.students
     set enrollment_status = case when p_ok then 'enrolled' else 'failed' end,
         enrollment_updated_at = now()
   where id = p_student_id and enrollment_status = 'pending';
end;
$$;

revoke all on function public.submit_enrollment(uuid, text[]) from public, anon, authenticated;
revoke all on function public.pending_enrollments()           from public, anon, authenticated;
revoke all on function public.complete_enrollment(uuid, boolean) from public, anon, authenticated;
grant execute on function public.submit_enrollment(uuid, text[]) to authenticated;
-- Solo el nodo de visión (publishable key + X-Device-Key, rol anon).
grant execute on function public.pending_enrollments()              to anon;
grant execute on function public.complete_enrollment(uuid, boolean) to anon;
