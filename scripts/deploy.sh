#!/usr/bin/env bash
# Despliega (o actualiza) el stack de CloudFormation con la tabla AforoPilot.
# Uso: ./scripts/deploy.sh
# Variables opcionales: STACK_NAME (por defecto aforo-db) y REGION (por defecto us-east-1,
# la misma región de aforo-backend, necesaria para que pueda importar los exports).
set -euo pipefail

STACK_NAME="${STACK_NAME:-aforo-db}"
REGION="${REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../infra/dynamodb.yaml"

echo "Desplegando stack '$STACK_NAME' en $REGION..."

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table
