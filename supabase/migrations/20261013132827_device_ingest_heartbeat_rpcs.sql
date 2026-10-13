-- RPCs del nodo de visión (aforo-vision). Se llaman sin sesión de usuario (rol anon) con dos headers:
--   apikey: <publishable key>        X-Device-Key: <llave del salón>
-- Errores (PostgREST los traduce a HTTP): 22023 -> 400, 28000 -> 403, PT429 -> 429.

-- Valida la llave del nodo de visión (header X-Device-Key) y aplica un límite de peticiones por minuto.
-- Devuelve el salón al que pertenece la llave. Si se supera el límite, la excepción revierte también el
-- incremento del contador, así que la llave sigue bloqueada hasta que termine la ventana de un minuto.
create or replace function private.authenticate_device(p_max_per_minute integer default 120)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key   text := nullif(current_setting('request.headers', true)::json ->> 'x-device-key', '');
  v_room  uuid;
  v_count integer;
begin
  if v_key is null or char_length(v_key) > 200 then
    raise exception 'falta el header X-Device-Key o no es válido' using errcode = '28000';
  end if;

  update private.device_keys
     set window_count = case when window_start < now() - interval '1 minute' then 1 else window_count + 1 end,
         window_start = case when window_start < now() - interval '1 minute' then now() else window_start end,
         last_used_at = now()
   where key_hash = encode(extensions.digest(v_key, 'sha256'), 'hex')
     and revoked_at is null
  returning classroom_id, window_count into v_room, v_count;

  if v_room is null then
    raise exception 'llave de dispositivo inválida' using errcode = '28000';
  end if;
  if v_count > p_max_per_minute then
    -- PTxxx: PostgREST responde con ese código HTTP (429 -> aforo-vision reintenta más tarde).
    raise exception 'demasiadas peticiones, espera un minuto' using errcode = 'PT429';
  end if;
  return v_room;
end;
$$;

-- Mismo contrato de evento que v1 (aforo-backend ARCHITECTURE.md sección 4):
--   { eventId: uuid, personId: uuid|null, personName: (se ignora), direction: ENTRY|EXIT,
--     cameraOutsideId: text, cameraInsideId: text, confidence: 0..1, method: FACE|BODY_ONLY,
--     timestamp: ISO 8601 }
-- Idempotente por eventId: un reintento devuelve duplicate = true y no vuelve a contar.
create or replace function public.ingest_event(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room       uuid := private.authenticate_device();
  v_id         uuid;
  v_direction  text;
  v_method     text;
  v_confidence numeric;
  v_occurred   timestamptz;
  v_student    uuid;
  v_cam_out    uuid;
  v_cam_in     uuid;
  v_session    uuid;
begin
  if p_event is null or jsonb_typeof(p_event) <> 'object' then
    raise exception 'evento inválido: se espera un objeto JSON' using errcode = '22023';
  end if;

  v_direction := p_event ->> 'direction';
  v_method    := p_event ->> 'method';
  begin
    v_id         := (p_event ->> 'eventId')::uuid;
    v_confidence := (p_event ->> 'confidence')::numeric;
    v_occurred   := (p_event ->> 'timestamp')::timestamptz;
    v_student    := nullif(p_event ->> 'personId', '')::uuid;
  exception when others then
    raise exception 'evento inválido: eventId, personId, confidence o timestamp con formato incorrecto'
      using errcode = '22023';
  end;

  if v_id is null or v_occurred is null or v_confidence is null
     or v_direction is null or v_direction not in ('ENTRY', 'EXIT')
     or v_method is null or v_method not in ('FACE', 'BODY_ONLY')
     or v_confidence not between 0 and 1 then
    raise exception 'evento inválido: revisa direction, method, confidence, eventId y timestamp'
      using errcode = '22023';
  end if;
  if v_occurred > now() + interval '5 minutes' then
    raise exception 'evento inválido: timestamp en el futuro' using errcode = '22023';
  end if;

  -- Un personId que no está (o no está activo) en students se registra como no identificado.
  if v_student is not null and not exists (select 1 from public.students s where s.id = v_student and s.is_active) then
    v_student := null;
  end if;

  select c.id into v_cam_out from public.cameras c where c.classroom_id = v_room and c.code = p_event ->> 'cameraOutsideId';
  select c.id into v_cam_in  from public.cameras c where c.classroom_id = v_room and c.code = p_event ->> 'cameraInsideId';

  select cs.id into v_session
    from public.class_sessions cs
   where cs.classroom_id = v_room and cs.status = 'scheduled'
     and v_occurred between cs.starts_at and cs.ends_at
   order by cs.starts_at desc
   limit 1;

  insert into public.events (id, classroom_id, session_id, student_id, direction, method, confidence,
                             camera_outside_id, camera_inside_id, occurred_at)
  values (v_id, v_room, v_session, v_student, v_direction, v_method, v_confidence, v_cam_out, v_cam_in, v_occurred)
  on conflict (id) do nothing;

  return jsonb_build_object('eventId', v_id, 'duplicate', not found);
end;
$$;

-- Latido de cada cámara (cada ~30 s desde aforo-vision). Marca online/offline y abre o cierra la alerta
-- camera_offline. Devuelve el estado guardado.
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
    insert into public.alerts (classroom_id, camera_id, type, severity, message)
    values (v_room, v_camera.id, 'camera_offline', 'warning', format('La cámara "%s" está desconectada', v_camera.name))
    on conflict (camera_id) where type = 'camera_offline' and resolved_at is null do nothing;
  end if;

  return jsonb_build_object('camera', v_camera.code, 'status', v_camera.status, 'lastSeenAt', v_camera.last_seen_at);
end;
$$;

-- Permisos: solo estas dos funciones se pueden llamar sin sesión (y exigen la llave del dispositivo).
revoke all on function private.authenticate_device(integer)    from public, anon, authenticated;
revoke all on function public.ingest_event(jsonb)              from public, anon, authenticated;
revoke all on function public.camera_heartbeat(text, boolean)  from public, anon, authenticated;
grant execute on function public.ingest_event(jsonb)             to anon, authenticated;
grant execute on function public.camera_heartbeat(text, boolean) to anon, authenticated;
