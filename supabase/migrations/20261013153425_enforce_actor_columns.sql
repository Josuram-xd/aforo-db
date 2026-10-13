-- Columnas de "quién lo hizo" que no se pueden falsificar desde la API:
--   alerts.resolved_by / resolved_at: la política solo exigía resolved_by null o propio, así que un teacher podía
--     resolver una alerta sin firmarla (resolved_by null), poner cualquier hora o reabrir una alerta ya resuelta.
--     Ahora, para un usuario con sesión, resolver fija resolved_by = auth.uid() y resolved_at = now(), y una
--     alerta resuelta no se puede volver a modificar.
--   class_sessions.created_by: un teacher podía crear o editar sesiones a nombre de otra persona. Ahora se fija
--     a auth.uid() al crear y no cambia al editar.
-- Los procesos del sistema (triggers, pg_cron, llave de servicio) no tienen auth.uid() y no se ven afectados.

create or replace function private.enforce_alert_resolution()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;
  end if;
  if old.resolved_at is not null then
    raise exception 'la alerta ya está resuelta' using errcode = '22023';
  end if;
  if new.resolved_at is null then
    raise exception 'solo se puede resolver la alerta (resolved_at)' using errcode = '22023';
  end if;
  new.resolved_at := now();
  new.resolved_by := v_uid;
  return new;
end;
$$;

create or replace function private.enforce_session_creator()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.created_by := v_uid;
  else
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;

create trigger enforce_alert_resolution
  before update on public.alerts
  for each row execute function private.enforce_alert_resolution();

create trigger enforce_session_creator
  before insert or update on public.class_sessions
  for each row execute function private.enforce_session_creator();

revoke all on function private.enforce_alert_resolution() from public, anon, authenticated;
revoke all on function private.enforce_session_creator()  from public, anon, authenticated;
