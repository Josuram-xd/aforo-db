-- Seguridad: Row Level Security en todas las tablas y permisos mínimos por rol.
--   anon (sin sesión)  -> no lee ni escribe ninguna tabla; solo puede llamar ingest_event/camera_heartbeat,
--                         que exigen la llave del nodo de visión.
--   viewer             -> aforo de los salones, cámaras, sesiones y alertas. Sin nombres de estudiantes.
--   teacher            -> lo anterior + estudiantes, eventos y asistencia; gestiona sesiones y resuelve alertas.
--   admin              -> todo, incluidos usuarios, roles y auditoría.

-- ---------------------------------------------------------------------------
-- Permisos de tabla (RLS filtra filas encima de esto)
-- ---------------------------------------------------------------------------

revoke all on all tables    in schema public  from anon, authenticated;
revoke all on all functions in schema public  from public, anon, authenticated;
revoke all on all tables    in schema private from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;

grant usage on schema private to authenticated;
grant execute on function private.has_any_role(text[]) to authenticated;

grant select on all tables in schema public to authenticated;
grant insert, update, delete on public.courses, public.classrooms, public.cameras, public.students,
                                 public.course_students, public.class_sessions to authenticated;
grant update (resolved_at, resolved_by) on public.alerts to authenticated;
grant update (full_name, avatar_url) on public.profiles to authenticated;

grant execute on function public.ingest_event(jsonb)            to anon, authenticated;
grant execute on function public.camera_heartbeat(text, boolean) to anon, authenticated;
grant execute on function public.log_access(text, text)          to authenticated;
grant execute on function public.set_user_role(uuid, text)       to authenticated;
grant execute on function public.set_user_active(uuid, boolean)  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.roles           enable row level security;
alter table public.profiles        enable row level security;
alter table public.user_roles      enable row level security;
alter table public.courses         enable row level security;
alter table public.classrooms      enable row level security;
alter table public.cameras         enable row level security;
alter table public.students        enable row level security;
alter table public.course_students enable row level security;
alter table public.class_sessions  enable row level security;
alter table public.events          enable row level security;
alter table public.attendance      enable row level security;
alter table public.alerts          enable row level security;
alter table public.audit_log       enable row level security;
alter table private.device_keys    enable row level security;

-- roles: catálogo visible para cualquier cuenta con sesión.
create policy "roles: leer con sesión" on public.roles
  for select to authenticated using (true);

-- profiles: cada quien ve y edita su perfil; admin ve todos.
create policy "profiles: ver el propio o admin" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select private.has_any_role('admin')));
create policy "profiles: editar el propio" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- user_roles: cada quien ve su rol; admin ve todos (los cambios van por set_user_role).
create policy "user_roles: ver el propio o admin" on public.user_roles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.has_any_role('admin')));

-- Catálogos operativos: los ve cualquier rol activo; los administra admin.
create policy "courses: leer" on public.courses
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "courses: admin escribe" on public.courses
  for all to authenticated
  using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));

create policy "classrooms: leer" on public.classrooms
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "classrooms: admin escribe" on public.classrooms
  for all to authenticated
  using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));

create policy "cameras: leer" on public.cameras
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "cameras: admin escribe" on public.cameras
  for all to authenticated
  using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));

-- Sesiones de clase: las ve cualquier rol; las crean/editan teacher y admin.
create policy "class_sessions: leer" on public.class_sessions
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "class_sessions: teacher/admin escriben" on public.class_sessions
  for all to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher')));

-- Datos personales (nombres, eventos, asistencia): solo teacher y admin.
create policy "students: teacher/admin leen" on public.students
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));
create policy "students: admin escribe" on public.students
  for all to authenticated
  using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));

create policy "course_students: teacher/admin leen" on public.course_students
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));
create policy "course_students: admin escribe" on public.course_students
  for all to authenticated
  using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));

create policy "events: teacher/admin leen" on public.events
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));

create policy "attendance: teacher/admin leen" on public.attendance
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));

-- Alertas: las ve cualquier rol; teacher/admin las marcan como resueltas.
create policy "alerts: leer" on public.alerts
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "alerts: teacher/admin resuelven" on public.alerts
  for update to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher')));

-- Auditoría: solo admin la lee; nadie la edita (la escriben triggers y log_access).
create policy "audit_log: admin lee" on public.audit_log
  for select to authenticated using ((select private.has_any_role('admin')));

-- private.device_keys: sin políticas -> nadie con sesión la ve; solo las funciones security definer.

-- ---------------------------------------------------------------------------
-- Tiempo real: el dashboard se suscribe a estos cambios (Realtime respeta RLS).
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table public.events, public.classrooms, public.cameras, public.alerts;
