# TASKS â€” aforo-db

Infraestructura como cÃ³digo de la tabla DynamoDB `AforoPilot` que usa `aforo-backend`.

## CÃ³mo usar este archivo

- Cada subtarea es **un commit**. Formato: `tipo(alcance): descripciÃ³n [x.y]`
  Ejemplo: `git commit -m "feat(infra): define aforo pilot table [2.1]"`
- En ese mismo commit cambia `[ ]` por `[x]` en este archivo.
- Las subtareas marcadas **(sin commit)** son verificaciones manuales: mÃ¡rcalas en el siguiente commit que hagas.
- Tipos: `feat`, `fix`, `test`, `docs`, `chore`, `perf`, `refactor`.
- **Prioridad 1** = sin esto no hay piloto. **Prioridad 2** = importante para que el piloto salga bien. **Prioridad 3** = extra si sobra tiempo.
- `> Depende de:` indica que antes tienes que avanzar tareas de otro repo.

## Orden global entre los 4 repos

| Fase | aforo-db | aforo-backend | aforo-vision | aforo-frontend |
|---|---|---|---|---|
| A â€” Arranque (en paralelo) | 1-3 | 1-2 | 1-3 | 1-2 |
| B â€” NÃºcleo | 4 | 3-7 | 4-6 | 3-5 (con datos mock) |
| C â€” IntegraciÃ³n | â€” | â€” | 7 | 6 |
| D â€” Ensayo y ajustes | 5 | 8-9, 11 (login) | 8-11 | 7-8, 11 (login) |
| E â€” Extras | 6 | 10 | 12-13 | 9-10 |

**Hito fin de septiembre:** fase A completa â†’ aquÃ­, la tabla desplegada en AWS (task 3). Este repo es el primero que debe estar listo porque `aforo-backend` lo necesita desde su task 4.

### VersiÃ³n 2 (despuÃ©s de la primera entrega, octubre 2026)

RetroalimentaciÃ³n del profe: pocas tablas, sin registro ni login, endpoints pÃºblicos, AWS sin protecciÃ³n contra abuso y un frontend muy bÃ¡sico. La v2 pasa los datos y el login a **Supabase** (PostgreSQL + Auth con Google + RLS + Realtime). Detalle en la secciÃ³n "Version 2" de cada `ARCHITECTURE.md`.

| Fase | aforo-db | aforo-backend | aforo-vision | aforo-frontend |
|---|---|---|---|---|
| F â€” Base v2 | 7 | 12.1-12.2 | â€” | 12 |
| G â€” Login, seguridad e integraciÃ³n | 8 | 13 | 14 | 13 |
| H â€” Producto | 9 | â€” | 15 (evaluar visiÃ³n en la nube) | 14-15 |
| I â€” Cierre | 10 | 12.3-12.4 | 15.3-15.6, 16 | 16 |

Las tareas v1 que la v2 reemplaza quedan marcadas con ~~tachado~~ y una nota; no se borran para conservar el historial.

---

## Prioridad 1 â€” CrÃ­tico

### Task 1 â€” Inicializar el repositorio
- [x] **1.1** `chore: init repo structure` â€” Carpetas `infra/` y `scripts/`, `README.md`, `.gitignore` (excluir `roster.json` real).
- [x] **1.2** `docs: add PRD, ARCHITECTURE and AGENTS` â€” Subir los documentos a la raÃ­z.

### Task 2 â€” Definir la tabla
- [x] **2.1** `feat(infra): define aforo pilot table` â€” `infra/dynamodb.yaml`: tabla `AforoPilot` con `PK`/`SK` de tipo String, `BillingMode: PROVISIONED`, 5 RCU / 5 WCU (dentro del Always Free).
- [x] **2.2** `feat(infra): export table name and arn` â€” `Outputs` con `Export` `AforoPilotTableName` y `AforoPilotTableArn` para que `aforo-backend` los importe.
- [x] **2.3** `chore(scripts): add deploy script` â€” `scripts/deploy.sh` que corre `aws cloudformation deploy` con el nombre del stack y la regiÃ³n.

### Task 3 â€” Desplegar **[HITO SEPT]**
- [x] **3.1** `feat(infra): add monthly budget alarm` â€” `infra/budget.yaml` con una alerta de AWS Budgets a partir de 1 USD que avise al correo. Protege los crÃ©ditos de la cuenta nueva.
- [x] **3.2** `docs: add aws setup and deploy steps to readme` â€” CÃ³mo configurar el AWS CLI, desplegar y verificar la tabla.
- [x] **3.3** (sin commit) Correr `scripts/deploy.sh` y confirmar en la consola que la tabla y los exports existen.

### Task 4 â€” Roster y limpieza del piloto
- [x] **4.1** `feat(scripts): add roster example file` â€” `scripts/roster.example.json` con `personId` y `name` de ejemplo (sin embeddings ni fotos).
- [x] **4.2** `feat(scripts): add seed people script` â€” `scripts/seed_people.py`: funciÃ³n `seed(roster_path)` que crea `PERSON#<id>` / `PROFILE` con `status = OUT` por cada persona. Para el roster real: Seguir con la task 5 del repo: `aforo-vision` (genera `roster.json` en la 5.2).
- [x] **4.3** `feat(scripts): add reset pilot script` â€” `scripts/reset_pilot.py`: borra los eventos, pone el contador `AFORO` / `CURRENT` en 0 y todas las personas en `OUT`. Se usa despuÃ©s del ensayo, antes del dÃ­a real.

---

## Prioridad 2 â€” Importante

### Task 5 â€” RetenciÃ³n de datos (privacidad)
- [ ] ~~**5.1** `feat(infra): enable ttl on expires at attribute` â€” Activar TTL sobre `expiresAt` para que los eventos (que tienen nombres) se borren solos unos dÃ­as despuÃ©s del piloto (principio de mÃ­nima retenciÃ³n, Ley 1581). DespuÃ©s sigue con la task 9.3 del repo: `aforo-backend`.~~ â†’ reemplazada por la task 9.1 (v2).

---

## Prioridad 3 â€” Extras

### Task 6 â€” Consultas de varios dÃ­as
- [ ] ~~**6.1** `feat(infra): add gsi on timestamp` â€” Ãndice secundario global por `timestamp`. Solo si el piloto termina durando mÃ¡s de un dÃ­a.~~ â†’ innecesaria en v2 (PostgreSQL consulta por rango con el Ã­ndice `events_classroom_occurred_idx`).

---

## VersiÃ³n 2 â€” Supabase (PostgreSQL relacional)

> Ver `ARCHITECTURE.md` secciÃ³n 7. Hay un **borrador sin probar** de las migraciones en `supabase/migrations/` (escrito el 8 oct 2026): las tasks 7.2-7.7 consisten en revisarlo, probarlo y commitearlo por partes.

### Task 7 â€” Proyecto y esquema **(Prioridad 1)**
- [x] **7.1** (sin commit) Crear el proyecto `aforo` en una cuenta de Supabase **del equipo** (las cuentas personales ya tienen sus 2 proyectos gratis), regiÃ³n `us-east-1`, e invitar a los demÃ¡s con rol **Developer**. Guardar la URL del proyecto; la `service_role` key nunca va a git.
- [x] **7.2** `feat(db): add relational schema with 13 tables` â€” `supabase/migrations/..._schema.sql`: `roles`, `profiles`, `user_roles`, `courses`, `classrooms`, `cameras`, `students`, `course_students`, `class_sessions`, `events`, `attendance`, `alerts`, `audit_log` + `private.device_keys`, con llaves forÃ¡neas, `check` e Ã­ndices.
- [x] **7.3** `feat(db): add occupancy attendance and alert triggers` â€” Trigger `apply_event`: aforo atÃ³mico (nunca < 0), `presence` del estudiante, fila de `attendance` de la sesiÃ³n y alerta `capacity_exceeded`.
- [x] **7.4** `feat(db): add device ingest and heartbeat rpcs` â€” `ingest_event(p_event)` (llave `X-Device-Key` + lÃ­mite de 120 peticiones/min, mismo contrato de evento que v1, idempotente por `eventId`) y `camera_heartbeat(code, online)` con alertas `camera_offline`.
- [x] **7.5** `feat(auth): create profile and viewer role on sign up` â€” Trigger sobre `auth.users`; RPCs de admin `set_user_role` y `set_user_active`.
- [x] **7.6** `feat(db): add audit log triggers and log access rpc` â€” `audit_change` en las tablas de catÃ¡logo y `log_access` para LOGIN/VIEW/EXPORT desde el frontend.
- [x] **7.7** `feat(security): enable rls with role policies` â€” RLS en todas las tablas, `anon` sin acceso a tablas, permisos por rol (`viewer` sin nombres de estudiantes). Realtime para `events`, `classrooms`, `cameras`, `alerts`.
- [x] **7.8** `feat(db): seed roles course classroom and cameras` â€” Los 3 roles, 1 curso, 1 salÃ³n (aforo mÃ¡ximo configurable) y sus 2 cÃ¡maras (`camera-outside`, `camera-inside`).
- [x] **7.9** (sin commit) Aplicar las migraciones al proyecto y correr los advisors de seguridad y rendimiento de Supabase: cero errores.

### Task 8 â€” Datos, llaves y pruebas **(Prioridad 1)**
> Depende de: task 7.

- [x] **8.1** `feat(scripts): add seed students script` â€” `scripts/seed_students.py`: carga `roster.json` (de `aforo-vision` task 5.2) en `students` y `course_students`, conservando el `personId` como `id`. Usa la `service_role` key desde variable de entorno. Reemplaza a `seed_people.py`.
- [x] **8.2** `feat(scripts): add create device key script` â€” `scripts/create_device_key.py <salÃ³n>`: genera una llave aleatoria, guarda solo su hash SHA-256 en `private.device_keys` y la muestra **una sola vez** para configurarla en `aforo-vision`. OpciÃ³n `--revoke`.
- [x] **8.3** `feat(scripts): port reset pilot script to supabase` â€” Borra eventos, asistencia y alertas de prueba, pone el aforo en 0 y a todos en `OUT`. Pide escribir `BORRAR`.
- [x] **8.4** `test(db): add pgtap tests for rls and triggers` â€” `supabase/tests/`: `viewer` no ve estudiantes, `anon` no ve nada, `ingest_event` rechaza llave invÃ¡lida y no duplica, el aforo no baja de 0, la alerta de aforo se abre y se cierra. Se corren con `supabase test db`.
- [x] **8.5** `docs: rewrite readme for supabase` â€” Crear proyecto, aplicar migraciones (`supabase db push`), cargar estudiantes, crear la llave del salÃ³n, promover al primer admin.

### Task 9 â€” RetenciÃ³n de datos **(Prioridad 2)**
- [x] **9.1** `feat(db): purge old events with pg cron` â€” Job diario de `pg_cron` que borra eventos y asistencia con mÃ¡s de N dÃ­as (mÃ­nima retenciÃ³n, Ley 1581). Reemplaza la task 5.1.
- [x] **9.2** `feat(db): add daily summary view` â€” Vista `daily_occupancy_summary` (entradas, salidas, % identificado por rostro, pico de aforo por dÃ­a) para las grÃ¡ficas del frontend.

### Task 10 â€” Retirar DynamoDB **(Prioridad 3)**
> Depende de: `aforo-vision` task 14 y `aforo-frontend` task 16 funcionando contra Supabase.

- [ ] **10.1** (sin commit) Exportar los eventos de v1 que se quieran conservar para el informe.
- [ ] **10.2** (sin commit) Borrar el stack de la tabla `AforoPilot` (confirmar antes: borra los datos de v1). Mantener la alerta de presupuesto.
- [ ] **10.3** `chore: remove dynamodb templates and scripts` â€” Quitar `infra/dynamodb.yaml`, `seed_people.py` y `reset_pilot.py` de v1; actualizar `ARCHITECTURE.md`.

### Task 11 â€” Eliminar estudiantes y usuarios (derecho de supresiÃ³n) **(Prioridad 1)**
> RevisiÃ³n de seguridad del 2026-10-15: `audit_log` guarda una copia completa de cada fila (nombre, correo, cÃ³digo), asÃ­ que borrar una fila no borraba sus datos personales del historial. Todo borrado pasa ahora por una RPC que ademÃ¡s limpia la auditorÃ­a (Ley 1581, supresiÃ³n).

- [x] **11.1** `feat(db): add delete student rpc with audit redaction` â€” `public.delete_student(p_student_id)`: solo `admin` activo. Borra el estudiante (sus inscripciones y asistencia en cascada; sus eventos quedan sin nombre y el aforo no cambia) y quita `full_name`, `email` y `student_code` de todas sus filas en `audit_log`, dejando una fila `STUDENT_DELETE` sin datos personales. Se quita el `DELETE` directo sobre `students` (polÃ­tica y permiso) para que ningÃºn borrado se salte la limpieza.
- [x] **11.2** `feat(db): add delete user rpc with audit redaction` â€” `public.delete_user(p_user_id)`: solo `admin` activo, nunca la propia cuenta. Borra la cuenta de `auth.users` (perfil, roles y sesiones en cascada) y quita `email`, `full_name` y `avatar_url` de su historial en `audit_log`, dejando una fila `ACCOUNT_DELETE` con el rol que tenÃ­a. Las acciones que hizo esa persona siguen en la auditorÃ­a, sin su nombre.
- [x] **11.3** `test(db): cover delete rpcs and audit redaction` â€” pgTAP: `teacher`/`viewer`/`anon` no pueden borrar; admin no se borra a sÃ­ mismo; tras borrar no queda el nombre ni el correo en `audit_log`; los eventos del estudiante se conservan sin `student_id`; `DELETE` directo sobre `students` falla.
- [ ] **11.4** (sin commit) Aplicar las migraciones en el proyecto de Supabase y correr los advisors.

### Task 12 â€” Profesor gestiona estudiantes y registro biomÃ©trico **(Prioridad 1)**
> DecisiÃ³n del 2026-11-02: el profesor crea cursos y estudiantes desde la app, con foto opcional, y registra la biometrÃ­a capturando fotos en el navegador. **ExcepciÃ³n a la regla 5 de `AGENTS.md`**: las fotos de rostro existen en la base solo de forma temporal (`private.enrollment_captures`) hasta que el nodo de visiÃ³n calcula el embedding en local y las borra; los embeddings nunca llegan a la base.

- [x] **12.1** `feat(db): let teachers manage students and add enrollment captures` â€” `teacher` crea/edita cursos, estudiantes e inscripciones y elimina estudiantes (`delete_student`); `students.photo_path` + bucket privado `student-photos`; `students.enrollment_status`; RPCs `submit_enrollment` (teacher/admin), `pending_enrollments` y `complete_enrollment` (nodo de visiÃ³n, llave de dispositivo). Pruebas en `supabase/tests/teacher_enrollment.test.sql`.
- [ ] **12.2** (sin commit) Aplicar la migraciÃ³n en Supabase, correr `supabase test db` y los advisors.

### Task 14 â€” Conectar cÃ¡maras desde la web **(Prioridad 1)**
> DecisiÃ³n del 2026-11-12: la IP y la cuenta de cÃ¡mara Tapo se registran en la web (admin); la clave se guarda cifrada en Supabase Vault y solo la lee el nodo de visiÃ³n con la llave del salÃ³n.

- [x] **14.1** `feat(db): add camera connections with vault-encrypted password` â€” `private.camera_connections` + RPCs `set_camera_connection`, `clear_camera_connection`, `camera_connections` (admin) y `camera_sources` (nodo de visiÃ³n). Pruebas en `supabase/tests/camera_connections.test.sql`.
- [ ] **14.2** (sin commit) Aplicar la migraciÃ³n en Supabase, correr `supabase test db` y los advisors.

### Task 15 â€” Foto fija de cÃ¡maras **(Prioridad 2)**
> DecisiÃ³n del 2026-11-12: el admin pide una foto fija de una cÃ¡mara desde la web. El nodo de visiÃ³n la captura y la entrega con su llave del salÃ³n; la imagen vive solo unos minutos en la base y cada vista queda en la auditorÃ­a.

- [x] **15.1** `feat(db): add on-demand camera snapshots` â€” `private.camera_snapshot_requests` y `private.camera_snapshots` (una foto por cÃ¡mara) + RPCs `request_camera_snapshot` y `get_camera_snapshot` (admin) y `pending_snapshot_requests` y `submit_camera_snapshot` (nodo de visiÃ³n). Purga cada 5 minutos con pg_cron. Pruebas en `supabase/tests/camera_snapshots.test.sql`.
- [ ] **15.2** (sin commit) Aplicar la migraciÃ³n en Supabase, correr `supabase test db` y los advisors.

### Task 16 â€” LimitaciÃ³n del nodo local **(Prioridad 1)**
> DecisiÃ³n del 2026-11-12 (dueÃ±o): los datos de cÃ¡maras y eventos dependen de un computador encendido con `aforo-vision` en la misma red que las cÃ¡maras. Sin Ã©l, las cÃ¡maras figuran sin conexiÃ³n.

- [x] **16.1** `docs: document the local-node limitation [16.1]` â€” Nota en `README.md`, limitaciÃ³n en `PRD.md` (secciÃ³n 8) y nota en `ARCHITECTURE.md` (secciÃ³n 6), con referencia a `aforo-vision` ADR-008 y al marcado offline tras 90 s.

### Task 17 â€” Datos iniciales del curso TEST **(Prioridad 1)**
> DecisiÃ³n del 2026-11-19 (dueÃ±o): el caso de estudio se centra en la entrada y salida de los estudiantes de un curso. La base real lleva datos persistentes: curso `TEST` con los estudiantes reales y un curso de ejemplo con historial.

- [x] **17.1** `feat(db): add idempotent demo seed with the TEST course [17.1]` â€” `supabase/seed/demo_seed.sql`: curso `TEST` (solo Joseph Herrera y Juan Cuaran) con un ensayo y la sesiÃ³n de hoy; curso `ED-2026-2` con 12 estudiantes ficticios, 5 clases y eventos ENTRY/EXIT balanceados. Ids deterministas (md5) y `on conflict do nothing`.
- [x] **17.2** `docs: explain how to load the demo seed [17.2]` â€” SecciÃ³n en `README.md` con cÃ³mo correrlo y quÃ© deja cargado.
