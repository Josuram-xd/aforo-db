# aforo-db

Infraestructura como código de la base de datos del sistema de aforo.

- **v2 (actual): PostgreSQL en Supabase.** Esquema relacional de 13 tablas, login con Supabase Auth, Row Level Security por rol, Realtime y las RPCs que usa `aforo-vision` para enviar eventos. Todo vive como migraciones SQL en `supabase/migrations/`.
- **v1 (legado):** tabla DynamoDB `AforoPilot` en AWS. Sigue desplegada hasta la task 10 (ver "Legado v1" al final).

Este repositorio **no** contiene lógica de aplicación: solo el esquema, sus funciones/políticas y scripts de administración.

## Estructura

```
aforo-db/
├── supabase/
│   ├── migrations/                 # se aplican en orden por fecha; nunca se editan las ya aplicadas
│   │   ├── ..._schema.sql                          # las 13 tablas, con RLS activado
│   │   ├── ..._occupancy_attendance_alert_triggers  # aforo, asistencia y alertas automáticas
│   │   ├── ..._device_ingest_heartbeat_rpcs         # ingest_event y camera_heartbeat (aforo-vision)
│   │   ├── ..._auth_profiles_and_role_rpcs          # perfil + rol viewer al registrarse, set_user_role...
│   │   ├── ..._audit_log_*, ..._audit_role_*        # auditoría de cambios y accesos
│   │   ├── ..._rls_role_policies                    # qué ve cada rol
│   │   ├── ..._seed_catalogs                        # roles, curso, salón y cámaras del piloto
│   │   ├── ..._device_key_admin_rpcs, ..._reset_pilot_rpc   # RPCs que usan los scripts
│   │   ├── ..._purge_old_events_cron, ..._mark_stale_cameras_offline_cron   # tareas programadas (pg_cron)
│   │   └── ..._daily_occupancy_summary_view, ..._enforce_actor_columns, ...
│   └── tests/rls_and_triggers.test.sql   # pruebas pgTAP (supabase test db)
├── scripts/
│   ├── seed_students.py            # carga el roster de aforo-vision como estudiantes
│   ├── create_device_key.py        # crea o revoca la llave del salón
│   ├── reset_pilot_supabase.py     # limpia los datos del ensayo
│   ├── supabase_admin.py           # cliente compartido de los scripts
│   ├── roster.example.json         # plantilla del roster (sin datos reales)
│   ├── deploy.sh                   # despliega infra/ (tabla v1 + alerta de presupuesto, que se conserva)
│   └── seed_people.py · reset_pilot.py   # v1 (DynamoDB), se quitan en la task 10.3
├── infra/                          # v1: CloudFormation (tabla DynamoDB y alerta de presupuesto)
└── PRD.md · ARCHITECTURE.md (sección 7 = v2) · AGENTS.md · TASKS.md
```

**Tablas:** `roles`, `profiles`, `user_roles` (usuarios y permisos) · `courses`, `classrooms`, `cameras`, `students`, `course_students`, `class_sessions` (el curso y el salón) · `events`, `attendance`, `alerts` (lo que pasa en la puerta) · `audit_log` (quién hizo qué).

## Privacidad y seguridad

- El roster real (`roster.json`) tiene nombres de personas y **no se versiona**. Plantilla: `scripts/roster.example.json`.
- En la base de datos **no hay datos biométricos** (los embeddings nunca salen del nodo de visión) ni contraseñas: las contraseñas las maneja solo Supabase Auth.
- La llave `service_role` (o `sb_secret_...`) salta RLS: úsala solo en tu máquina, por variable de entorno, **nunca** en git ni en el frontend. El frontend y `aforo-vision` usan solo la *publishable key*.
- La llave de dispositivo de cada salón se guarda solo como hash SHA-256.

## Puesta en marcha (v2, Supabase)

### 1. Crear el proyecto

En una cuenta de Supabase **del equipo**: proyecto `aforo`, región `us-east-1`, plan Free. Invita al resto del equipo con rol **Developer**. Anota la URL del proyecto (`https://<ref>.supabase.co`).

### 2. Aplicar las migraciones

Con el [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started):

```bash
supabase login
supabase init                      # solo la primera vez, si no existe supabase/config.toml
supabase link --project-ref <ref>
supabase db push                   # aplica supabase/migrations/ en orden
```

Las migraciones crean, en este orden: el esquema con RLS activado y sin permisos; los triggers de aforo/asistencia/alertas; las RPCs del nodo de visión (`ingest_event`, `camera_heartbeat`); perfil y rol `viewer` al registrarse + RPCs de admin; auditoría; políticas RLS y Realtime; los datos base (3 roles, el curso `PILOTO-AFORO`, el salón `Salón del piloto` con aforo 30 y sus cámaras `camera-outside` / `camera-inside`); y las RPCs de administración que usan los scripts.

Después corre los advisors (**Dashboard → Advisors**, seguridad y rendimiento): no debe haber errores.

### 3. Pruebas

```bash
supabase test db                   # requiere Docker (stack local)
```

`supabase/tests/rls_and_triggers.test.sql` comprueba que `anon` no ve nada, que `viewer` no ve estudiantes, que una cuenta desactivada pierde el acceso, que `ingest_event` rechaza llaves inválidas y no duplica reintentos, que el aforo no baja de 0 y que la alerta de aforo se abre y se cierra.

### 4. Variables de entorno para los scripts

Los scripts usan solo la biblioteca estándar de Python 3.

```bash
export SUPABASE_URL=https://<ref>.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<service_role o sb_secret_...>   # Dashboard → Project Settings → API Keys
```

En PowerShell: `$env:SUPABASE_URL = "..."` y `$env:SUPABASE_SERVICE_ROLE_KEY = "..."`.

### 5. Cargar los estudiantes

En `aforo-vision`: `python -m enrollment.export_roster` genera `data/roster.json` (solo `personId` + `name`). Cópialo a `scripts/roster.json` y:

```bash
python scripts/seed_students.py            # o: python scripts/seed_students.py ruta/roster.json --course PILOTO-AFORO
```

Se puede correr varias veces: actualiza nombres sin tocar el estado `IN`/`OUT` y no duplica inscripciones.

### 6. Crear la llave del salón

```bash
python scripts/create_device_key.py "Salón del piloto"
```

Muestra la llave **una sola vez**. Ponla en el `.env` de `aforo-vision` (que está en `.gitignore`):

```
AFORO_BACKEND_URL=https://<ref>.supabase.co
AFORO_SUPABASE_KEY=<publishable key>
AFORO_DEVICE_KEY=<la llave>
```

Si la llave se filtra: `python scripts/create_device_key.py "Salón del piloto" --revoke` y crea otra.

### 7. Promover al primer administrador

Toda cuenta nueva (correo o Google) entra como `viewer`. Regístrate en el frontend y, en **Dashboard → SQL Editor**, conviértete en admin (solo esta vez; después los roles se cambian desde la app con `set_user_role`):

```sql
update public.user_roles
   set role_id = (select id from public.roles where code = 'admin')
 where user_id = (select id from auth.users where email = 'tu-correo@ejemplo.com');
```

### 8. Ajustes del dashboard (no son SQL)

- **Authentication → Providers**: activar Google (Client ID/Secret de Google Cloud) si se usa login con Google.
- **Authentication → URL Configuration**: *Site URL* y *Redirect URLs* del frontend (Amplify y `http://localhost:5173`).
- **Authentication → Attack Protection**: activar *leaked password protection* (requiere plan Pro; en Free queda pendiente) y dejar la longitud mínima de contraseña en al menos 8.

### Reiniciar el piloto

Después del ensayo y antes del día real:

```bash
python scripts/reset_pilot_supabase.py     # pide escribir BORRAR
```

Borra eventos, asistencia y alertas; pone el aforo en 0 y a todos en `OUT`. Conserva estudiantes, usuarios, sesiones y la auditoría.

## Estructuras de datos, GRASP y SOLID

Esta sección describe lo que el esquema **ya hace** y dónde está en las migraciones. Cada afirmación se puede comprobar abriendo el archivo citado.

### Estructuras de datos del esquema

- **Índices (B-tree, el tipo por defecto de PostgreSQL).** Por ejemplo `events_classroom_occurred_idx on public.events (classroom_id, occurred_at desc)` en `supabase/migrations/20261013132634_schema.sql`: acelera "eventos de un salón, del más reciente al más antiguo". Hay más índices en el mismo archivo (por estudiante, por sesión, por fecha de auditoría). El índice único parcial `alerts_open_capacity_uidx` impide tener dos alertas de aforo abiertas en el mismo salón.
- **Grafo de relaciones por claves foráneas.** Las 13 tablas de `public` se enlazan con `references` en `20261013132634_schema.sql`. Ejemplos: `events` apunta a `classrooms`, `class_sessions`, `students` y `cameras`; `course_students` une `courses` con `students`; `attendance` une `class_sessions` con `students`; `profiles` depende de `auth.users`. Los borrados siguen el grafo: `on delete cascade` (p. ej. `course_students`, `attendance`), `on delete set null` (p. ej. los eventos conservan su historial cuando se borra un estudiante) o `on delete restrict` (`user_roles.role_id`).
- **Tabla de eventos como registro ordenado en el tiempo.** `public.events` guarda `occurred_at` (hora del evento) y `received_at` (hora de llegada). El job `purge-old-events` de pg_cron (`20261013134057_purge_old_events_cron.sql`) corre a diario y borra los eventos y la asistencia con más de 30 días mediante `private.purge_old_data(30)`.
- **Cola de registro biométrico.** `private.enrollment_captures` funciona como cola: `pending_enrollments()` entrega hasta 3 estudiantes con `enrollment_status = 'pending'`, en orden de `enrollment_updated_at` (FIFO), y `complete_enrollment()` borra sus fotos al terminar (`20261102120000_teacher_manage_students_enrollment.sql`). La cola la consume el nodo de visión, no la app.

### Estructuras del curso que no se aplican

El esquema no implementa pilas, colas genéricas, listas enlazadas, árboles propios ni colas de prioridad. La base delega ese trabajo al motor de PostgreSQL (índices, orden y almacenamiento de tablas). Las únicas colas son la de registro biométrico de arriba, que es un flujo de negocio, no una estructura de datos general.

### GRASP

- **Experto (information expert).** La lógica de datos vive en la base. `private.has_any_role` (`20261013133014_auth_profiles_and_role_rpcs.sql`) decide los permisos a partir de `user_roles` y `profiles.is_active`, y lo usan las políticas RLS y las RPCs. El trigger `apply_event` sobre `events` (`20261013132715_occupancy_attendance_alert_triggers.sql`) actualiza aforo, asistencia y alertas. `private.audit_change` (`20261013133122_audit_log_triggers_and_log_access.sql`) escribe la auditoría.
- **Indirección (indirection).** `public.delete_student` (`20261015140000_delete_student_rpc.sql`, reemplazada en `20261102120000_teacher_manage_students_enrollment.sql`) y `public.delete_user` (`20261015140100_delete_user_rpc.sql`) son las vías de borrado. El `DELETE` directo sobre `students` se retiró: la política y el permiso de `authenticated` se quitaron en `20261015140000`, y en `20261102120000` no se volvió a conceder. La cuenta se borra solo con `delete_user`, porque `authenticated` no tiene permisos sobre `auth.users`. Ambas funciones son `security definer` y redactan los datos personales de `audit_log`.
- **Bajo acoplamiento (low coupling).** El esquema `private` guarda funciones, triggers y tablas internas (`device_keys`, `enrollment_captures`), con `revoke all ... from public` en `20261013132634_schema.sql`. Las tablas de `private` no tienen permisos para `anon` ni `authenticated`, y `authenticated` solo recibe `usage` y `execute` de `has_any_role` (`20261013133014_auth_profiles_and_role_rpcs.sql`). Las migraciones no añaden `private` a los esquemas expuestos por la API; esa lista vive en la configuración del proyecto de Supabase, que no está en este repo.
- **Alta cohesión (high cohesion).** Cada migración agrupa una responsabilidad y su nombre la describe: `rls_role_policies`, `audit_log_triggers_and_log_access`, `purge_old_events_cron`, `delete_student_rpc`. Matiz honesto: algunas funciones se redefinen en migraciones posteriores (por ejemplo `ingest_event` en `20261013132827` y `20261013153232`, `audit_change` en `20261013133122` y `20261013140927`, `delete_student` en `20261015140000` y `20261102120000`). Las migraciones ya aplicadas no se editan, así que la versión vigente es la última.

### SOLID (por analogía)

Un esquema SQL no tiene clases ni interfaces, así que SOLID aplica solo por analogía:

- **S (responsabilidad única):** una migración y una RPC por responsabilidad, por ejemplo `delete_student` solo borra estudiantes y `complete_enrollment` solo cierra un registro biométrico.
- **O, L, I, D:** no aplican al esquema y no se documentan como cumplidos.

El curso está en `C:\Users\amand\Documents\Estructura de datos`; el mapeo completo curso-Aforo está en el README de `aforo-vision`.

## Contrato con los otros repos

| Quién | Cómo | Qué |
|---|---|---|
| `aforo-vision` | `POST /rest/v1/rpc/ingest_event` con `{"p_event": {...}}` y headers `apikey` + `X-Device-Key` | Mismo evento de v1; responde `200 {"eventId", "duplicate"}`, `400` evento inválido, `403` llave inválida, `429` más de 120 peticiones/min |
| `aforo-vision` | `POST /rest/v1/rpc/camera_heartbeat` con `{"p_camera_code", "p_online"}` | Estado de la cámara y alertas `camera_offline` |
| `aforo-frontend` | `supabase-js` con el JWT del usuario | Lecturas filtradas por RLS, Realtime de `events`, `classrooms`, `cameras`, `alerts`; RPCs `set_user_role`, `set_user_active`, `delete_user`, `delete_student`, `log_access` |

Cualquier cambio de columnas en `events`, `students` o `classrooms` se avisa a `aforo-vision`, `aforo-frontend` y `aforo-backend` (AGENTS.md, regla 4).

## Legado v1 (DynamoDB)

Se retira en la task 10. Despliegue (Git Bash, AWS CLI configurado en `us-east-1`):

```bash
NOTIFICATION_EMAIL=tu-correo@ejemplo.com ./scripts/deploy.sh
```

Crea el stack `aforo-budget` (alerta de AWS Budgets a partir de 1 USD, que **se conserva** después de retirar v1) y el stack `aforo-db` (tabla `AforoPilot`, 5 RCU / 5 WCU, con `DeletionPolicy: Retain` y los exports `AforoPilotTableName` / `AforoPilotTableArn`). Scripts v1: `seed_people.py` y `reset_pilot.py`.
