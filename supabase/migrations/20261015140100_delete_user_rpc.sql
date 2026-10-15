-- Eliminación de una cuenta de usuario por un administrador, sin dejar sus datos personales en la auditoría.
--   - borra la cuenta en auth.users: identidades, sesiones, perfil y roles se van en cascada;
--   - las referencias a la persona (audit_log.actor_id, alerts.resolved_by, class_sessions.created_by,
--     user_roles.granted_by) quedan en null: lo que hizo sigue registrado, sin decir quién era;
--   - quita email, full_name y avatar_url de las filas de su perfil en audit_log y deja una fila
--     ACCOUNT_DELETE con el rol que tenía (sin correo ni nombre).
-- Un admin no puede borrarse a sí mismo, así que siempre queda al menos un administrador.

-- Los triggers anti-falsificación de 20261013153425 solo deben actuar sobre cambios hechos desde la API
-- (profundidad 1). Al borrar una cuenta, Postgres pone resolved_by/created_by en null con una acción de
-- llave foránea (trigger anidado, profundidad > 1); antes esos triggers lo bloqueaban o lo revertían.
create or replace function private.enforce_alert_resolution()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null or pg_trigger_depth() > 1 then
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
  if v_uid is null or pg_trigger_depth() > 1 then
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

create or replace function public.delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_personal constant text[] := array['email', 'full_name', 'avatar_url'];
  v_role     text;
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede eliminar cuentas' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'p_user_id es obligatorio' using errcode = '22023';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'no puedes eliminar tu propia cuenta' using errcode = '22023';
  end if;

  select r.code into v_role
    from public.user_roles ur join public.roles r on r.id = ur.role_id
   where ur.user_id = p_user_id
   order by case r.code when 'admin' then 3 when 'teacher' then 2 else 1 end desc
   limit 1;

  delete from auth.users where id = p_user_id;
  if not found then
    raise exception 'usuario desconocido' using errcode = '22023';
  end if;

  update public.audit_log
     set old_data = private.redact_personal(old_data, v_personal),
         new_data = private.redact_personal(new_data, v_personal)
   where table_name = 'profiles'
     and record_id = p_user_id::text;

  insert into public.audit_log (actor_id, action, table_name, record_id, old_data)
  values ((select auth.uid()), 'ACCOUNT_DELETE', 'profiles', p_user_id::text,
          jsonb_build_object('role', v_role));
end;
$$;

revoke all on function private.enforce_alert_resolution() from public, anon, authenticated;
revoke all on function private.enforce_session_creator()  from public, anon, authenticated;
revoke all on function public.delete_user(uuid)           from public, anon, authenticated;
grant execute on function public.delete_user(uuid) to authenticated;
