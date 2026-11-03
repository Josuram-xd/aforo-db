-- Task 13: validación en el servidor. El frontend ya valida, pero RLS deja escribir directo con la publishable
-- key, así que las mismas reglas viven en la base. NOT VALID: se aplican a todo INSERT/UPDATE nuevo sin
-- fallar por filas antiguas; correr "alter table ... validate constraint" cuando se confirme que no hay datos viejos que las rompan.

alter table public.students
  add constraint students_full_name_clean check (full_name = btrim(full_name) and full_name !~ '[[:cntrl:]<>]') not valid,
  add constraint students_email_valid check (
    email is null or (char_length(email) <= 254 and email ~ '^[^\s@<>]+@[^\s@<>]+\.[A-Za-z]{2,}$')
  ) not valid,
  add constraint students_code_valid check (
    student_code is null or (char_length(student_code) between 1 and 40 and student_code !~ '[[:cntrl:]<>]')
  ) not valid,
  -- La foto solo puede apuntar a su propia carpeta del bucket: "<student_id>/<archivo>.jpg".
  add constraint students_photo_path_valid check (
    photo_path is null or photo_path ~ ('^' || id::text || '/[0-9]+\.jpg$')
  ) not valid;

alter table public.courses
  add constraint courses_code_valid check (char_length(code) between 1 and 30 and code !~ '[[:cntrl:]<>]') not valid,
  add constraint courses_name_valid check (char_length(name) between 1 and 160 and name !~ '[[:cntrl:]<>]') not valid,
  add constraint courses_period_valid check (
    academic_period is null or (char_length(academic_period) <= 20 and academic_period !~ '[[:cntrl:]<>]')
  ) not valid;

alter table public.classrooms
  add constraint classrooms_name_valid check (char_length(name) between 1 and 80 and name !~ '[[:cntrl:]<>]') not valid,
  add constraint classrooms_location_valid check (
    location is null or (char_length(location) <= 120 and location !~ '[[:cntrl:]<>]')
  ) not valid,
  add constraint classrooms_capacity_valid check (max_capacity <= 10000) not valid;

alter table public.cameras
  add constraint cameras_name_valid check (char_length(name) between 1 and 80 and name !~ '[[:cntrl:]<>]') not valid;

alter table public.class_sessions
  add constraint class_sessions_title_valid check (char_length(title) between 1 and 160 and title !~ '[[:cntrl:]<>]') not valid;
