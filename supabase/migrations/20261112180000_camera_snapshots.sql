-- Task 15: foto fija bajo demanda de una cámara, solo para el admin.
--   - El admin pide una foto desde la web (request_camera_snapshot) y consulta el resultado (get_camera_snapshot).
--   - El nodo de visión (llave del salón) ve las solicitudes pendientes, captura un JPEG y lo entrega con
--     submit_camera_snapshot. La imagen vive solo en private.camera_snapshots (una por cámara) y la purga
--     un job de pg_cron cada 5 minutos. Cada vez que el admin ve la imagen queda registrado en audit_log.

-- ---------------------------------------------------------------------------
-- Tablas privadas (PostgREST no las expone)
-- ---------------------------------------------------------------------------

create table private.camera_snapshot_requests (
  id           uuid primary key default gen_random_uuid(),
  camera_id    uuid not null references public.cameras (id) on delete cascade,
  requested_by uuid,
  requested_at timestamptz not null default now(),
  status       text not null default 'pending' check (status in ('pending', 'done', 'failed'))
);
create index camera_snapshot_requests_camera_idx on private.camera_snapshot_requests (camera_id, requested_at desc);

-- Una sola imagen por cámara: cada foto nueva reemplaza la anterior.
create table private.camera_snapshots (
  camera_id  uuid primary key references public.cameras (id) on delete cascade,
  request_id uuid,
  image      bytea not null check (octet_length(image) between 1 and 400000),
  taken_at   timestamptz not null default now()
);

alter table private.camera_snapshot_requests enable row level security;
alter table private.camera_snapshots         enable row level security;
revoke all on private.camera_snapshot_requests, private.camera_snapshots from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin: pide una foto. Si ya hay una pedida hace menos de 20 s, devuelve esa (doble clic, otra pestaña).
-- ---------------------------------------------------------------------------

create or replace function public.request_camera_snapshot(p_camera_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request uuid;
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede pedir fotos de cámaras' using errcode = '42501';
  end if;
  -- Bloquea la cámara para que dos peticiones simultáneas no creen dos solicitudes.
  perform 1 from public.cameras where id = p_camera_id for update;
  if not found then
    raise exception 'cámara desconocida' using errcode = '22023';
  end if;

  select id into v_request from private.camera_snapshot_requests
   where camera_id = p_camera_id and status = 'pending' and requested_at > now() - interval '20 seconds'
   order by requested_at desc limit 1;
  if v_request is not null then
    return v_request;
  end if;

  update private.camera_snapshot_requests set status = 'failed'
   where camera_id = p_camera_id and status = 'pending';
  insert into private.camera_snapshot_requests (camera_id, requested_by)
  values (p_camera_id, (select auth.uid()))
  returning id into v_request;

  insert into public.audit_log (actor_id, action, table_name, record_id)
  values ((select auth.uid()), 'CAMERA_SNAPSHOT_REQUEST', 'cameras', p_camera_id::text);
  return v_request;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin: estado de la solicitud y, si está lista, la imagen en base64 (JPEG).
-- ---------------------------------------------------------------------------

create or replace function public.get_camera_snapshot(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req    private.camera_snapshot_requests%rowtype;
  v_snap   private.camera_snapshots%rowtype;
  v_status text;
  v_image  text := null;
  v_taken  timestamptz := null;
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede ver fotos de cámaras' using errcode = '42501';
  end if;
  select * into v_req from private.camera_snapshot_requests where id = p_request_id;
  if not found then
    raise exception 'solicitud desconocida' using errcode = '22023';
  end if;

  v_status := v_req.status;
  if v_status = 'pending' and v_req.requested_at < now() - interval '60 seconds' then
    v_status := 'expired';
  elsif v_status = 'done' then
    -- Solo la imagen de ESTA solicitud. Si ya se purgó o la reemplazó otra, la foto ya no está disponible.
    select * into v_snap from private.camera_snapshots
     where camera_id = v_req.camera_id and request_id = v_req.id;
    if found then
      v_image := replace(encode(v_snap.image, 'base64'), E'\n', '');
      v_taken := v_snap.taken_at;
      -- Auditoría: una fila por solicitud y persona (no por cada sondeo de la web).
      if not exists (
        select 1 from public.audit_log
         where actor_id = (select auth.uid()) and action = 'CAMERA_SNAPSHOT_VIEW'
           and new_data ->> 'requestId' = v_req.id::text
      ) then
        insert into public.audit_log (actor_id, action, table_name, record_id, new_data)
        values ((select auth.uid()), 'CAMERA_SNAPSHOT_VIEW', 'cameras', v_req.camera_id::text,
                jsonb_build_object('requestId', v_req.id));
      end if;
    else
      v_status := 'expired';
    end if;
  end if;

  return jsonb_build_object('status', v_status, 'image', v_image, 'takenAt', v_taken);
end;
$$;

-- ---------------------------------------------------------------------------
-- Nodo de visión (llave del salón): solicitudes pendientes de su salón, máximo 4.
-- ---------------------------------------------------------------------------

create or replace function public.pending_snapshot_requests()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid := private.authenticate_device();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('requestId', r.id, 'cameraCode', r.code) order by r.requested_at)
      from (
        select req.id, req.requested_at, cam.code
          from private.camera_snapshot_requests req
          join public.cameras cam on cam.id = req.camera_id
         where cam.classroom_id = v_room
           and req.status = 'pending'
           and req.requested_at > now() - interval '60 seconds'
         order by req.requested_at
         limit 4
      ) r
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Nodo de visión (llave del salón): entrega la foto de una solicitud pendiente (o null si falló).
-- ---------------------------------------------------------------------------

create or replace function public.submit_camera_snapshot(p_request_id uuid, p_image text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room  uuid := private.authenticate_device();
  v_req   private.camera_snapshot_requests%rowtype;
  v_bytes bytea;
begin
  if p_request_id is null then
    raise exception 'p_request_id es obligatorio' using errcode = '22023';
  end if;
  select req.* into v_req
    from private.camera_snapshot_requests req
    join public.cameras cam on cam.id = req.camera_id
   where req.id = p_request_id and cam.classroom_id = v_room and req.status = 'pending';
  if not found then
    raise exception 'solicitud desconocida, ya respondida o de otro salón' using errcode = '22023';
  end if;

  if p_image is null then
    update private.camera_snapshot_requests set status = 'failed' where id = p_request_id;
    return;
  end if;

  begin
    v_bytes := decode(p_image, 'base64');
  exception when others then
    raise exception 'imagen con base64 inválido' using errcode = '22023';
  end;
  if octet_length(v_bytes) not between 1 and 400000 then
    raise exception 'la foto debe pesar entre 1 byte y 400 KB' using errcode = '22023';
  end if;
  -- Solo JPEG (firma FF D8 FF), igual que las fotos de registro biométrico.
  if substring(v_bytes from 1 for 3) <> '\xffd8ff'::bytea then
    raise exception 'solo se aceptan fotos JPEG' using errcode = '22023';
  end if;

  insert into private.camera_snapshots (camera_id, request_id, image, taken_at)
  values (v_req.camera_id, v_req.id, v_bytes, now())
  on conflict (camera_id) do update
    set request_id = excluded.request_id, image = excluded.image, taken_at = excluded.taken_at;
  update private.camera_snapshot_requests set status = 'done' where id = p_request_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Purga: cada 5 minutos. Fotos con más de 10 minutos y solicitudes con más de 1 hora.
-- ---------------------------------------------------------------------------

create extension if not exists pg_cron with schema pg_catalog;

create or replace function private.purge_camera_snapshots()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from private.camera_snapshots where taken_at < now() - interval '10 minutes';
  delete from private.camera_snapshot_requests where requested_at < now() - interval '1 hour';
end;
$$;

revoke all on function private.purge_camera_snapshots() from public, anon, authenticated;

select cron.schedule('purge-camera-snapshots', '*/5 * * * *', $$select private.purge_camera_snapshots()$$);

-- ---------------------------------------------------------------------------
-- Permisos: admin (authenticated) pide y consulta; el nodo de visión (anon + llave) responde.
-- ---------------------------------------------------------------------------

revoke all on function public.request_camera_snapshot(uuid)      from public, anon, authenticated;
revoke all on function public.get_camera_snapshot(uuid)          from public, anon, authenticated;
revoke all on function public.pending_snapshot_requests()        from public, anon, authenticated;
revoke all on function public.submit_camera_snapshot(uuid, text) from public, anon, authenticated;
grant execute on function public.request_camera_snapshot(uuid)      to authenticated;
grant execute on function public.get_camera_snapshot(uuid)          to authenticated;
grant execute on function public.pending_snapshot_requests()        to anon;
grant execute on function public.submit_camera_snapshot(uuid, text) to anon;
