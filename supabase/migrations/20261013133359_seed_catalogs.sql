-- Datos base del piloto: los 3 roles, el curso, el salón y sus dos cámaras.
-- Los estudiantes NO van aquí (son datos personales): se cargan con scripts/seed_students.py
-- desde el roster que exporta aforo-vision. El aforo máximo se cambia luego desde el dashboard
-- (admin) o con: update public.classrooms set max_capacity = <n> where name = 'Salón del piloto';

insert into public.roles (code, name, description) values
  ('admin',   'Administrador', 'Gestiona usuarios, roles, salones, cámaras, estudiantes y ve la auditoría'),
  ('teacher', 'Docente',       'Ve estudiantes, eventos y asistencia; gestiona sesiones de clase y alertas'),
  ('viewer',  'Observador',    'Ve el aforo, el estado de las cámaras y las alertas, sin datos personales');

insert into public.courses (code, name, academic_period)
values ('PILOTO-AFORO', 'Piloto de aforo', '2026-2');

with room as (
  insert into public.classrooms (name, location, max_capacity)
  values ('Salón del piloto', 'Por definir', 30)
  returning id
)
insert into public.cameras (classroom_id, code, name, position)
select room.id, c.code, c.name, c.position
from room,
     (values ('camera-outside', 'Cámara del pasillo', 'outside'),
             ('camera-inside',  'Cámara del salón',   'inside')) as c (code, name, position);
