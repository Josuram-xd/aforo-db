-- Auditoría explícita de permisos: cada cambio de rol (user_roles) y cada activación/desactivación de cuenta
-- (profiles.is_active) queda en audit_log con una acción propia y el código del rol, no solo como un
-- INSERT/UPDATE genérico con role_id. Si el cambio lo hace la llave de servicio (Edge Function invite-user,
-- scripts), auth.uid() es null y se usa granted_by como actor.
--   ROLE_GRANT / ROLE_REVOKE / ROLE_CHANGE         table_name = 'user_roles', record_id = user_id
--   ACCOUNT_ACTIVATE / ACCOUNT_DEACTIVATE          table_name = 'profiles',   record_id = id

create or replace function private.audit_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_role text;
  v_new_role text;
  v_user     uuid := coalesce(new.user_id, old.user_id);
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select r.code into v_old_role from public.roles r where r.id = old.role_id;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    select r.code into v_new_role from public.roles r where r.id = new.role_id;
  end if;
  if tg_op = 'UPDATE' and old.role_id = new.role_id and old.user_id = new.user_id then
    return null;
  end if;

  insert into public.audit_log (actor_id, action, table_name, record_id, old_data, new_data)
  values (
    coalesce((select auth.uid()), case when tg_op <> 'DELETE' then new.granted_by end),
    case tg_op when 'INSERT' then 'ROLE_GRANT' when 'DELETE' then 'ROLE_REVOKE' else 'ROLE_CHANGE' end,
    'user_roles',
    v_user::text,
    case when tg_op <> 'INSERT' then jsonb_build_object('user_id', old.user_id, 'role', v_old_role, 'granted_by', old.granted_by) end,
    case when tg_op <> 'DELETE' then jsonb_build_object('user_id', new.user_id, 'role', v_new_role, 'granted_by', new.granted_by) end
  );
  return null;
end;
$$;

create or replace function private.audit_account_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_active is not distinct from new.is_active then
    return null;
  end if;
  insert into public.audit_log (actor_id, action, table_name, record_id, old_data, new_data)
  values (
    (select auth.uid()),
    case when new.is_active then 'ACCOUNT_ACTIVATE' else 'ACCOUNT_DEACTIVATE' end,
    'profiles',
    new.id::text,
    jsonb_build_object('is_active', old.is_active),
    jsonb_build_object('is_active', new.is_active)
  );
  return null;
end;
$$;

-- La auditoría genérica ya no registra is_active de profiles (lo registra audit_account_status) para no duplicar.
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
                        when 'profiles'   then array['is_active', 'updated_at']
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

-- user_roles pasa de la auditoría genérica a la específica de roles (mismo trigger, otra función).
create or replace trigger audit_change
  after insert or update or delete on public.user_roles
  for each row execute function private.audit_role_change();

create trigger audit_account_status
  after update of is_active on public.profiles
  for each row execute function private.audit_account_status();

revoke all on function private.audit_role_change()    from public, anon, authenticated;
revoke all on function private.audit_account_status() from public, anon, authenticated;
revoke all on function private.audit_change()         from public, anon, authenticated;
