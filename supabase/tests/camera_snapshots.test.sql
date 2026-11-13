-- Pruebas pgTAP de la task 15: foto fija de cámaras (solo admin la pide y la lee; el nodo la entrega con llave).
-- Correr con: supabase test db   (todo se revierte al final).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin-snap@test.local',  '{}', now(), now()),
  ('00000000-0000-4000-8000-0000000000d2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'viewer-snap@test.local', '{}', now(), now());
update public.user_roles set role_id = (select id from public.roles where code = 'admin')
 where user_id = '00000000-0000-4000-8000-0000000000d1';

-- Una cámara del seed y la llave de dispositivo de su salón (para el nodo de visión).
create temp table snap_ctx as select id as camera_id, classroom_id from public.cameras limit 1;
grant select on snap_ctx to authenticated;
insert into private.device_keys (classroom_id, label, key_hash)
select classroom_id, 'test-snapshot', encode(extensions.digest('llave-snapshot-test', 'sha256'), 'hex') from snap_ctx;

-- ---------------------------------------------------------------------------
-- Viewer: no pide ni lee fotos
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000d2","role":"authenticated"}';
select throws_ok($$select public.request_camera_snapshot((select camera_id from snap_ctx))$$,
                 '42501', null, 'viewer no pide fotos de cámaras');
select throws_ok($$select public.get_camera_snapshot(gen_random_uuid())$$,
                 '42501', null, 'viewer no lee fotos de cámaras');

-- ---------------------------------------------------------------------------
-- Admin: pide la foto; la tabla privada no se lee directo
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000d1","role":"authenticated"}';
select lives_ok($$select set_config('test.req_a', public.request_camera_snapshot((select camera_id from snap_ctx))::text, true)$$,
                'admin pide una foto');
select is(public.get_camera_snapshot(current_setting('test.req_a')::uuid) ->> 'status', 'pending',
          'la foto recién pedida está pendiente');
select is(public.request_camera_snapshot((select camera_id from snap_ctx)), current_setting('test.req_a')::uuid,
          'pedir otra vez en menos de 20 s devuelve la misma solicitud');
select throws_ok($$select * from private.camera_snapshot_requests$$, '42501', null,
                 'la tabla de solicitudes no se lee directo');
select throws_ok($$select * from private.camera_snapshots$$, '42501', null,
                 'la tabla de fotos no se lee directo');

-- ---------------------------------------------------------------------------
-- Nodo de visión (anon + llave del salón): ve la solicitud y entrega la foto
-- ---------------------------------------------------------------------------

set local role anon;
set local request.headers = '{"x-device-key":"llave-snapshot-test"}';
select is(jsonb_array_length(public.pending_snapshot_requests()), 1, 'el nodo ve la solicitud pendiente de su salón');
select throws_ok($$select public.submit_camera_snapshot(current_setting('test.req_a')::uuid, encode('hola'::bytea, 'base64'))$$,
                 '22023', null, 'submit rechaza una imagen que no es JPEG');
select lives_ok($$select public.submit_camera_snapshot(current_setting('test.req_a')::uuid,
                  encode('\xffd8ff'::bytea || decode(repeat('00', 2000), 'hex'), 'base64'))$$,
                'el nodo entrega un JPEG');
select is(public.pending_snapshot_requests(), '[]'::jsonb, 'tras entregar, ya no hay solicitudes pendientes');

-- ---------------------------------------------------------------------------
-- Admin: recibe la foto; una solicitud nueva no devuelve la foto anterior
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000d1","role":"authenticated"}';
select is(public.get_camera_snapshot(current_setting('test.req_a')::uuid) ->> 'status', 'done', 'la solicitud queda done');
select isnt(public.get_camera_snapshot(current_setting('test.req_a')::uuid) ->> 'image', null,
            'el admin recibe la imagen de su solicitud');
select lives_ok($$select set_config('test.req_b', public.request_camera_snapshot((select camera_id from snap_ctx))::text, true)$$,
                'admin pide una segunda foto');
select is(public.get_camera_snapshot(current_setting('test.req_b')::uuid) ->> 'image', null,
          'la solicitud nueva no devuelve la foto de otra solicitud');
select is(public.get_camera_snapshot(current_setting('test.req_b')::uuid) ->> 'status', 'pending',
          'la solicitud nueva está pendiente');

-- Una solicitud pendiente de más de 60 s se marca como expirada (cambio de fecha como postgres).
reset role;
update private.camera_snapshot_requests set requested_at = now() - interval '2 minutes'
 where id = current_setting('test.req_b')::uuid;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000d1","role":"authenticated"}';
select is(public.get_camera_snapshot(current_setting('test.req_b')::uuid) ->> 'status', 'expired',
          'una solicitud pendiente de más de 60 s queda expirada');

select * from finish();
rollback;
