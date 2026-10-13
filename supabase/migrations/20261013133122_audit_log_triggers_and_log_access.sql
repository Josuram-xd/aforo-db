-- Auditoría: quién cambió qué (triggers) y quién vio o exportó datos sensibles (RPC log_access).
-- audit_log solo lo lee admin; nadie lo puede editar desde la API.

-- Escribe una fila por cada INSERT/UPDATE/DELETE en las tablas de catálogo. No audita los cambios
-- automáticos de contadores y estados (aforo, presence, latidos de cámara), que llegan con cada evento.
create or replace function private.audit_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_ignored text[] := case tg_table_name
                        when 'classrooms' then array['current_occupancy', 'occupancy_updated_at', 'updated_at']
                        when 'students'   then array['presence', 'last_event_at', 'updated_at']
                        when 'cameras'    then array['status', 'last_seen_at', 'updated_at']
                        else array['updated_at']
                      end;
begin
  if tg_op = 'UPDATE' and (v_old - v_ignored) = (v_new - v_ignored) then
    return null;
  end if;

  insert into public.audit_log (actor_id, action, table_name, record_id, old_data, new_data)
  values (
    (select auth.uid()),
    tg_op,
    tg_table_name,
    coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'student_id'),
    v_old,
    v_new
  );
  return null;
end;
$$;

revoke all on function private.audit_change() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'user_roles', 'courses', 'classrooms', 'cameras', 'students',
                           'course_students', 'class_sessions', 'alerts'] loop
    execute format(
      'create trigger audit_change after insert or update or delete on public.%I '
      'for each row execute function private.audit_change()', t);
  end loop;
end $$;

-- Registro de accesos desde el dashboard: iniciar/cerrar sesión, ver estudiantes, exportar eventos.
-- Solo para cuentas activas; p_resource es un texto corto (ej. 'students', 'events.csv').
create or replace function public.log_access(p_action text, p_resource text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not private.has_any_role('admin', 'teacher', 'viewer') then
    raise exception 'se requiere una sesión activa' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('LOGIN', 'LOGOUT', 'VIEW', 'EXPORT') then
    raise exception 'acción no permitida: %', left(p_action, 20) using errcode = '22023';
  end if;
  insert into public.audit_log (actor_id, action, table_name)
  values ((select auth.uid()), p_action, left(p_resource, 100));
end;
$$;

revoke all on function public.log_access(text, text) from public, anon, authenticated;
grant execute on function public.log_access(text, text) to authenticated;
