# aforo-db

Infraestructura como código de la tabla DynamoDB `AforoPilot` que usa `aforo-backend` para guardar los eventos de entrada/salida, el estado de las personas enroladas y el contador de aforo del piloto.

Este repositorio **no** contiene lógica de negocio: solo la definición de la tabla y scripts de apoyo para desplegarla y preparar los datos del piloto.

## Estructura

```
aforo-db/
├── infra/      # plantillas CloudFormation / SAM (tabla, alerta de presupuesto)
├── scripts/    # despliegue, carga del roster y reinicio del piloto
├── PRD.md
├── ARCHITECTURE.md
├── AGENTS.md
└── TASKS.md
```

## Documentación

- [`PRD.md`](PRD.md) — problema, objetivos y restricciones.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — diseño de tabla única, patrones de acceso y ADRs.
- [`AGENTS.md`](AGENTS.md) — reglas para asistentes de IA en este repo.
- [`TASKS.md`](TASKS.md) — plan de trabajo y estado de las tareas.

## Privacidad

El roster real (`roster.json`) contiene nombres de personas y **no se versiona** (está en `.gitignore`). Usa `scripts/roster.example.json` como plantilla.

## Despliegue

Los pasos para configurar el AWS CLI y desplegar la tabla se documentarán en la task 3.2.
