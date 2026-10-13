-- Pruebas pgTAP de seguridad (RLS, llaves de dispositivo) y de los triggers de eventos.
-- Correr con: supabase test db   (todo ocurre dentro de una transacción que se revierte al final).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(39);

-- ---------------------------------------------------------------------------
-- Datos de prueba: un salón con aforo 1, sus cámaras, una llave, un estudiante y cuatro cuentas
-- ---------------------------------------------------------------------------

insert into public.classrooms (id, name, max_capacity)
values ('00000000-0000-4000-8000-0000000000c1', 'Salón de prueba', 1);
insert into public.cameras (classroom_id, code, name, position) values
  ('00000000-0000-4000-8000-0000000000c1', 'camera-outside', 'Afuera', 'outside'),
  ('00000000-0000-4000-8000-0000000000c1', 'camera-inside',  'Adentro', 'inside');
insert into private.device_keys (classroom_id, label, key_hash)
values ('00000000-0000-4000-8000-0000000000c1', 'test', encode(extensions.digest('llave-de-prueba', 'sha256'), 'hex'));
insert into public.students (id, full_name)
values ('00000000-0000-4000-8000-0000000000b1', 'Estudiante de prueba');

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@test.local',    now(), now()),
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teacher@test.local',  now(), now()),
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'viewer@test.local',   now(), now()),
  ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'inactive@test.local', now(), now());

select is(
  (select r.code from public.user_roles ur join public.roles r on r.id = ur.role_id
    where ur.user_id = '00000000-0000-4000-8000-0000000000a3'),
  'viewer', 'una cuenta nueva recibe perfil y rol viewer');

update public.user_roles set role_id = (select id from public.roles where code = 'admin')
 where user_id = '00000000-0000-4000-8000-0000000000a1';
update public.user_roles set role_id = (select id from public.roles where code = 'teacher')
 where user_id in ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a4');
update public.profiles set is_active = false where id = '00000000-0000-4000-8000-0000000000a4';

-- ---------------------------------------------------------------------------
-- anon: no ve ninguna tabla
-- ---------------------------------------------------------------------------

set local role anon;
select throws_ok('select count(*) from public.students',   '42501', null, 'anon no puede leer students');
select throws_ok('select count(*) from public.events',     '42501', null, 'anon no puede leer events');
select throws_ok('select count(*) from public.classrooms', '42501', null, 'anon no puede leer classrooms');
select throws_ok($$select public.set_user_role('00000000-0000-4000-8000-0000000000a1', 'viewer')$$,
                 '42501', null, 'anon no puede llamar set_user_role');

-- ---------------------------------------------------------------------------
-- ingest_event: llave del dispositivo, validación e idempotencia
-- ---------------------------------------------------------------------------

set local request.headers = '{}';
select throws_ok($$select public.ingest_event(jsonb_set('{"eventId":"11111111-1111-4111-8111-111111111111","direction":"ENTRY","method":"BODY_ONLY","confidence":0.5}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '0 minutes')))$$,
                 '28000', null, 'ingest_event rechaza una petición sin X-Device-Key');

set local request.headers = '{"x-device-key":"llave-falsa"}';
select throws_ok($$select public.ingest_event(jsonb_set('{"eventId":"11111111-1111-4111-8111-111111111111","direction":"ENTRY","method":"BODY_ONLY","confidence":0.5}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '0 minutes')))$$,
                 '28000', null, 'ingest_event rechaza una llave inválida');

set local request.headers = '{"x-device-key":"llave-de-prueba"}';
-- Los errores de validación responden 400 (response.status) sin excepción, para que la petición cuente en el límite.
select is(public.ingest_event(jsonb_set('{"eventId":"11111111-1111-4111-8111-111111111111","direction":"SIDEWAYS","method":"BODY_ONLY","confidence":0.5}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '0 minutes'))) ->> 'code',
          '22023', 'ingest_event rechaza un evento con direction inválida');
select is(current_setting('response.status', true), '400', 'el evento inválido responde HTTP 400');
select is(public.ingest_event(jsonb_build_object('eventId', '44444444-4444-4444-8444-444444444444', 'direction', 'ENTRY',
            'method', 'BODY_ONLY', 'confidence', 0.5, 'timestamp', now() - interval '31 days')) ->> 'code',
          '22023', 'ingest_event rechaza eventos de hace más de 30 días');
set local response.status = '200';

-- Los eventos usan horas relativas a now() (ingest_event rechaza eventos de hace más de 30 días).
-- Una salida con el salón vacío no deja el aforo en negativo.
select is(public.ingest_event(jsonb_set('{"eventId":"10000000-0000-4000-8000-000000000000","direction":"EXIT","method":"BODY_ONLY","confidence":0.5}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '-1 minutes'))) ->> 'duplicate',
          'false', 'una salida con el salón vacío se registra');

select is(public.ingest_event(jsonb_set('{"eventId":"11111111-1111-4111-8111-111111111111","personId":"00000000-0000-4000-8000-0000000000b1","personName":"x","direction":"ENTRY","cameraOutsideId":"camera-outside","cameraInsideId":"camera-inside","method":"FACE","confidence":0.9}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '0 minutes'))) ->> 'duplicate',
          'false', 'el primer envío de un evento se registra');
select is(public.ingest_event(jsonb_set('{"eventId":"11111111-1111-4111-8111-111111111111","personId":"00000000-0000-4000-8000-0000000000b1","personName":"x","direction":"ENTRY","cameraOutsideId":"camera-outside","cameraInsideId":"camera-inside","method":"FACE","confidence":0.9}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '0 minutes'))) ->> 'duplicate',
          'true', 'un reintento del mismo eventId responde duplicate = true');

-- Segunda entrada: 2 personas en un salón con aforo 1.
select is(public.ingest_event(jsonb_set('{"eventId":"22222222-2222-4222-8222-222222222222","direction":"ENTRY","method":"BODY_ONLY","confidence":0.6}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '1 minutes'))) ->> 'duplicate',
          'false', 'segunda entrada registrada');
reset role;

select is((select window_count from private.device_keys where classroom_id = '00000000-0000-4000-8000-0000000000c1'),
          6, 'las peticiones inválidas también cuentan para el límite por minuto');
select is((select count(*)::int from public.events where classroom_id = '00000000-0000-4000-8000-0000000000c1'),
          3, 'el reintento no duplicó el evento');
select is((select current_occupancy from public.classrooms where id = '00000000-0000-4000-8000-0000000000c1'),
          2, 'el aforo nunca bajó de 0 y no contó el duplicado (0 -> 0 -> 1 -> 2)');
select is((select presence from public.students where id = '00000000-0000-4000-8000-0000000000b1'),
          'IN', 'el estudiante identificado queda IN');
select is((select count(*)::int from public.alerts
            where classroom_id = '00000000-0000-4000-8000-0000000000c1' and type = 'capacity_exceeded' and resolved_at is null),
          1, 'se abre una alerta de aforo al superar el máximo');

set local role anon;
set local request.headers = '{"x-device-key":"llave-de-prueba"}';
select lives_ok($$select public.ingest_event(jsonb_set('{"eventId":"33333333-3333-4333-8333-333333333333","direction":"EXIT","method":"BODY_ONLY","confidence":0.6}'::jsonb, '{timestamp}', to_jsonb(date_trunc('hour', now()) - interval '1 hour' + interval '2 minutes')))$$,
                'una salida se registra');
reset role;
select is((select count(*)::int from public.alerts
            where classroom_id = '00000000-0000-4000-8000-0000000000c1' and type = 'capacity_exceeded' and resolved_at is null),
          0, 'la alerta de aforo se cierra al volver a estar dentro del máximo');

-- ---------------------------------------------------------------------------
-- RLS por rol
-- ---------------------------------------------------------------------------

set local role authenticated;

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}';
select is((select count(*)::int from public.students), 0, 'viewer no ve estudiantes (nombres)');
select ok((select count(*) from public.classrooms) > 0, 'viewer sí ve los salones y su aforo');
select throws_ok($$select public.set_user_role('00000000-0000-4000-8000-0000000000a3', 'admin')$$,
                 '42501', null, 'viewer no puede darse el rol admin');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}';
select ok((select count(*) from public.students) > 0, 'teacher ve estudiantes');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a4","role":"authenticated"}';
select is((select count(*)::int from public.classrooms), 0, 'una cuenta desactivada no ve nada');

reset role;

-- ---------------------------------------------------------------------------
-- Cámaras sin latido: el job de pg_cron las marca offline y abre la alerta
-- ---------------------------------------------------------------------------

update public.cameras set status = 'online', last_seen_at = now() - interval '5 minutes'
 where classroom_id = '00000000-0000-4000-8000-0000000000c1' and code = 'camera-outside';
update public.cameras set status = 'online', last_seen_at = now()
 where classroom_id = '00000000-0000-4000-8000-0000000000c1' and code = 'camera-inside';
select ok(private.mark_stale_cameras_offline(90) >= 1, 'el job marca offline las cámaras sin latido reciente');
select is((select status from public.cameras
            where classroom_id = '00000000-0000-4000-8000-0000000000c1' and code = 'camera-outside'),
          'offline', 'la cámara sin latido queda offline');
select is((select status from public.cameras
            where classroom_id = '00000000-0000-4000-8000-0000000000c1' and code = 'camera-inside'),
          'online', 'la cámara con latido reciente sigue online');
select is((select count(*)::int from public.alerts a join public.cameras c on c.id = a.camera_id
            where c.classroom_id = '00000000-0000-4000-8000-0000000000c1' and a.type = 'camera_offline'
              and a.resolved_at is null),
          1, 'se abre una alerta camera_offline por la cámara sin latido');
select ok(exists (select 1 from cron.job where jobname = 'mark-stale-cameras-offline'),
          'el job mark-stale-cameras-offline está programado');

-- ---------------------------------------------------------------------------
-- Auditoría de cambios de rol y de activación de cuentas
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}';
select lives_ok($$select public.set_user_role('00000000-0000-4000-8000-0000000000a3', 'teacher')$$,
                'admin cambia el rol de otra cuenta');
select lives_ok($$select public.set_user_active('00000000-0000-4000-8000-0000000000a3', false)$$,
                'admin desactiva otra cuenta');
reset role;
select is((select count(*)::int from public.audit_log
            where action = 'ROLE_GRANT' and record_id = '00000000-0000-4000-8000-0000000000a3'
              and actor_id = '00000000-0000-4000-8000-0000000000a1' and new_data ->> 'role' = 'teacher'),
          1, 'el cambio de rol queda en audit_log como ROLE_GRANT con el actor y el código del rol');
select is((select count(*)::int from public.audit_log
            where action = 'ROLE_REVOKE' and record_id = '00000000-0000-4000-8000-0000000000a3'
              and old_data ->> 'role' = 'viewer'),
          1, 'el rol anterior queda en audit_log como ROLE_REVOKE');
select is((select count(*)::int from public.audit_log
            where action = 'ACCOUNT_DEACTIVATE' and record_id = '00000000-0000-4000-8000-0000000000a3'
              and actor_id = '00000000-0000-4000-8000-0000000000a1'),
          1, 'la desactivación queda en audit_log como ACCOUNT_DEACTIVATE');

-- ---------------------------------------------------------------------------
-- Columnas de actor: no se pueden falsificar desde la API
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}';
update public.alerts set resolved_at = '2000-01-01', resolved_by = null
 where camera_id in (select id from public.cameras where classroom_id = '00000000-0000-4000-8000-0000000000c1')
   and resolved_at is null;
select throws_ok($$update public.alerts set resolved_at = null
                    where camera_id in (select id from public.cameras where classroom_id = '00000000-0000-4000-8000-0000000000c1')$$,
                 '22023', null, 'una alerta resuelta no se puede reabrir');
insert into public.class_sessions (course_id, classroom_id, title, starts_at, ends_at, created_by)
select (select id from public.courses limit 1), '00000000-0000-4000-8000-0000000000c1', 'Sesión de prueba',
       now(), now() + interval '1 hour', '00000000-0000-4000-8000-0000000000a1';
reset role;
select is((select resolved_by from public.alerts a join public.cameras c on c.id = a.camera_id
            where c.classroom_id = '00000000-0000-4000-8000-0000000000c1' and a.type = 'camera_offline'),
          '00000000-0000-4000-8000-0000000000a2'::uuid, 'resolver una alerta la firma con el usuario actual');
select is((select created_by from public.class_sessions where title = 'Sesión de prueba'),
          '00000000-0000-4000-8000-0000000000a2'::uuid, 'una sesión nueva queda a nombre de quien la crea');

select * from finish();
rollback;
