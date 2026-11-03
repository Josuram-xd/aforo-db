-- Pruebas pgTAP de la task 12: el profesor gestiona estudiantes y el registro biométrico es temporal.
-- Correr con: supabase test db   (todo se revierte al final).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teacher@test.local', '{}', now(), now()),
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'viewer@test.local',  '{}', now(), now());
update public.user_roles set role_id = (select id from public.roles where code = 'teacher')
 where user_id = '00000000-0000-4000-8000-0000000000a2';

-- Un JPEG falso: firma FF D8 FF + relleno (la RPC solo valida firma y tamaño).
create temp table fake_jpeg as
  select encode('\xffd8ff'::bytea || decode(repeat('00', 2000), 'hex'), 'base64') as b64;
grant select on fake_jpeg to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}';

select lives_ok($$insert into public.students (id, full_name) values ('00000000-0000-4000-8000-0000000000b1', 'Ana Nueva')$$,
                'teacher crea estudiantes');
select lives_ok($$insert into public.courses (code, name) values ('T-1', 'Curso del profe')$$, 'teacher crea cursos');
select throws_ok($$insert into public.classrooms (name, max_capacity) values ('Otro', 5)$$,
                 '42501', null, 'teacher no crea salones');
select throws_ok($$update public.students set enrollment_status = 'enrolled' where id = '00000000-0000-4000-8000-0000000000b1'$$,
                 '42501', null, 'teacher no puede marcar la biometría como registrada a mano');
select throws_ok($$select public.submit_enrollment('00000000-0000-4000-8000-0000000000b1', array[(select b64 from fake_jpeg)])$$,
                 '22023', 'se esperan entre 3 y 8 fotos', 'se exigen al menos 3 fotos');
select lives_ok($$select public.submit_enrollment('00000000-0000-4000-8000-0000000000b1',
                    array[(select b64 from fake_jpeg), (select b64 from fake_jpeg), (select b64 from fake_jpeg)])$$,
                'teacher envía 3 fotos');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}';
select throws_ok($$select public.submit_enrollment('00000000-0000-4000-8000-0000000000b1',
                    array[(select b64 from fake_jpeg), (select b64 from fake_jpeg), (select b64 from fake_jpeg)])$$,
                 '42501', null, 'viewer no puede registrar biometría');

reset role;
select is((select enrollment_status from public.students where id = '00000000-0000-4000-8000-0000000000b1'),
          'pending', 'el estudiante queda pendiente');
select is((select count(*)::int from private.enrollment_captures), 3, 'hay 3 fotos guardadas');

-- El nodo de visión (anon) sin llave de dispositivo no lee nada.
set local role anon;
select throws_ok($$select public.pending_enrollments()$$, '28000', null, 'pending_enrollments exige llave de dispositivo');
select throws_ok($$select public.complete_enrollment('00000000-0000-4000-8000-0000000000b1', true)$$,
                 '28000', null, 'complete_enrollment exige llave de dispositivo');
reset role;

-- Eliminar al estudiante no deja fotos de rostro.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}';
select public.delete_student('00000000-0000-4000-8000-0000000000b1');
reset role;
select is((select count(*)::int from private.enrollment_captures), 0, 'borrar al estudiante borra sus fotos');

select * from finish();
rollback;
