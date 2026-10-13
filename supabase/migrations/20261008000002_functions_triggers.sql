-- Funciones y triggers: perfiles al registrarse, updated_at, auditoría, aforo/asistencia/alertas
-- a partir de los eventos, y la ingesta de eventos desde aforo-vision.

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------

-- ¿El usuario actual (activo) tiene alguno de estos roles? La usan las políticas RLS.
create or replace function private.has_any_role(variadic role_codes text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    join public.profiles p on p.id = ur.user_id
    where ur.user_id = (select auth.uid())
      and p.is_active
      and r.code = any (role_codes)
  );
$$;

-- ---------------------------------------------------------------------------
-- Registro: cada cuenta nueva (correo o Google) recibe perfil y rol viewer
-- ---------------------------------------------------------------------------

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  );
  insert into public.user_roles (user_id, role_id)
  select new.id, r.id from public.roles r where r.code = 'viewer';
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'courses', 'classrooms', 'cameras', 'students', 'class_sessions'] loop
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function private.set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Auditoría de cambios
-- ---------------------------------------------------------------------------

create or replace function private.audit_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
begin
  -- No auditar los cambios automáticos de contadores/estado (los hace el trigger de eventos).
  if tg_op = 'UPDATE' and (v_old - array['current_occupancy', 'occupancy_updated_at', 'presence',
                                          'last_event_at', 'status', 'last_seen_at', 'updated_at'])
                        = (v_new - array['current_occupancy', 'occupancy_updated_at', 'presence',
                                          'last_event_at', 'status', 'last_seen_at', 'updated_at'])
     and tg_table_name in ('classrooms', 'students', 'cameras') then
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

do $$
declare t text;
begin
  foreach t in array array['profiles', 'user_roles', 'courses', 'classrooms', 'cameras', 'students',
                           'course_students', 'class_sessions', 'alerts'] loop
    execute format(
      'create trigger audit_change after insert or update or delete on public.%I for each row execute function private.audit_change()', t);
  end loop;
end $$;

-- Registro de accesos desde el dashboard (ver estudiantes, exportar eventos, iniciar sesión...).
create or replace function public.log_access(p_action text, p_resource text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'sesión requerida' using errcode = '28000';
  end if;
  if p_action not in ('LOGIN', 'LOGOUT', 'VIEW', 'EXPORT') then
    raise exception 'acción no permitida: %', p_action using errcode = '22023';
  end if;
  insert into public.audit_log (actor_id, action, table_name)
  values ((select auth.uid()), p_action, left(p_resource, 100));
end;
$$;

-- ---------------------------------------------------------------------------
-- Efectos de cada evento: aforo, estado del estudiante, asistencia y alerta de aforo
-- ---------------------------------------------------------------------------

create or replace function private.apply_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_occupancy integer;
  v_capacity  integer;
  v_room_name text;
begin
  update public.classrooms
     set current_occupancy = greatest(current_occupancy + case when new.direction = 'ENTRY' then 1 else -1 end, 0),
         occupancy_updated_at = new.occurred_at
   where id = new.classroom_id
  returning current_occupancy, max_capacity, name into v_occupancy, v_capacity, v_room_name;

  if new.student_id is not null then
    update public.students
       set presence = case when new.direction = 'ENTRY' then 'IN' else 'OUT' end,
           last_event_at = new.occurred_at
     where id = new.student_id;

    if new.session_id is not null then
      insert into public.attendance (session_id, student_id, first_entry_at, last_exit_at, status)
      values (
        new.session_id, new.student_id,
        case when new.direction = 'ENTRY' then new.occurred_at end,
        case when new.direction = 'EXIT' then new.occurred_at end,
        case when new.direction = 'ENTRY' then 'present' else 'left' end
      )
      on conflict (session_id, student_id) do update
        set first_entry_at = coalesce(public.attendance.first_entry_at, excluded.first_entry_at),
            last_exit_at   = coalesce(excluded.last_exit_at, public.attendance.last_exit_at),
            status         = excluded.status,
            updated_at     = now();
    end if;
  end if;

  if v_occupancy > v_capacity and not exists (
    select 1 from public.alerts
     where classroom_id = new.classroom_id and type = 'capacity_exceeded' and resolved_at is null
  ) then
    insert into public.alerts (classroom_id, type, severity, message)
    values (new.classroom_id, 'capacity_exceeded', 'critical',
            format('%s superó su aforo máximo: %s de %s personas', v_room_name, v_occupancy, v_capacity));
  elsif v_occupancy <= v_capacity then
    update public.alerts
       set resolved_at = now()
     where classroom_id = new.classroom_id and type = 'capacity_exceeded' and resolved_at is null;
  end if;

  return null;
end;
$$;

create trigger apply_event
  after insert on public.events
  for each row execute function private.apply_event();

-- ---------------------------------------------------------------------------
-- Ingesta desde aforo-vision (POST /rest/v1/rpc/ingest_event)
-- ---------------------------------------------------------------------------

-- Valida la llave del nodo de visión (header X-Device-Key) y aplica un límite de peticiones.
-- Devuelve el salón al que pertenece la llave.
create or replace function private.authenticate_device(p_max_per_minute integer default 120)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key  text := nullif(current_setting('request.headers', true)::json ->> 'x-device-key', '');
  v_room uuid;
  v_count integer;
begin
  if v_key is null then
    raise exception 'falta el header X-Device-Key' using errcode = '28000';
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

-- Mismo contrato de evento que antes (ARCHITECTURE.md sección 4): eventId, personId, personName,
-- direction, cameraOutsideId, cameraInsideId, confidence, method, timestamp.
create or replace function public.ingest_event(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room       uuid := private.authenticate_device();
  v_id         uuid;
  v_direction  text := p_event ->> 'direction';
  v_method     text := p_event ->> 'method';
  v_confidence numeric;
  v_occurred   timestamptz;
  v_student    uuid;
  v_cam_out    uuid;
  v_cam_in     uuid;
  v_session    uuid;
begin
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

  -- Un personId que no está en la tabla de estudiantes se registra como no identificado.
  if v_student is not null and not exists (select 1 from public.students where id = v_student and is_active) then
    v_student := null;
  end if;

  select id into v_cam_out from public.cameras where classroom_id = v_room and code = p_event ->> 'cameraOutsideId';
  select id into v_cam_in  from public.cameras where classroom_id = v_room and code = p_event ->> 'cameraInsideId';

  select id into v_session
    from public.class_sessions
   where classroom_id = v_room and status = 'scheduled'
     and v_occurred between starts_at and ends_at
   order by starts_at desc
   limit 1;

  insert into public.events (id, classroom_id, session_id, student_id, direction, method, confidence,
                             camera_outside_id, camera_inside_id, occurred_at)
  values (v_id, v_room, v_session, v_student, v_direction, v_method, v_confidence, v_cam_out, v_cam_in, v_occurred)
  on conflict (id) do nothing;

  if not found then
    return jsonb_build_object('eventId', v_id, 'duplicate', true);
  end if;
  return jsonb_build_object('eventId', v_id, 'duplicate', false);
end;
$$;

-- Latido de cada cámara (cada ~30 s desde aforo-vision). Marca online/offline y abre o cierra alertas.
create or replace function public.camera_heartbeat(p_camera_code text, p_online boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room   uuid := private.authenticate_device();
  v_camera public.cameras%rowtype;
begin
  update public.cameras
     set status = case when p_online then 'online' else 'offline' end,
         last_seen_at = case when p_online then now() else last_seen_at end
   where classroom_id = v_room and code = p_camera_code
  returning * into v_camera;

  if v_camera.id is null then
    raise exception 'cámara desconocida: %', p_camera_code using errcode = '22023';
  end if;

  if not p_online and not exists (
    select 1 from public.alerts where camera_id = v_camera.id and type = 'camera_offline' and resolved_at is null
  ) then
    insert into public.alerts (classroom_id, camera_id, type, severity, message)
    values (v_room, v_camera.id, 'camera_offline', 'warning', format('La cámara "%s" está desconectada', v_camera.name));
  elsif p_online then
    update public.alerts set resolved_at = now()
     where camera_id = v_camera.id and type = 'camera_offline' and resolved_at is null;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Administración
-- ---------------------------------------------------------------------------

-- Cambia el rol de un usuario (solo admin). Un admin no puede quitarse a sí mismo el rol admin.
create or replace function public.set_user_role(p_user_id uuid, p_role_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede cambiar roles' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and p_role_code <> 'admin' then
    raise exception 'no puedes quitarte tu propio rol de administrador' using errcode = '22023';
  end if;
  if not exists (select 1 from public.roles where code = p_role_code) then
    raise exception 'rol desconocido: %', p_role_code using errcode = '22023';
  end if;

  delete from public.user_roles where user_id = p_user_id;
  insert into public.user_roles (user_id, role_id, granted_by)
  select p_user_id, id, (select auth.uid()) from public.roles where code = p_role_code;
end;
$$;

-- Activa o desactiva una cuenta (solo admin). Una cuenta inactiva pierde todos sus permisos.
create or replace function public.set_user_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede activar o desactivar cuentas' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'no puedes desactivar tu propia cuenta' using errcode = '22023';
  end if;
  update public.profiles set is_active = p_active where id = p_user_id;
end;
$$;
