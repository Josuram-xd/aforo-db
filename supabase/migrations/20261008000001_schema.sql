-- Esquema relacional del sistema de aforo (PostgreSQL en Supabase).
-- 13 tablas en "public" + 1 tabla interna en "private" (llaves de dispositivo, nunca expuesta por la API).
-- Zona horaria de negocio: America/Bogota. Todas las fechas se guardan como timestamptz (UTC).

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Usuarios y permisos
-- ---------------------------------------------------------------------------

-- Roles de la aplicación: admin (todo), teacher (ve estudiantes y eventos), viewer (solo aforo y alertas).
create table public.roles (
  id          smallint generated always as identity primary key,
  code        text not null unique check (code in ('admin', 'teacher', 'viewer')),
  name        text not null,
  description text
);

-- Perfil de cada cuenta de Supabase Auth (correo/contraseña o Google). Se crea solo al registrarse.
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text not null,
  full_name  text,
  avatar_url text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_roles (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role_id    smallint not null references public.roles (id) on delete restrict,
  granted_by uuid references public.profiles (id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, role_id)
);

-- ---------------------------------------------------------------------------
-- Estructura académica y física
-- ---------------------------------------------------------------------------

create table public.courses (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,
  name            text not null,
  academic_period text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.classrooms (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null unique,
  location             text,
  max_capacity         integer not null check (max_capacity > 0),
  -- Contador atómico (lo actualiza el trigger de eventos): entradas - salidas, nunca < 0.
  current_occupancy    integer not null default 0 check (current_occupancy >= 0),
  occupancy_updated_at timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- Cada salón tiene una cámara afuera y otra adentro de la puerta.
-- No se guarda la URL ni las credenciales del stream: eso vive solo en el nodo de visión.
create table public.cameras (
  id           uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms (id) on delete cascade,
  code         text not null,                          -- el CameraId del contrato: camera-outside / camera-inside
  name         text not null,
  position     text not null check (position in ('outside', 'inside')),
  status       text not null default 'offline' check (status in ('online', 'offline')),
  last_seen_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (classroom_id, code),
  unique (classroom_id, position)
);

-- Estudiantes. El id es el mismo personId que genera el enrolamiento en aforo-vision.
-- Aquí NO hay datos biométricos: los embeddings nunca salen del nodo de visión.
create table public.students (
  id            uuid primary key default gen_random_uuid(),
  full_name     text not null,
  student_code  text unique,
  email         text,
  is_active     boolean not null default true,
  presence      text not null default 'OUT' check (presence in ('IN', 'OUT')),
  last_event_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.course_students (
  course_id   uuid not null references public.courses (id) on delete cascade,
  student_id  uuid not null references public.students (id) on delete cascade,
  enrolled_at timestamptz not null default now(),
  primary key (course_id, student_id)
);

-- Una clase/jornada monitoreada en un salón. Los eventos dentro de su horario se asocian a ella.
create table public.class_sessions (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references public.courses (id) on delete cascade,
  classroom_id uuid not null references public.classrooms (id) on delete cascade,
  title        text not null,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  status       text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);

-- ---------------------------------------------------------------------------
-- Operación
-- ---------------------------------------------------------------------------

-- Cada cruce de la puerta. El id es el eventId que genera aforo-vision (idempotencia: un reintento no duplica).
create table public.events (
  id                uuid primary key,
  classroom_id      uuid not null references public.classrooms (id) on delete cascade,
  session_id        uuid references public.class_sessions (id) on delete set null,
  student_id        uuid references public.students (id) on delete set null,
  direction         text not null check (direction in ('ENTRY', 'EXIT')),
  method            text not null check (method in ('FACE', 'BODY_ONLY')),
  confidence        numeric(4, 3) not null check (confidence between 0 and 1),
  camera_outside_id uuid references public.cameras (id) on delete set null,
  camera_inside_id  uuid references public.cameras (id) on delete set null,
  occurred_at       timestamptz not null,
  received_at       timestamptz not null default now()
);

-- Asistencia por sesión, calculada a partir de los eventos identificados.
create table public.attendance (
  session_id     uuid not null references public.class_sessions (id) on delete cascade,
  student_id     uuid not null references public.students (id) on delete cascade,
  first_entry_at timestamptz,
  last_exit_at   timestamptz,
  status         text not null default 'present' check (status in ('present', 'left')),
  updated_at     timestamptz not null default now(),
  primary key (session_id, student_id)
);

create table public.alerts (
  id           uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms (id) on delete cascade,
  camera_id    uuid references public.cameras (id) on delete set null,
  type         text not null check (type in ('capacity_exceeded', 'camera_offline')),
  severity     text not null default 'warning' check (severity in ('info', 'warning', 'critical')),
  message      text not null,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  uuid references public.profiles (id) on delete set null
);

-- Quién hizo qué: cambios en tablas (triggers) y accesos a vistas sensibles (RPC log_access).
create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid references public.profiles (id) on delete set null,
  action     text not null,          -- INSERT / UPDATE / DELETE / VIEW / LOGIN / ...
  table_name text,
  record_id  text,
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Interno (schema private: PostgREST no lo expone)
-- ---------------------------------------------------------------------------

-- Llave del nodo de visión de cada salón. Solo se guarda el hash SHA-256; la llave en claro
-- la tiene únicamente el nodo de visión. Incluye un límite simple de peticiones por minuto.
create table private.device_keys (
  id           uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms (id) on delete cascade,
  label        text not null,
  key_hash     text not null unique,
  window_start timestamptz not null default now(),
  window_count integer not null default 0,
  last_used_at timestamptz,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz
);

-- ---------------------------------------------------------------------------
-- Índices para las consultas del dashboard y para las llaves foráneas
-- ---------------------------------------------------------------------------

create index events_classroom_occurred_idx on public.events (classroom_id, occurred_at desc);
create index events_session_idx            on public.events (session_id);
create index events_student_idx            on public.events (student_id, occurred_at desc);
create index events_camera_outside_idx     on public.events (camera_outside_id);
create index events_camera_inside_idx      on public.events (camera_inside_id);
create index class_sessions_room_time_idx  on public.class_sessions (classroom_id, starts_at, ends_at);
create index class_sessions_course_idx     on public.class_sessions (course_id);
create index class_sessions_created_by_idx on public.class_sessions (created_by);
create index attendance_student_idx        on public.attendance (student_id);
create index alerts_open_idx               on public.alerts (classroom_id, created_at desc) where resolved_at is null;
create index alerts_camera_idx             on public.alerts (camera_id);
create index alerts_resolved_by_idx        on public.alerts (resolved_by);
create index audit_log_created_idx         on public.audit_log (created_at desc);
create index audit_log_actor_idx           on public.audit_log (actor_id);
create index user_roles_role_idx           on public.user_roles (role_id);
create index user_roles_granted_by_idx     on public.user_roles (granted_by);
create index course_students_student_idx   on public.course_students (student_id);
create index device_keys_classroom_idx     on private.device_keys (classroom_id);
