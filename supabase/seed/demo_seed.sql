-- Datos iniciales persistentes para la prueba en vivo (curso TEST) y un historial de ejemplo.
-- Idempotente: los ids salen de md5('<tag>') y todos los inserts usan "on conflict do nothing".
-- Los estudiantes DEMO-* son ficticios; Joseph Herrera y Juan Cuaran ya existen en la base.
-- Ejecutar con un rol que salte RLS (SQL editor de Supabase o MCP), nunca con la clave publicable.

begin;

create temp table seed_ids on commit drop as
select
  (select id from public.classrooms order by created_at limit 1) as classroom_id,
  (select id from public.cameras where position = 'outside' order by created_at limit 1) as cam_out,
  (select id from public.cameras where position = 'inside' order by created_at limit 1) as cam_in,
  (select id from public.students where full_name = 'Joseph Herrera' limit 1) as joseph_id,
  (select id from public.students where full_name = 'Juan Cuaran' limit 1) as cuaran_id,
  md5('course:TEST')::uuid as test_course,
  md5('course:ED')::uuid as ed_course;

-- Cursos.
insert into public.courses (id, code, name, academic_period)
select test_course, 'TEST', 'TEST – Control de entrada y salida', '2026-2' from seed_ids
on conflict do nothing;
insert into public.courses (id, code, name, academic_period)
select ed_course, 'ED-2026-2', 'Estructuras de Datos', '2026-2' from seed_ids
on conflict do nothing;

-- Estudiantes ficticios (sin biometría, enrollment_status = none).
insert into public.students (id, full_name, student_code, email)
select md5('student:' || n)::uuid, name, 'DEMO-' || lpad(n::text, 3, '0'),
       'demo' || lpad(n::text, 3, '0') || '@aforo.test'
from (values
  (1, 'Valentina Ríos'), (2, 'Santiago Muñoz'), (3, 'Mariana López'), (4, 'Andrés Castaño'),
  (5, 'Laura Benavides'), (6, 'Camilo Rosero'), (7, 'Daniela Ortiz'), (8, 'Felipe Guerrero'),
  (9, 'Isabella Narváez'), (10, 'Juan David Pantoja'), (11, 'Sofía Erazo'), (12, 'Mateo Burbano')
) as s(n, name)
on conflict do nothing;

-- Inscripciones: los estudiantes reales (Joseph, Cuaran) van solo en TEST; ED lleva solo los 12 ficticios.
insert into public.course_students (course_id, student_id)
select test_course, joseph_id from seed_ids where joseph_id is not null
union all select test_course, cuaran_id from seed_ids where cuaran_id is not null
union all select ed_course, md5('student:' || n)::uuid from seed_ids, generate_series(1, 12) n
on conflict do nothing;

-- Sesiones (America/Bogota = UTC-5). TEST: ayer 14:00-16:00 y hoy 07:00-23:00 para la prueba en vivo.
insert into public.class_sessions (id, course_id, classroom_id, title, starts_at, ends_at)
select md5('session:TEST:2026-11-18')::uuid, test_course, classroom_id, 'TEST – ensayo',
       '2026-11-18 14:00-05'::timestamptz, '2026-11-18 16:00-05'::timestamptz from seed_ids
union all
select md5('session:TEST:2026-11-19')::uuid, test_course, classroom_id, 'TEST – prueba en vivo',
       '2026-11-19 07:00-05'::timestamptz, '2026-11-19 23:00-05'::timestamptz from seed_ids
union all
select md5('session:ED:' || d)::uuid, ed_course, classroom_id, 'Estructuras de Datos – clase ' || d,
       (d || ' 08:00-05')::timestamptz, (d || ' 10:00-05')::timestamptz
from seed_ids, unnest(array['2026-11-12', '2026-11-13', '2026-11-14', '2026-11-17', '2026-11-18']) d
on conflict do nothing;

-- Eventos: pares ENTRY/EXIT balanceados para que el aforo actual no cambie.
-- Se insertan en orden cronológico porque el trigger apply_event actualiza presencia y asistencia.
with ed_pairs as (
  select d, n,
         (d || ' 08:00-05')::timestamptz + ((n * 37 + extract(day from d::date)::int * 11) % 14) * interval '1 minute' as entry_at,
         (d || ' 09:45-05')::timestamptz + ((n * 13 + extract(day from d::date)::int * 7) % 14) * interval '1 minute' as exit_at
  from unnest(array['2026-11-12', '2026-11-13', '2026-11-14', '2026-11-17', '2026-11-18']) d,
       generate_series(1, 12) n
  where (n + extract(day from d::date)::int) % 6 <> 0  -- algunas inasistencias por clase
),
rows as (
  select md5('event:ED:' || d || ':' || n || ':in')::uuid id, md5('session:ED:' || d)::uuid session_id,
         md5('student:' || n)::uuid student_id, 'ENTRY' direction, entry_at at from ed_pairs
  union all
  select md5('event:ED:' || d || ':' || n || ':out')::uuid, md5('session:ED:' || d)::uuid,
         md5('student:' || n)::uuid, 'EXIT', exit_at from ed_pairs
  union all  -- personas no identificadas (solo cuerpo)
  select md5('event:ED:' || d || ':anon:in')::uuid, md5('session:ED:' || d)::uuid, null, 'ENTRY',
         (d || ' 08:20-05')::timestamptz
  from unnest(array['2026-11-13', '2026-11-17']) d
  union all
  select md5('event:ED:' || d || ':anon:out')::uuid, md5('session:ED:' || d)::uuid, null, 'EXIT',
         (d || ' 09:10-05')::timestamptz
  from unnest(array['2026-11-13', '2026-11-17']) d
  union all  -- ensayo de TEST con los dos estudiantes reales
  select md5('event:TEST:joseph:in')::uuid, md5('session:TEST:2026-11-18')::uuid, joseph_id, 'ENTRY',
         '2026-11-18 14:05-05'::timestamptz from seed_ids where joseph_id is not null
  union all
  select md5('event:TEST:cuaran:in')::uuid, md5('session:TEST:2026-11-18')::uuid, cuaran_id, 'ENTRY',
         '2026-11-18 14:07-05'::timestamptz from seed_ids where cuaran_id is not null
  union all
  select md5('event:TEST:cuaran:out')::uuid, md5('session:TEST:2026-11-18')::uuid, cuaran_id, 'EXIT',
         '2026-11-18 15:40-05'::timestamptz from seed_ids where cuaran_id is not null
  union all
  select md5('event:TEST:joseph:out')::uuid, md5('session:TEST:2026-11-18')::uuid, joseph_id, 'EXIT',
         '2026-11-18 15:52-05'::timestamptz from seed_ids where joseph_id is not null
)
insert into public.events (id, classroom_id, session_id, student_id, direction, method, confidence,
                           camera_outside_id, camera_inside_id, occurred_at)
select r.id, s.classroom_id, r.session_id, r.student_id, r.direction,
       case when r.student_id is null then 'BODY_ONLY' else 'FACE' end,
       case when r.student_id is null then 0.62 else 0.91 end,
       s.cam_out, s.cam_in, r.at
from rows r cross join seed_ids s
order by r.at
on conflict do nothing;

commit;
