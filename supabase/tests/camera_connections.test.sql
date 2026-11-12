-- Pruebas pgTAP de la task 14: conexión de cámaras (clave cifrada, solo admin, solo el nodo de visión la lee).
-- Correr con: supabase test db   (todo se revierte al final).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin-cam@test.local',  '{}', now(), now()),
  ('00000000-0000-4000-8000-0000000000c2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'viewer-cam@test.local', '{}', now(), now());
update public.user_roles set role_id = (select id from public.roles where code = 'admin')
 where user_id = '00000000-0000-4000-8000-0000000000c1';

create temp table cam as select id from public.cameras limit 1;
grant select on cam to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000c2","role":"authenticated"}';
select throws_ok($$select public.set_camera_connection((select id from cam), '192.168.1.50', 'cam', 'secreto')$$,
                 '42501', null, 'viewer no conecta cámaras');
select throws_ok($$select * from public.camera_connections()$$, '42501', null, 'viewer no lista conexiones');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}';
select lives_ok($$select public.set_camera_connection((select id from cam), '192.168.1.50', 'cam', 'secreto')$$,
                'admin conecta una cámara');
select throws_ok($$select public.set_camera_connection((select id from cam), 'bad host;', 'cam', 'x')$$,
                 '22023', null, 'se rechaza un host inválido');
select lives_ok($$select public.set_camera_connection((select id from cam), '192.168.1.51', 'cam', null)$$,
                'cambiar la IP sin reescribir la clave');
select is((select host from public.camera_connections() limit 1), '192.168.1.51', 'la IP quedó actualizada');
select throws_ok($$select * from private.camera_connections$$, '42501', null, 'la tabla privada no se lee directo');

select * from finish();
rollback;
