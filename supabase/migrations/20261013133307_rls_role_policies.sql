-- Seguridad: permisos de tabla mínimos + políticas RLS por rol (RLS ya está activo desde la migración schema).
--   anon (sin sesión)  -> ninguna tabla; solo ingest_event/camera_heartbeat, que exigen la llave del nodo de visión.
--   viewer             -> aforo de los salones, cámaras, cursos, sesiones y alertas. Sin nombres de estudiantes.
--   teacher            -> lo anterior + estudiantes, eventos y asistencia; gestiona sesiones y resuelve alertas.
--   admin              -> todo, incluidos usuarios, roles y auditoría.
-- Una cuenta desactivada no pasa ninguna política (private.has_any_role exige profiles.is_active);
-- solo puede leer su propio perfil, para que el frontend le muestre que está desactivada.
-- Las políticas usan (select ...) para que Postgres evalúe la función una vez por consulta y no por fila.

-- ---------------------------------------------------------------------------
-- Permisos de tabla (RLS filtra filas encima de esto). anon no recibe nada.
-- ---------------------------------------------------------------------------

grant select on all tables in schema public to authenticated;
grant insert, update, delete on public.courses, public.classrooms, public.cameras, public.students,
                                 public.course_students, public.class_sessions to authenticated;
grant update (resolved_at, resolved_by) on public.alerts   to authenticated;
grant update (full_name, avatar_url)    on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Usuarios
-- ---------------------------------------------------------------------------

create policy "roles: cuentas activas leen" on public.roles
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));

create policy "profiles: ver el propio o admin" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select private.has_any_role('admin')));
create policy "profiles: editar el propio (cuenta activa)" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) and (select private.has_any_role('admin', 'teacher', 'viewer')))
  with check (id = (select auth.uid()));

-- Los cambios de rol van solo por set_user_role.
create policy "user_roles: ver el propio o admin" on public.user_roles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.has_any_role('admin')));

-- ---------------------------------------------------------------------------
-- Catálogos: los lee cualquier rol activo; los administra admin
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['courses', 'classrooms', 'cameras'] loop
    execute format($f$
      create policy "%1$s: roles activos leen" on public.%1$I
        for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
      create policy "%1$s: admin crea" on public.%1$I
        for insert to authenticated with check ((select private.has_any_role('admin')));
      create policy "%1$s: admin edita" on public.%1$I
        for update to authenticated
        using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));
      create policy "%1$s: admin borra" on public.%1$I
        for delete to authenticated using ((select private.has_any_role('admin')));
    $f$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Datos personales (nombres, matrícula): solo teacher y admin leen; admin escribe
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['students', 'course_students'] loop
    execute format($f$
      create policy "%1$s: teacher/admin leen" on public.%1$I
        for select to authenticated using ((select private.has_any_role('admin', 'teacher')));
      create policy "%1$s: admin crea" on public.%1$I
        for insert to authenticated with check ((select private.has_any_role('admin')));
      create policy "%1$s: admin edita" on public.%1$I
        for update to authenticated
        using ((select private.has_any_role('admin'))) with check ((select private.has_any_role('admin')));
      create policy "%1$s: admin borra" on public.%1$I
        for delete to authenticated using ((select private.has_any_role('admin')));
    $f$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Sesiones de clase: las ve cualquier rol activo; las gestionan teacher y admin
-- ---------------------------------------------------------------------------

create policy "class_sessions: roles activos leen" on public.class_sessions
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "class_sessions: teacher/admin crean" on public.class_sessions
  for insert to authenticated with check ((select private.has_any_role('admin', 'teacher')));
create policy "class_sessions: teacher/admin editan" on public.class_sessions
  for update to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher')));
create policy "class_sessions: teacher/admin borran" on public.class_sessions
  for delete to authenticated using ((select private.has_any_role('admin', 'teacher')));

-- ---------------------------------------------------------------------------
-- Operación: eventos y asistencia (identifican personas) solo teacher/admin; los escribe la base de datos
-- ---------------------------------------------------------------------------

create policy "events: teacher/admin leen" on public.events
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));

create policy "attendance: teacher/admin leen" on public.attendance
  for select to authenticated using ((select private.has_any_role('admin', 'teacher')));

-- Alertas: las ve cualquier rol activo; teacher/admin las resuelven (solo a su nombre).
create policy "alerts: roles activos leen" on public.alerts
  for select to authenticated using ((select private.has_any_role('admin', 'teacher', 'viewer')));
create policy "alerts: teacher/admin resuelven" on public.alerts
  for update to authenticated
  using ((select private.has_any_role('admin', 'teacher')))
  with check ((select private.has_any_role('admin', 'teacher'))
              and (resolved_by is null or resolved_by = (select auth.uid())));

-- Auditoría: solo admin la lee; nadie la edita (la escriben triggers y log_access).
create policy "audit_log: admin lee" on public.audit_log
  for select to authenticated using ((select private.has_any_role('admin')));

-- private.device_keys: RLS activo y sin políticas ni permisos -> solo las funciones security definer la usan.

-- ---------------------------------------------------------------------------
-- Tiempo real: el dashboard se suscribe a estos cambios (Realtime aplica las mismas políticas RLS).
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table public.events, public.classrooms, public.cameras, public.alerts;
