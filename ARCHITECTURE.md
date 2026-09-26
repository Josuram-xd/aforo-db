# Architecture — aforo-db

**Repository:** `aforo-db`
**Last updated:** September 26, 2026
**Scope:** One-day pilot, single classroom door.

## 1. Purpose

`aforo-db` defines and provisions the DynamoDB table(s) used by `aforo-backend`. It is infrastructure-as-code only — no application logic lives here.

## 2. Design

A **single-table DynamoDB design** is used, since the access patterns are simple and well-known ahead of time (this is the standard DynamoDB approach — one table, multiple item shapes distinguished by key prefixes).

### Table: `AforoPilot`

| Attribute | Type | Notes |
|---|---|---|
| `PK` | String (partition key) | `EVENT#<date>` for events, `PERSON#<personId>` for people |
| `SK` | String (sort key) | `<timestamp>#<eventId>` for events, `PROFILE` for a person's current state |
| `eventId` | String | present on event items |
| `personId` | String \| null | present on event items |
| `personName` | String \| null | present on event items |
| `direction` | String (`ENTRY` \| `EXIT`) | present on event items |
| `cameraOutsideId` / `cameraInsideId` | String | present on event items |
| `confidence` | Number | present on event items |
| `method` | String (`FACE` \| `BODY_ONLY`) | present on event items |
| `timestamp` | String (ISO 8601) | present on event items |
| `status` | String (`IN` \| `OUT`) | present on person profile items |
| `lastEventAt` | String (ISO 8601) | present on person profile items |

### Access patterns

| Need | How it's served |
|---|---|
| Insert a new event | `PutItem` with `PK = EVENT#<date>`, `SK = <timestamp>#<eventId>` |
| List events in a time range | `Query` on `PK = EVENT#<date>` with `SK` between two timestamps (a Global Secondary Index by full timestamp is added if the pilot needs to query across multiple days) |
| Get/update a person's current status | `GetItem`/`UpdateItem` with `PK = PERSON#<personId>`, `SK = PROFILE` |
| List all enrolled people + status | `Scan` filtered to `SK = PROFILE` (acceptable at this scale — a full course roster, not thousands of rows) |
| Compute current occupancy | Count of `PERSON#*` items with `status = IN` (computed in `aforo-backend`, not in the database itself) |

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

## 4. Tech stack

| Layer | Choice |
|---|---|
| Database | AWS DynamoDB |
| IaC | AWS SAM template (`dynamodb.yaml`) or Terraform module — should match the tool chosen in `aforo-backend` |

## 5. Repository structure

```
aforo-db/
├── ARCHITECTURE.md
├── AGENTS.md
├── PRD.md
├── README.md
└── infra/
    └── dynamodb.yaml     # table definition (AWS SAM) or main.tf (Terraform)
```

## 6. Contract with other repos

`aforo-backend` is the only consumer of this table, via the AWS SDK (boto3), using the table name exported by this repo's IaC output. `aforo-vision` and `aforo-frontend` never talk to DynamoDB directly.
