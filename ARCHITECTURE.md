# Architecture — aforo-db

**Repository:** `aforo-db`
**Last updated:** October 8, 2026
**Scope:** One-day pilot, single classroom door.

> **Version 2 planned (section 7).** Sections 1-6 describe the DynamoDB design that is deployed today (v1).
> After the first project review, the data layer moves to PostgreSQL on Supabase with a relational
> schema, user accounts and row-level security. Section 7 is the target; v1 stays running until the
> v2 tasks in `TASKS.md` (tasks 7-10) are done.

## 1. Purpose

`aforo-db` defines and provisions the DynamoDB table(s) used by `aforo-backend`. It is infrastructure-as-code only — no application logic lives here.

## 2. Design

A **single-table DynamoDB design** is used, since the access patterns are simple and well-known ahead of time (this is the standard DynamoDB approach — one table, multiple item shapes distinguished by key prefixes).

### Table: `AforoPilot`

| Attribute | Type | Notes |
|---|---|---|
| `PK` | String (partition key) | `EVENT#<date>` for events, `PERSON#<personId>` for people, `AFORO` for the occupancy counter |
| `SK` | String (sort key) | `<timestamp>#<eventId>` for events, `PROFILE` for a person's current state, `CURRENT` for the occupancy counter |
| `currentOccupancy` | Number | present only on the counter item (`PK = AFORO`, `SK = CURRENT`) |
| `eventId` | String | present on event items |
| `personId` | String \| null | present on event items; String on person profile items |
| `personName` | String \| null | present on event items |
| `direction` | String (`ENTRY` \| `EXIT`) | present on event items |
| `cameraOutsideId` / `cameraInsideId` | String | present on event items |
| `confidence` | Number | present on event items |
| `method` | String (`FACE` \| `BODY_ONLY`) | present on event items |
| `timestamp` | String (ISO 8601) | present on event items |
| `name` | String | present on person profile items (from the roster, no biometrics) |
| `status` | String (`IN` \| `OUT`) | present on person profile items |
| `lastEventAt` | String (ISO 8601) | present on person profile items |

### Access patterns

| Need | How it's served |
|---|---|
| Insert a new event | `PutItem` with `PK = EVENT#<date>`, `SK = <timestamp>#<eventId>` |
| List events in a time range | `Query` on `PK = EVENT#<date>` with `SK` between two timestamps (a Global Secondary Index by full timestamp is added if the pilot needs to query across multiple days) |
| Get/update a person's current status | `GetItem`/`UpdateItem` with `PK = PERSON#<personId>`, `SK = PROFILE` |
| List all enrolled people + status | `Scan` filtered to `SK = PROFILE` (acceptable at this scale — a full course roster, not thousands of rows) |
| Read/update current occupancy | `UpdateItem` on `PK = AFORO`, `SK = CURRENT` with `ADD currentOccupancy :delta` (+1 on `ENTRY`, -1 on `EXIT`, never below 0); `GetItem` to read it |

## 3. Architecture Decision Records

### ADR-001: Single DynamoDB table, not one table per entity
**Decision**: Events and people live in one table (`AforoPilot`), distinguished by key prefix.
**Why**: this is DynamoDB's recommended pattern, avoids extra tables (and extra "Always Free" allowances to track), and the pilot's total data volume is trivial (one course, one day).

### ADR-002: No relational database
**Decision**: DynamoDB, not PostgreSQL/MySQL/RDS.
**Why**: no server to provision or pay for when idle; DynamoDB has a permanent free tier; the access patterns here (append events, query by time, read/update a status flag) fit a key-value/wide-column model well and don't need joins or transactions across many tables.

### ADR-003: Infrastructure as code
**Decision**: The table is defined in code (AWS SAM template or Terraform, matching whatever `aforo-backend` uses for its own deployment) and deployed via CLI, not created manually in the AWS console.
**Why**: reproducibility — if the pilot needs to be redeployed (e.g., a rehearsal run before the real day), the whole stack can be recreated identically.

### ADR-004: Occupancy as an atomic counter item, not derived from person status
**Decision**: Current occupancy is stored in a dedicated counter item (`AFORO` / `CURRENT`) updated atomically on every event.
**Why**: deriving it from `PERSON#*` items with `status = IN` would silently ignore every `BODY_ONLY` event (people counted but not identified have no person profile), so the dashboard would under-count. A counter updated from every event — identified or not — matches the PRD definition (entries minus exits).

### ADR-005: Provisioned capacity inside the Always Free tier
**Decision**: The table uses `PROVISIONED` billing with 5 RCU / 5 WCU, not on-demand.
**Why**: DynamoDB's permanent free tier covers up to 25 RCU / 25 WCU of provisioned capacity; on-demand is billed per request and is not part of that allowance. A few dozen events per pilot day fit comfortably in 5/5.

## 4. Tech stack

| Layer | Choice |
|---|---|
| Database | AWS DynamoDB (`PROVISIONED`, 5 RCU / 5 WCU) |
| IaC | AWS SAM template (`dynamodb.yaml`) or Terraform module — should match the tool chosen in `aforo-backend` |

## 5. Repository structure

```
aforo-db/
├── ARCHITECTURE.md
├── AGENTS.md
├── PRD.md
├── README.md
├── TASKS.md
├── infra/
│   └── dynamodb.yaml     # table definition (AWS SAM / CloudFormation)
└── scripts/
    ├── deploy.sh
    ├── seed_people.py    # loads roster.json (personId + name, no biometrics)
    ├── roster.example.json
    └── reset_pilot.py    # clears events and resets counter/statuses after a rehearsal
```

## 6. Contract with other repos

`aforo-backend` is the only consumer of this table, via the AWS SDK (boto3), using the table name exported by this repo's IaC output. `aforo-vision` and `aforo-frontend` never talk to DynamoDB directly.

## 7. Version 2 — PostgreSQL on Supabase (planned)

### 7.1 Why v2

Feedback from the first project review (October 2026):
- The data model was too small (one table, three item shapes) for the course's expectations; a relational model with explicit entities and relations is expected (~10+ tables).
- There was no user registration or login, and every `GET` endpoint was public: anyone with the URL could read student names.
- The AWS API had no rate limit, so it could be abused to generate cost.

### 7.2 Target platform

| Concern | v1 (today) | v2 (target) |
|---|---|---|
| Database | DynamoDB, single table `AforoPilot` | PostgreSQL 17 on Supabase (Free plan) |
| Users and login | none | Supabase Auth: sign-up, email + password, Google OAuth, password reset |
| Authorization | none on reads | Row Level Security (RLS) per role: `admin`, `teacher`, `viewer` |
| Writes from `aforo-vision` | `POST /events` (Lambda) + shared secret | RPC `ingest_event` + per-classroom device key (`X-Device-Key`) |
| Live updates | polling every 3 s | Supabase Realtime (Postgres changes, RLS-aware) |
| Audit | none | `audit_log` table filled by triggers + `log_access` RPC |
| IaC | SAM templates in `infra/` | SQL migrations in `supabase/migrations/` (Supabase CLI) |

The Supabase project lives in a **team account**, not in a personal one (the personal accounts already use their two free projects). Team members are invited with the `Developer` role. Region: `us-east-1` (lowest latency from Colombia).

### 7.3 Relational schema (13 tables)

Names in English, as in the rest of the project. Draft migrations: `supabase/migrations/2026100800000{1..4}_*.sql`.

| # | Table | Purpose | Key relations |
|---|---|---|---|
| 1 | `roles` | Catalog: `admin`, `teacher`, `viewer` | — |
| 2 | `profiles` | One row per Supabase Auth user (email, name, avatar, `is_active`) | `id` → `auth.users.id` |
| 3 | `user_roles` | Role assignment, with who granted it | `profiles`, `roles` |
| 4 | `courses` | Courses being monitored (one today, extensible) | — |
| 5 | `classrooms` | Rooms with `max_capacity` and the atomic `current_occupancy` counter | — |
| 6 | `cameras` | The two checkpoints per room (`outside` / `inside`), status and last heartbeat. No stream URL or credentials | `classrooms` |
| 7 | `students` | Enrolled people; `id` = the `personId` generated by `aforo-vision`. Current `presence` (`IN`/`OUT`). **No biometrics** | — |
| 8 | `course_students` | Which students belong to which course (N:M) | `courses`, `students` |
| 9 | `class_sessions` | A monitored class (course + room + time window) | `courses`, `classrooms`, `profiles` |
| 10 | `events` | Every door crossing (same contract as v1; `id` = `eventId`, idempotent) | `classrooms`, `class_sessions`, `students`, `cameras` |
| 11 | `attendance` | Per session and student: first entry, last exit, status | `class_sessions`, `students` |
| 12 | `alerts` | `capacity_exceeded`, `camera_offline`; open/resolved | `classrooms`, `cameras`, `profiles` |
| 13 | `audit_log` | Who changed or viewed what (triggers + `log_access`) | `profiles` |

Plus `private.device_keys` (not exposed by the API): SHA-256 hash of each classroom's device key, with a per-minute request counter. Not counted as an app table.

Out of scope by decision: no consent table (signed forms stay on paper, per `aforo-vision/docs`). One course, one classroom and two cameras are seeded, but the model supports more.

### 7.4 Business logic in the database

- **`handle_new_user`** (trigger on `auth.users`): creates the profile and assigns `viewer`. Admins promote users with `set_user_role`.
- **`apply_event`** (trigger on `events`): updates `classrooms.current_occupancy` (never below 0, same rule as v1 ADR-004), the student's `presence`, the `attendance` row of the matching session, and opens/closes the `capacity_exceeded` alert.
- **`ingest_event(p_event)`** (RPC, callable without a user session): validates the device key and the rate limit (120 req/min per key), validates the event contract, resolves cameras and session, inserts with `on conflict do nothing` (retries never double-count).
- **`camera_heartbeat(code, online)`** (RPC): updates camera status and opens/closes `camera_offline` alerts.
- **`audit_change`** (trigger on catalog tables): writes `audit_log`; skips automatic counter/status updates.

### 7.5 Security model

| Role | Can read | Can write |
|---|---|---|
| no session (`anon`) | nothing | only `ingest_event` / `camera_heartbeat`, and only with a valid device key |
| `viewer` | rooms + occupancy, cameras, sessions, alerts (no student names) | own profile |
| `teacher` | + students, events, attendance | class sessions, resolve alerts |
| `admin` | everything, including users and `audit_log` | everything (roles via `set_user_role`, accounts via `set_user_active`) |

- RLS is enabled on every table; table grants are revoked from `anon`. A deactivated profile loses all permissions.
- The publishable key is public by design; it grants nothing without RLS policies. The service-role key is used only by admin scripts on a trusted machine and never shipped to the browser or committed.
- Security definer functions use `set search_path = ''`. After each migration, the Supabase security and performance advisors must report no errors.

### 7.6 ADRs for v2

**ADR-006: Relational PostgreSQL on Supabase replaces DynamoDB.** Supersedes ADR-001, ADR-002 and ADR-005.
**Why**: the project now has real entities with relations (users, roles, courses, rooms, cameras, sessions, attendance, alerts, audit) and needs joins, constraints and per-row authorization. Supabase gives PostgreSQL, Auth (including Google), RLS and Realtime on a free plan, so login and security do not need custom servers.
**Trade-off**: the stack is no longer AWS-only; the Free plan pauses a project after a week without activity, and has 500 MB of database storage (enough for this volume).

**ADR-007: Authorization lives in the database (RLS), not in an API layer.** The browser talks to Supabase directly with the user's JWT; policies decide what each role sees. Hiding UI elements is never the access control.

**ADR-008: Occupancy stays an atomic counter** (keeps v1 ADR-004), now a column in `classrooms` updated by the `apply_event` trigger.

**ADR-009: Devices authenticate with a per-classroom key, not with a user account.** `aforo-vision` is a machine client; its key is stored only as a hash and can be revoked without touching user accounts.
