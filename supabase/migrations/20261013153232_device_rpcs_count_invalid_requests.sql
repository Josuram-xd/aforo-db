-- Límite de peticiones sin atajos: antes, un evento o latido inválido lanzaba una excepción que revertía también
-- el incremento del contador de private.device_keys, así que quien tuviera la llave podía mandar peticiones
-- inválidas sin límite. Ahora los errores de validación responden HTTP 400 con response.status (PostgREST) y
-- la transacción se confirma, de modo que la petición sí cuenta para el límite por minuto.
-- El cuerpo de la respuesta 400 tiene la misma forma que un error de PostgREST: {code, message, details, hint}.
-- Además ingest_event rechaza eventos con más de 30 días (los borraría la retención de todos modos), para que
-- una llave no pueda reescribir asistencia de sesiones antiguas.

create or replace function private.invalid_device_request(p_message text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('response.status', '400', true);
  return jsonb_build_object('code', '22023', 'message', p_message, 'details', null, 'hint', null);
end;
$$;

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
    return private.invalid_device_request('evento inválido: se espera un objeto JSON');
  end if;

  v_direction := p_event ->> 'direction';
  v_method    := p_event ->> 'method';
  begin
    v_id         := (p_event ->> 'eventId')::uuid;
    v_confidence := (p_event ->> 'confidence')::numeric;
    v_occurred   := (p_event ->> 'timestamp')::timestamptz;
    v_student    := nullif(p_event ->> 'personId', '')::uuid;
  exception when others then
    return private.invalid_device_request(
      'evento inválido: eventId, personId, confidence o timestamp con formato incorrecto');
  end;

  if v_id is null or v_occurred is null or v_confidence is null
     or v_direction is null or v_direction not in ('ENTRY', 'EXIT')
     or v_method is null or v_method not in ('FACE', 'BODY_ONLY')
     or v_confidence not between 0 and 1 then
    return private.invalid_device_request('evento inválido: revisa direction, method, confidence, eventId y timestamp');
  end if;
  if v_occurred > now() + interval '5 minutes' then
    return private.invalid_device_request('evento inválido: timestamp en el futuro');
  end if;
  if v_occurred < now() - interval '30 days' then
    return private.invalid_device_request('evento inválido: timestamp de hace más de 30 días');
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
    return private.invalid_device_request('latido inválido: p_camera_code y p_online son obligatorios');
  end if;

  update public.cameras
     set status       = case when p_online then 'online' else 'offline' end,
         last_seen_at = case when p_online then now() else last_seen_at end
   where classroom_id = v_room and code = p_camera_code
  returning * into v_camera;

  if v_camera.id is null then
    return private.invalid_device_request(format('cámara desconocida: %s', left(p_camera_code, 50)));
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

revoke all on function private.invalid_device_request(text)    from public, anon, authenticated;
revoke all on function public.ingest_event(jsonb)              from public, anon, authenticated;
revoke all on function public.camera_heartbeat(text, boolean)  from public, anon, authenticated;
grant execute on function public.ingest_event(jsonb)             to anon;
grant execute on function public.camera_heartbeat(text, boolean) to anon;
