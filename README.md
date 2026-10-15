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

## Contrato con los otros repos

| Quién | Cómo | Qué |
|---|---|---|
| `aforo-vision` | `POST /rest/v1/rpc/ingest_event` con `{"p_event": {...}}` y headers `apikey` + `X-Device-Key` | Mismo evento de v1; responde `200 {"eventId", "duplicate"}`, `400` evento inválido, `403` llave inválida, `429` más de 120 peticiones/min |
| `aforo-vision` | `POST /rest/v1/rpc/camera_heartbeat` con `{"p_camera_code", "p_online"}` | Estado de la cámara y alertas `camera_offline` |
| `aforo-frontend` | `supabase-js` con el JWT del usuario | Lecturas filtradas por RLS, Realtime de `events`, `classrooms`, `cameras`, `alerts`; RPCs `set_user_role`, `set_user_active`, `log_access` |

Cualquier cambio de columnas en `events`, `students` o `classrooms` se avisa a `aforo-vision`, `aforo-frontend` y `aforo-backend` (AGENTS.md, regla 4).

## Legado v1 (DynamoDB)

Se retira en la task 10. Despliegue (Git Bash, AWS CLI configurado en `us-east-1`):

```bash
NOTIFICATION_EMAIL=tu-correo@ejemplo.com ./scripts/deploy.sh
```

Crea el stack `aforo-budget` (alerta de AWS Budgets a partir de 1 USD, que **se conserva** después de retirar v1) y el stack `aforo-db` (tabla `AforoPilot`, 5 RCU / 5 WCU, con `DeletionPolicy: Retain` y los exports `AforoPilotTableName` / `AforoPilotTableArn`). Scripts v1: `seed_people.py` y `reset_pilot.py`.
