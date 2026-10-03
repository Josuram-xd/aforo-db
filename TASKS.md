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
- [ ] **4.3** `feat(scripts): add reset pilot script` — `scripts/reset_pilot.py`: borra los eventos, pone el contador `AFORO` / `CURRENT` en 0 y todas las personas en `OUT`. Se usa después del ensayo, antes del día real.

---

## Prioridad 2 — Importante

### Task 5 — Retención de datos (privacidad)
- [ ] **5.1** `feat(infra): enable ttl on expires at attribute` — Activar TTL sobre `expiresAt` para que los eventos (que tienen nombres) se borren solos unos días después del piloto (principio de mínima retención, Ley 1581). Después sigue con la task 9.3 del repo: `aforo-backend`.

---

## Prioridad 3 — Extras

### Task 6 — Consultas de varios días
- [ ] **6.1** `feat(infra): add gsi on timestamp` — Índice secundario global por `timestamp`. Solo si el piloto termina durando más de un día.
