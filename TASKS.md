# TASKS — aforo-db

Infraestructura como código de la tabla DynamoDB `AforoPilot` que usa `aforo-backend`.

## Cómo usar este archivo

- Cada subtarea es **un commit**. Formato: `tipo(alcance): descripción [x.y]`
  Ejemplo: `git commit -m "feat(infra): define aforo pilot table [2.1]"`
- En ese mismo commit cambia `[ ]` por `[x]` en este archivo.
- Las subtareas marcadas **(sin commit)** son verificaciones manuales: márcalas en el siguiente commit que hagas.
- Tipos: `feat`, `fix`, `test`, `docs`, `chore`, `perf`, `refactor`.
- **Prioridad 1** = sin esto no hay piloto. **Prioridad 2** = importante para que el piloto salga bien. **Prioridad 3** = extra si sobra tiempo.
- `> Depende de:` indica que antes tienes que avanzar tareas de otro repo.

## Orden global entre los 4 repos

| Fase | aforo-db | aforo-backend | aforo-vision | aforo-frontend |
|---|---|---|---|---|
| A — Arranque (en paralelo) | 1-3 | 1-2 | 1-3 | 1-2 |
| B — Núcleo | 4 | 3-7 | 4-6 | 3-5 (con datos mock) |
| C — Integración | — | — | 7 | 6 |
| D — Ensayo y ajustes | 5 | 8-9, 11 (login) | 8-11 | 7-8, 11 (login) |
| E — Extras | 6 | 10 | 12-13 | 9-10 |

**Hito fin de septiembre:** fase A completa → aquí, la tabla desplegada en AWS (task 3). Este repo es el primero que debe estar listo porque `aforo-backend` lo necesita desde su task 4.

### Versión 2 (después de la primera entrega, octubre 2026)

Retroalimentación del profe: pocas tablas, sin registro ni login, endpoints públicos, AWS sin protección contra abuso y un frontend muy básico. La v2 pasa los datos y el login a **Supabase** (PostgreSQL + Auth con Google + RLS + Realtime). Detalle en la sección "Version 2" de cada `ARCHITECTURE.md`.

| Fase | aforo-db | aforo-backend | aforo-vision | aforo-frontend |
|---|---|---|---|---|
| F — Base v2 | 7 | 12.1-12.2 | — | 12 |
| G — Login, seguridad e integración | 8 | 13 | 14 | 13 |
| H — Producto | 9 | — | 15 (evaluar visión en la nube) | 14-15 |
| I — Cierre | 10 | 12.3-12.4 | 15.3-15.6, 16 | 16 |

Las tareas v1 que la v2 reemplaza quedan marcadas con ~~tachado~~ y una nota; no se borran para conservar el historial.

---

## Prioridad 1 — Crítico

### Task 1 — Inicializar el repositorio
- [x] **1.1** `chore: init repo structure` — Carpetas `infra/` y `scripts/`, `README.md`, `.gitignore` (excluir `roster.json` real).
- [x] **1.2** `docs: add PRD, ARCHITECTURE and AGENTS` — Subir los documentos a la raíz.

### Task 2 — Definir la tabla
- [x] **2.1** `feat(infra): define aforo pilot table` — `infra/dynamodb.yaml`: tabla `AforoPilot` con `PK`/`SK` de tipo String, `BillingMode: PROVISIONED`, 5 RCU / 5 WCU (dentro del Always Free).
- [x] **2.2** `feat(infra): export table name and arn` — `Outputs` con `Export` `AforoPilotTableName` y `AforoPilotTableArn` para que `aforo-backend` los importe.
- [x] **2.3** `chore(scripts): add deploy script` — `scripts/deploy.sh` que corre `aws cloudformation deploy` con el nombre del stack y la región.

### Task 3 — Desplegar **[HITO SEPT]**
- [x] **3.1** `feat(infra): add monthly budget alarm` — `infra/budget.yaml` con una alerta de AWS Budgets a partir de 1 USD que avise al correo. Protege los créditos de la cuenta nueva.
- [x] **3.2** `docs: add aws setup and deploy steps to readme` — Cómo configurar el AWS CLI, desplegar y verificar la tabla.
- [x] **3.3** (sin commit) Correr `scripts/deploy.sh` y confirmar en la consola que la tabla y los exports existen.

### Task 4 — Roster y limpieza del piloto
- [x] **4.1** `feat(scripts): add roster example file` — `scripts/roster.example.json` con `personId` y `name` de ejemplo (sin embeddings ni fotos).
- [x] **4.2** `feat(scripts): add seed people script` — `scripts/seed_people.py`: función `seed(roster_path)` que crea `PERSON#<id>` / `PROFILE` con `status = OUT` por cada persona. Para el roster real: Seguir con la task 5 del repo: `aforo-vision` (genera `roster.json` en la 5.2).
- [x] **4.3** `feat(scripts): add reset pilot script` — `scripts/reset_pilot.py`: borra los eventos, pone el contador `AFORO` / `CURRENT` en 0 y todas las personas en `OUT`. Se usa después del ensayo, antes del día real.

---

## Prioridad 2 — Importante

### Task 5 — Retención de datos (privacidad)
- [ ] ~~**5.1** `feat(infra): enable ttl on expires at attribute` — Activar TTL sobre `expiresAt` para que los eventos (que tienen nombres) se borren solos unos días después del piloto (principio de mínima retención, Ley 1581). Después sigue con la task 9.3 del repo: `aforo-backend`.~~ → reemplazada por la task 9.1 (v2).

---

## Prioridad 3 — Extras

### Task 6 — Consultas de varios días
- [ ] ~~**6.1** `feat(infra): add gsi on timestamp` — Índice secundario global por `timestamp`. Solo si el piloto termina durando más de un día.~~ → innecesaria en v2 (PostgreSQL consulta por rango con el índice `events_classroom_occurred_idx`).

---

## Versión 2 — Supabase (PostgreSQL relacional)

> Ver `ARCHITECTURE.md` sección 7. Hay un **borrador sin probar** de las migraciones en `supabase/migrations/` (escrito el 8 oct 2026): las tasks 7.2-7.7 consisten en revisarlo, probarlo y commitearlo por partes.

### Task 7 — Proyecto y esquema **(Prioridad 1)**
- [x] **7.1** (sin commit) Crear el proyecto `aforo` en una cuenta de Supabase **del equipo** (las cuentas personales ya tienen sus 2 proyectos gratis), región `us-east-1`, e invitar a los demás con rol **Developer**. Guardar la URL del proyecto; la `service_role` key nunca va a git.
- [x] **7.2** `feat(db): add relational schema with 13 tables` — `supabase/migrations/..._schema.sql`: `roles`, `profiles`, `user_roles`, `courses`, `classrooms`, `cameras`, `students`, `course_students`, `class_sessions`, `events`, `attendance`, `alerts`, `audit_log` + `private.device_keys`, con llaves foráneas, `check` e índices.
- [x] **7.3** `feat(db): add occupancy attendance and alert triggers` — Trigger `apply_event`: aforo atómico (nunca < 0), `presence` del estudiante, fila de `attendance` de la sesión y alerta `capacity_exceeded`.
- [x] **7.4** `feat(db): add device ingest and heartbeat rpcs` — `ingest_event(p_event)` (llave `X-Device-Key` + límite de 120 peticiones/min, mismo contrato de evento que v1, idempotente por `eventId`) y `camera_heartbeat(code, online)` con alertas `camera_offline`.
- [x] **7.5** `feat(auth): create profile and viewer role on sign up` — Trigger sobre `auth.users`; RPCs de admin `set_user_role` y `set_user_active`.
- [x] **7.6** `feat(db): add audit log triggers and log access rpc` — `audit_change` en las tablas de catálogo y `log_access` para LOGIN/VIEW/EXPORT desde el frontend.
- [x] **7.7** `feat(security): enable rls with role policies` — RLS en todas las tablas, `anon` sin acceso a tablas, permisos por rol (`viewer` sin nombres de estudiantes). Realtime para `events`, `classrooms`, `cameras`, `alerts`.
- [x] **7.8** `feat(db): seed roles course classroom and cameras` — Los 3 roles, 1 curso, 1 salón (aforo máximo configurable) y sus 2 cámaras (`camera-outside`, `camera-inside`).
- [x] **7.9** (sin commit) Aplicar las migraciones al proyecto y correr los advisors de seguridad y rendimiento de Supabase: cero errores.

### Task 8 — Datos, llaves y pruebas **(Prioridad 1)**
> Depende de: task 7.

- [x] **8.1** `feat(scripts): add seed students script` — `scripts/seed_students.py`: carga `roster.json` (de `aforo-vision` task 5.2) en `students` y `course_students`, conservando el `personId` como `id`. Usa la `service_role` key desde variable de entorno. Reemplaza a `seed_people.py`.
- [x] **8.2** `feat(scripts): add create device key script` — `scripts/create_device_key.py <salón>`: genera una llave aleatoria, guarda solo su hash SHA-256 en `private.device_keys` y la muestra **una sola vez** para configurarla en `aforo-vision`. Opción `--revoke`.
- [x] **8.3** `feat(scripts): port reset pilot script to supabase` — Borra eventos, asistencia y alertas de prueba, pone el aforo en 0 y a todos en `OUT`. Pide escribir `BORRAR`.
- [x] **8.4** `test(db): add pgtap tests for rls and triggers` — `supabase/tests/`: `viewer` no ve estudiantes, `anon` no ve nada, `ingest_event` rechaza llave inválida y no duplica, el aforo no baja de 0, la alerta de aforo se abre y se cierra. Se corren con `supabase test db`.
- [x] **8.5** `docs: rewrite readme for supabase` — Crear proyecto, aplicar migraciones (`supabase db push`), cargar estudiantes, crear la llave del salón, promover al primer admin.

### Task 9 — Retención de datos **(Prioridad 2)**
- [x] **9.1** `feat(db): purge old events with pg cron` — Job diario de `pg_cron` que borra eventos y asistencia con más de N días (mínima retención, Ley 1581). Reemplaza la task 5.1.
- [x] **9.2** `feat(db): add daily summary view` — Vista `daily_occupancy_summary` (entradas, salidas, % identificado por rostro, pico de aforo por día) para las gráficas del frontend.

### Task 10 — Retirar DynamoDB **(Prioridad 3)**
> Depende de: `aforo-vision` task 14 y `aforo-frontend` task 16 funcionando contra Supabase.

- [ ] **10.1** (sin commit) Exportar los eventos de v1 que se quieran conservar para el informe.
- [ ] **10.2** (sin commit) Borrar el stack de la tabla `AforoPilot` (confirmar antes: borra los datos de v1). Mantener la alerta de presupuesto.
- [ ] **10.3** `chore: remove dynamodb templates and scripts` — Quitar `infra/dynamodb.yaml`, `seed_people.py` y `reset_pilot.py` de v1; actualizar `ARCHITECTURE.md`.

### Task 11 — Eliminar estudiantes y usuarios (derecho de supresión) **(Prioridad 1)**
> Revisión de seguridad del 2026-10-15: `audit_log` guarda una copia completa de cada fila (nombre, correo, código), así que borrar una fila no borraba sus datos personales del historial. Todo borrado pasa ahora por una RPC que además limpia la auditoría (Ley 1581, supresión).

- [x] **11.1** `feat(db): add delete student rpc with audit redaction` — `public.delete_student(p_student_id)`: solo `admin` activo. Borra el estudiante (sus inscripciones y asistencia en cascada; sus eventos quedan sin nombre y el aforo no cambia) y quita `full_name`, `email` y `student_code` de todas sus filas en `audit_log`, dejando una fila `STUDENT_DELETE` sin datos personales. Se quita el `DELETE` directo sobre `students` (política y permiso) para que ningún borrado se salte la limpieza.
- [x] **11.2** `feat(db): add delete user rpc with audit redaction` — `public.delete_user(p_user_id)`: solo `admin` activo, nunca la propia cuenta. Borra la cuenta de `auth.users` (perfil, roles y sesiones en cascada) y quita `email`, `full_name` y `avatar_url` de su historial en `audit_log`, dejando una fila `ACCOUNT_DELETE` con el rol que tenía. Las acciones que hizo esa persona siguen en la auditoría, sin su nombre.
- [x] **11.3** `test(db): cover delete rpcs and audit redaction` — pgTAP: `teacher`/`viewer`/`anon` no pueden borrar; admin no se borra a sí mismo; tras borrar no queda el nombre ni el correo en `audit_log`; los eventos del estudiante se conservan sin `student_id`; `DELETE` directo sobre `students` falla.
- [ ] **11.4** (sin commit) Aplicar las migraciones en el proyecto de Supabase y correr los advisors.
