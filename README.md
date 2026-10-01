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

Todo se despliega con CloudFormation en la región `us-east-1` (la misma de `aforo-backend`, para que pueda importar los exports). No crees nada a mano en la consola de AWS.

### 1. Configurar el AWS CLI

1. Instala el [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) y comprueba la instalación:
   ```bash
   aws --version
   ```
2. Si todavía no tienes un usuario de IAM con access keys, créalo en la consola de AWS (con permisos sobre CloudFormation, DynamoDB y Budgets). No uses las claves del usuario root. Si ya tienes uno configurado (por ejemplo, el que usas para `aforo-backend`), reutilízalo y salta al paso 4.
3. Configura las credenciales y la región:
   ```bash
   aws configure
   # AWS Access Key ID:     <tu access key>
   # AWS Secret Access Key: <tu secret key>
   # Default region name:   us-east-1
   # Default output format: json
   ```
4. Verifica que el CLI apunta a la cuenta correcta:
   ```bash
   aws sts get-caller-identity
   ```

En Windows, ejecuta los comandos de bash desde **Git Bash**.

### 2. Desplegar

```bash
NOTIFICATION_EMAIL=tu-correo@ejemplo.com ./scripts/deploy.sh
```

El script despliega dos stacks:

| Stack | Plantilla | Qué crea |
|---|---|---|
| `aforo-budget` | `infra/budget.yaml` | Alerta mensual de AWS Budgets que avisa al correo si el gasto real (sin descontar créditos) supera 1 USD |
| `aforo-db` | `infra/dynamodb.yaml` | Tabla `AforoPilot` (5 RCU / 5 WCU, dentro del Always Free) y los exports `AforoPilotTableName` y `AforoPilotTableArn` |

`NOTIFICATION_EMAIL` es obligatoria y se pasa siempre por variable: el repositorio es público y el correo no debe quedar versionado. Variables opcionales: `STACK_NAME`, `BUDGET_STACK_NAME` y `REGION` (ver el encabezado de `scripts/deploy.sh`).

El script se puede volver a correr después de cambiar una plantilla: CloudFormation solo aplica las diferencias, y si no hay cambios termina sin error.

### 3. Verificar

Al terminar, el script imprime los outputs del stack de la tabla. También puedes comprobarlo a mano:

```bash
# La tabla existe y está activa
aws dynamodb describe-table --table-name AforoPilot --region us-east-1 \
  --query "Table.[TableStatus, ProvisionedThroughput.ReadCapacityUnits, ProvisionedThroughput.WriteCapacityUnits]"

# Los exports que usa aforo-backend
aws cloudformation list-exports --region us-east-1 \
  --query "Exports[?starts_with(Name, 'AforoPilot')].[Name, Value]" --output table

# La alerta de presupuesto
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query "Budgets[?BudgetName=='aforo-monthly-budget'].[BudgetName, BudgetLimit.Amount]"
```

En la consola: **DynamoDB → Tables** debe mostrar `AforoPilot`, **CloudFormation → Exports** los dos exports y **Billing → Budgets** el presupuesto `aforo-monthly-budget`.

### Borrar los stacks

La tabla tiene `DeletionPolicy: Retain`: si borras el stack `aforo-db`, la tabla **y los datos del piloto se conservan**. Borrar la tabla es una decisión aparte y manual. Mientras `aforo-backend` importe los exports, CloudFormation no permite borrar el stack `aforo-db`.
