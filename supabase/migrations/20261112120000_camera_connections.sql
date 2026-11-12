-- Task 14: conectar las cámaras Tapo desde la web.
-- El admin guarda la IP y la "cuenta de cámara" (la que se crea en la app Tapo); la clave va cifrada en
-- Supabase Vault. Solo el nodo de visión (llave del salón) puede leerla; el navegador nunca la recibe.

create table private.camera_connections (
  camera_id       uuid primary key references public.cameras (id) on delete cascade,
  host            text not null check (host ~ '^[A-Za-z0-9.-]{1,253}$'),
  username        text not null check (char_length(username) between 1 and 64),
  password_secret uuid not null,      -- vault.secrets.id; borrar la cámara deja el secreto huérfano (shortcut: limpiar con clear_camera_connection antes)
  updated_at      timestamptz not null default now()
);
alter table private.camera_connections enable row level security;
revoke all on private.camera_connections from public, anon, authenticated;

-- Admin: guarda o actualiza la conexión. Con p_password nulo conserva la clave anterior.
create or replace function public.set_camera_connection(
  p_camera_id uuid, p_host text, p_username text, p_password text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret uuid;
begin
  if not (select private.has_any_role('admin')) then
    raise exception 'solo un administrador puede conectar cámaras' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cameras where id = p_camera_id) then
    raise exception 'cámara desconocida' using errcode = '22023';
  end if;
  p_host := btrim(p_host);
  p_username := btrim(p_username);
  if p_host is null or p_host !~ '^[A-Za-z0-9.-]{1,253}$' or char_length(coalesce(p_username, '')) not between 1 and 64 then
    raise exception 'IP o usuario inválidos' using errcode = '22023';
  end if;

  select password_secret into v_secret from private.camera_connections where camera_id = p_camera_id;
  if nullif(p_password, '') is null then
    if v_secret is null then
      raise exception 'falta la contraseña de la cámara' using errcode = '22023';
    end if;
  elsif char_length(p_password) > 128 then
    raise exception 'contraseña demasiado larga' using errcode = '22023';
  elsif v_secret is null then
    v_secret := vault.create_secret(p_password, 'camera-' || p_camera_id::text);
  else
    perform vault.update_secret(v_secret, p_password);
  end if;

  insert into private.camera_connections (camera_id, host, username, password_secret)
  values (p_camera_id, p_host, p_username, v_secret)
  on conflict (camera_id) do update
    set host = excluded.host, username = excluded.username,
        password_secret = excluded.password_secret, updated_at = now();
end;
$$;

-- Admin: borra la conexión (y su clave).
create or replace function public.clear_camera_connection(p_camera_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret uuid;
begin
  if not (select private.has_any_role('admin')) then
    raise exception 'solo un administrador puede desconectar cámaras' using errcode = '42501';
  end if;
  delete from private.camera_connections where camera_id = p_camera_id returning password_secret into v_secret;
  if v_secret is not null then delete from vault.secrets where id = v_secret; end if;
end;
$$;

-- Admin: qué cámaras tienen conexión (sin la clave) para mostrarlo en el formulario.
create or replace function public.camera_connections()
returns table (camera_id uuid, host text, username text, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select private.has_any_role('admin')) then
    raise exception 'solo un administrador puede ver las conexiones' using errcode = '42501';
  end if;
  return query select c.camera_id, c.host, c.username, c.updated_at from private.camera_connections c;
end;
$$;

-- Nodo de visión (llave del salón): datos para armar la URL RTSP de cada cámara de su salón.
create or replace function public.camera_sources()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid := private.authenticate_device();
begin
  return coalesce((
    select jsonb_object_agg(cam.code, jsonb_build_object(
             'host', cc.host, 'username', cc.username, 'password', s.decrypted_secret))
      from public.cameras cam
      join private.camera_connections cc on cc.camera_id = cam.id
      join vault.decrypted_secrets s on s.id = cc.password_secret
     where cam.classroom_id = v_room
  ), '{}'::jsonb);
end;
$$;

revoke all on function public.set_camera_connection(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.clear_camera_connection(uuid)                 from public, anon, authenticated;
revoke all on function public.camera_connections()                          from public, anon, authenticated;
revoke all on function public.camera_sources()                              from public, anon, authenticated;
grant execute on function public.set_camera_connection(uuid, text, text, text) to authenticated;
grant execute on function public.clear_camera_connection(uuid)                 to authenticated;
grant execute on function public.camera_connections()                          to authenticated;
grant execute on function public.camera_sources()                              to anon;
