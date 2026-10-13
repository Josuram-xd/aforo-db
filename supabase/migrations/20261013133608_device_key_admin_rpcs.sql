-- Administración de llaves de dispositivo (scripts/create_device_key.py). Solo service_role puede llamarlas:
-- private.device_keys no está expuesto por la API, así que el script pasa por estas dos RPCs.
-- Nunca reciben la llave en claro: solo su hash SHA-256 (hex).

create or replace function public.admin_register_device_key(p_classroom_name text, p_label text, p_key_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid;
  v_id   uuid;
begin
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'p_key_hash debe ser un SHA-256 en hexadecimal (64 caracteres)' using errcode = '22023';
  end if;
  select id into v_room from public.classrooms where name = p_classroom_name;
  if v_room is null then
    raise exception 'salón desconocido: %', left(p_classroom_name, 100) using errcode = '22023';
  end if;

  insert into private.device_keys (classroom_id, label, key_hash)
  values (v_room, coalesce(nullif(left(p_label, 100), ''), 'aforo-vision'), p_key_hash)
  returning id into v_id;
  return v_id;
end;
$$;

-- Revoca todas las llaves activas del salón (por ejemplo, si se filtró la llave). Devuelve cuántas revocó.
create or replace function public.admin_revoke_device_keys(p_classroom_name text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update private.device_keys k
     set revoked_at = now()
    from public.classrooms c
   where c.id = k.classroom_id and c.name = p_classroom_name and k.revoked_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.admin_register_device_key(text, text, text) from public, anon, authenticated;
revoke all on function public.admin_revoke_device_keys(text)              from public, anon, authenticated;
grant execute on function public.admin_register_device_key(text, text, text) to service_role;
grant execute on function public.admin_revoke_device_keys(text)              to service_role;
