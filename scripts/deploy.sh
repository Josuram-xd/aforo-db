#!/usr/bin/env bash
# Despliega (o actualiza) los stacks de CloudFormation de aforo-db:
#   1. La alerta de presupuesto mensual (infra/budget.yaml).
#   2. La tabla AforoPilot (infra/dynamodb.yaml).
# Uso: NOTIFICATION_EMAIL=tu-correo@ejemplo.com ./scripts/deploy.sh
# Variable obligatoria:
#   NOTIFICATION_EMAIL correo que recibe la alerta de presupuesto
#                      (no se guarda en el repo porque es público)
# Variables opcionales:
#   STACK_NAME         stack de la tabla (por defecto aforo-db)
#   BUDGET_STACK_NAME  stack del presupuesto (por defecto aforo-budget)
#   REGION             por defecto us-east-1, la misma región de aforo-backend,
#                      necesaria para que pueda importar los exports
set -euo pipefail

STACK_NAME="${STACK_NAME:-aforo-db}"
BUDGET_STACK_NAME="${BUDGET_STACK_NAME:-aforo-budget}"
REGION="${REGION:-us-east-1}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:?Define NOTIFICATION_EMAIL con el correo para la alerta de presupuesto}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../infra"

# El presupuesto va primero: así la alerta ya existe antes de crear recursos.
echo "Desplegando stack '$BUDGET_STACK_NAME' en $REGION..."

aws cloudformation deploy \
  --stack-name "$BUDGET_STACK_NAME" \
  --template-file "$INFRA_DIR/budget.yaml" \
  --region "$REGION" \
  --parameter-overrides "NotificationEmail=$NOTIFICATION_EMAIL" \
  --no-fail-on-empty-changeset

echo "Desplegando stack '$STACK_NAME' en $REGION..."

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$INFRA_DIR/dynamodb.yaml" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table
