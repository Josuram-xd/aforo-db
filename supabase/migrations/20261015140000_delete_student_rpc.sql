-- Supresión de un estudiante (Ley 1581): borrarlo de verdad, incluido su rastro en la auditoría.
-- audit_change guarda la fila completa (nombre, correo, código) en old_data/new_data, así que un DELETE
-- directo dejaba sus datos personales en audit_log. Ahora el único camino es public.delete_student:
--   - borra el estudiante: inscripciones (course_students) y asistencia en cascada; sus eventos se
--     conservan con student_id null, así el aforo y los conteos históricos no cambian;
--   - quita full_name, email y student_code de TODAS sus filas en audit_log (las del propio estudiante
--     y la del DELETE que acaba de escribir el trigger), y deja una fila STUDENT_DELETE sin datos personales.
-- La auditoría sigue siendo de solo lectura para todos; esta función es la única excepción y solo redacta.

-- Quita las llaves personales de un jsonb de auditoría. null sigue siendo null.
create or replace function private.redact_personal(p_data jsonb, p_keys text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p_data is null then null else (p_data - p_keys) || jsonb_build_object('redacted', true) end;
$$;

create or replace function public.delete_student(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_personal constant text[] := array['full_name', 'email', 'student_code'];
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede eliminar estudiantes' using errcode = '42501';
  end if;
  if p_student_id is null then
    raise exception 'p_student_id es obligatorio' using errcode = '22023';
  end if;

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

-- Sin borrado directo: la política y el permiso de DELETE sobre students se retiran.
drop policy if exists "students: admin borra" on public.students;
revoke delete on public.students from authenticated;

revoke all on function private.redact_personal(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.delete_student(uuid)            from public, anon, authenticated;
grant execute on function public.delete_student(uuid) to authenticated;
