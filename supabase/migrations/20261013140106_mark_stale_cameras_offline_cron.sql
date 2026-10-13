-- Cámaras sin latido: si el nodo de visión se apaga o pierde la red deja de llamar a camera_heartbeat y
-- las cámaras se quedaban "online" para siempre. Un job de pg_cron revisa cada minuto y marca offline las
-- cámaras cuyo último latido tiene más de 90 s (el nodo late cada 30 s), abriendo la alerta camera_offline.
-- La alerta se abre con la misma función que usa camera_heartbeat, y se cierra sola con el siguiente latido online.

-- Abre (si no hay una abierta) la alerta camera_offline de una cámara. La comparten camera_heartbeat y el job.
create or replace function private.open_camera_offline_alert(p_camera_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.alerts (classroom_id, camera_id, type, severity, message)
  select c.classroom_id, c.id, 'camera_offline', 'warning', format('La cámara "%s" está desconectada', c.name)
    from public.cameras c
   where c.id = p_camera_id
  on conflict (camera_id) where type = 'camera_offline' and resolved_at is null do nothing;
end;
$$;

-- Marca offline las cámaras online sin latido en los últimos p_stale_seconds segundos y abre su alerta.
-- Devuelve cuántas cámaras marcó (queda en cron.job_run_details).
create or replace function private.mark_stale_cameras_offline(p_stale_seconds integer default 90)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_camera uuid;
  v_count  integer := 0;
begin
  if p_stale_seconds is null or p_stale_seconds < 30 then
    raise exception 'p_stale_seconds debe ser al menos 30' using errcode = '22023';
  end if;

  for v_camera in
    update public.cameras
       set status = 'offline'
     where status = 'online'
       and (last_seen_at is null or last_seen_at < now() - make_interval(secs => p_stale_seconds))
    returning id
  loop
    perform private.open_camera_offline_alert(v_camera);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- camera_heartbeat usa la misma función para abrir la alerta (mismo mensaje y misma deduplicación).
create or replace function public.camera_heartbeat(p_camera_code text, p_online boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room   uuid := private.authenticate_device();
  v_camera public.cameras%rowtype;
begin
  if p_camera_code is null or p_online is null then
    raise exception 'latido inválido: p_camera_code y p_online son obligatorios' using errcode = '22023';
  end if;

  update public.cameras
     set status       = case when p_online then 'online' else 'offline' end,
         last_seen_at = case when p_online then now() else last_seen_at end
   where classroom_id = v_room and code = p_camera_code
  returning * into v_camera;

  if v_camera.id is null then
    raise exception 'cámara desconocida: %', left(p_camera_code, 50) using errcode = '22023';
  end if;

  if p_online then
    update public.alerts set resolved_at = now()
     where camera_id = v_camera.id and type = 'camera_offline' and resolved_at is null;
  else
    perform private.open_camera_offline_alert(v_camera.id);
  end if;

  return jsonb_build_object('camera', v_camera.code, 'status', v_camera.status, 'lastSeenAt', v_camera.last_seen_at);
end;
$$;

revoke all on function private.open_camera_offline_alert(uuid)       from public, anon, authenticated;
revoke all on function private.mark_stale_cameras_offline(integer)    from public, anon, authenticated;
revoke all on function public.camera_heartbeat(text, boolean)          from public, anon, authenticated;
grant execute on function public.camera_heartbeat(text, boolean)       to anon;

-- Cada minuto. Reprogramar con el mismo nombre lo actualiza.
select cron.schedule('mark-stale-cameras-offline', '* * * * *', $$select private.mark_stale_cameras_offline(90)$$);
