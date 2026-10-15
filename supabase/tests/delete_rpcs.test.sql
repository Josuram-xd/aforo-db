-- Pruebas pgTAP de la supresión de estudiantes y cuentas (task 11): permisos, cascadas y que no quede
-- ningún dato personal en audit_log. Correr con: supabase test db   (todo se revierte al final).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(22);

-- ---------------------------------------------------------------------------
-- Datos de prueba: un salón, un curso, una sesión, un estudiante con evento y asistencia, y cuatro cuentas
-- ---------------------------------------------------------------------------

insert into public.classrooms (id, name, max_capacity)
values ('00000000-0000-4000-8000-0000000000c1', 'Salón de prueba', 10);
insert into public.courses (id, code, name) values ('00000000-0000-4000-8000-0000000000d1', 'CURSO-T', 'Curso de prueba');
insert into public.students (id, full_name, email, student_code)
values ('00000000-0000-4000-8000-0000000000b1', 'Ana Suprimida', 'ana.suprimida@test.local', 'COD-123');
insert into public.course_students (course_id, student_id)
values ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000b1');
update public.students set full_name = 'Ana María Suprimida' where id = '00000000-0000-4000-8000-0000000000b1';

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@test.local',   '{}', now(), now()),
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teacher@test.local', '{"full_name":"Profe Borrable"}', now(), now()),
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'viewer@test.local',  '{}', now(), now()),
  ('00000000-0000-4000-8000-0000000000a5', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin2@test.local',  '{}', now(), now());
update public.user_roles set role_id = (select id from public.roles where code = 'admin')
 where user_id in ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a5');
update public.user_roles set role_id = (select id from public.roles where code = 'teacher')
 where user_id = '00000000-0000-4000-8000-0000000000a2';

-- El teacher crea una sesión y resuelve una alerta: luego se borrará su cuenta.
insert into public.class_sessions (id, course_id, classroom_id, title, starts_at, ends_at, created_by)
values ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000d1',
        '00000000-0000-4000-8000-0000000000c1', 'Sesión de prueba', now() - interval '1 hour', now() + interval '1 hour',
        '00000000-0000-4000-8000-0000000000a2');
insert into public.alerts (id, classroom_id, type, message, resolved_at, resolved_by)
values ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000c1', 'capacity_exceeded',
        'Aforo superado', now(), '00000000-0000-4000-8000-0000000000a2');

-- Un evento identificado y su asistencia (los escribe el sistema; aquí se insertan directo).
insert into public.events (id, classroom_id, session_id, student_id, direction, method, confidence, occurred_at)
values ('00000000-0000-4000-8000-000000000e01', '00000000-0000-4000-8000-0000000000c1',
        '00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000b1', 'ENTRY', 'FACE', 0.9, now());
insert into public.attendance (session_id, student_id, first_entry_at, last_event_at)
values ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000b1', now(), now())
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Quién puede borrar
-- ---------------------------------------------------------------------------

set local role anon;
select throws_ok($$select public.delete_student('00000000-0000-4000-8000-0000000000b1')$$,
                 '42501', null, 'anon no puede llamar delete_student');
select throws_ok($$select public.delete_user('00000000-0000-4000-8000-0000000000a3')$$,
                 '42501', null, 'anon no puede llamar delete_user');

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}';
select throws_ok($$select public.delete_student('00000000-0000-4000-8000-0000000000b1')$$,
                 '42501', null, 'teacher no puede eliminar estudiantes');
select throws_ok($$select public.delete_user('00000000-0000-4000-8000-0000000000a3')$$,
                 '42501', null, 'teacher no puede eliminar cuentas');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}';
select throws_ok($$select public.delete_user('00000000-0000-4000-8000-0000000000a2')$$,
                 '42501', null, 'viewer no puede eliminar cuentas');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}';
select throws_ok($$delete from public.students where id = '00000000-0000-4000-8000-0000000000b1'$$,
                 '42501', null, 'ni un admin puede borrar estudiantes sin pasar por delete_student');
select throws_ok($$select public.delete_user('00000000-0000-4000-8000-0000000000a1')$$,
                 '22023', 'no puedes eliminar tu propia cuenta', 'un admin no puede eliminarse a sí mismo');
select throws_ok($$select public.delete_student('00000000-0000-4000-8000-0000000000ff')$$,
                 '22023', 'estudiante desconocido', 'delete_student rechaza un id inexistente');

-- ---------------------------------------------------------------------------
-- Eliminar estudiante
-- ---------------------------------------------------------------------------

select lives_ok($$select public.delete_student('00000000-0000-4000-8000-0000000000b1')$$,
                'un admin elimina al estudiante');
reset role;

select is((select count(*)::int from public.students where id = '00000000-0000-4000-8000-0000000000b1'),
          0, 'el estudiante ya no existe');
select is((select count(*)::int from public.course_students where student_id = '00000000-0000-4000-8000-0000000000b1'),
          0, 'sus inscripciones se borran');
select is((select count(*)::int from public.attendance where student_id = '00000000-0000-4000-8000-0000000000b1'),
          0, 'su asistencia se borra');
select is((select student_id from public.events where id = '00000000-0000-4000-8000-000000000e01'),
          null, 'su evento se conserva sin nombre');
select is((select count(*)::int from public.audit_log
            where coalesce(old_data::text, '') || coalesce(new_data::text, '')
                  ~* 'Suprimida|ana\.suprimida@test\.local|COD-123'),
          0, 'no queda su nombre, correo ni código en audit_log');
select is((select count(*)::int from public.audit_log
            where action = 'STUDENT_DELETE' and record_id = '00000000-0000-4000-8000-0000000000b1'
              and actor_id = '00000000-0000-4000-8000-0000000000a1'),
          1, 'queda una fila STUDENT_DELETE a nombre del admin');

-- ---------------------------------------------------------------------------
-- Eliminar cuenta
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}';
select lives_ok($$select public.delete_user('00000000-0000-4000-8000-0000000000a2')$$,
                'un admin elimina la cuenta del teacher (aunque haya resuelto alertas y creado sesiones)');
reset role;

select is((select count(*)::int from auth.users where id = '00000000-0000-4000-8000-0000000000a2'),
          0, 'la cuenta ya no existe en auth.users');
select is((select count(*)::int from public.profiles where id = '00000000-0000-4000-8000-0000000000a2'),
          0, 'su perfil se borra');
select is((select resolved_by from public.alerts where id = '00000000-0000-4000-8000-0000000000f1'),
          null, 'la alerta que resolvió sigue resuelta, sin su nombre');
select is((select created_by from public.class_sessions where id = '00000000-0000-4000-8000-0000000000e1'),
          null, 'la sesión que creó se conserva, sin su nombre');
select is((select count(*)::int from public.audit_log
            where coalesce(old_data::text, '') || coalesce(new_data::text, '')
                  ~* 'teacher@test\.local|Profe Borrable'),
          0, 'no queda su correo ni su nombre en audit_log');
select is((select old_data ->> 'role' from public.audit_log
            where action = 'ACCOUNT_DELETE' and record_id = '00000000-0000-4000-8000-0000000000a2'),
          'teacher', 'queda una fila ACCOUNT_DELETE con el rol que tenía');

select * from finish();
rollback;
