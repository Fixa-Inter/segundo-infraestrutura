#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
REGION="us-east-1"

VERSION="${1:-v1}"

if [[ ! "$VERSION" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Versao invalida."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

STATE_DIR="$ROOT/.states/$ACCOUNT_ID"

if [[ ! -f "$STATE_DIR/terraform.tfstate" ]]; then
  echo "ERRO: State da conta nao encontrado."
  echo "Execute primeiro o deploy de infraestrutura."
  exit 1
fi

export TF_DATA_DIR="$STATE_DIR/.terraform"
export AWS_DEFAULT_REGION="$REGION"

# Inicializa o backend da conta atual
terraform -chdir="$TF_DIR" init \
  -reconfigure \
  -backend-config="path=$STATE_DIR/terraform.tfstate" \
  -input=false

echo "Conta AWS: $ACCOUNT_ID"
echo "Versao das imagens: $VERSION"

# Verifica se o certificado foi emitido
CERT_ARN=$(terraform -chdir="$TF_DIR" \
  output -raw acm_certificate_arn)

CERT_STATUS=$(aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region "$REGION" \
  --query 'Certificate.Status' \
  --output text)

if [[ "$CERT_STATUS" != "ISSUED" ]]; then
  echo "ERRO: certificado ACM ainda nao emitido."
  echo "Estado: $CERT_STATUS"
  echo ""
  echo "Registros de validacao:"
  terraform -chdir="$TF_DIR" \
    output acm_validation_records
  exit 1
fi

echo "[OK] Certificado ACM emitido."

# Verifica as imagens
for api in mobile web nosql ia; do
  echo "Verificando imagem: $api:$VERSION"

  aws ecr describe-images \
    --repository-name "fixa/${api}-api" \
    --image-ids "imageTag=$VERSION" \
    --region "$REGION" \
    >/dev/null

  test -f "$ROOT/env/${api}.public.env"
  test -f "$ROOT/env/${api}.secrets.json"
done

echo "[OK] Imagens e manifestos encontrados."

# Configura o Terraform sem modificar arquivos .tf
IMAGE_TAGS=$(python3 - "$VERSION" <<'PY'
import json
import sys

print(json.dumps({
    name: sys.argv[1]
    for name in ("mobile", "web", "nosql", "ia")
}))
PY
)

PLAN_FILE="$STATE_DIR/activate.tfplan"

echo ""
echo "Gerando plano de ativacao..."

terraform -chdir="$TF_DIR" plan \
  -out="$PLAN_FILE"

echo ""
read -r -p "Ativar as quatro APIs? (sim/nao): " CONFIRM

if [[ "$CONFIRM" != "sim" ]]; then
  rm -f "$PLAN_FILE"
  echo "Operacao cancelada."
  exit 0
fi

terraform -chdir="$TF_DIR" apply "$PLAN_FILE"

rm -f "$PLAN_FILE"

echo ""
echo "[OK] Terraform aplicado."

aws ecs describe-services \
  --cluster cluster-fixa \
  --services \
    fixa-mobile-api-service \
    fixa-web-api-service \
    fixa-nosql-api-service \
    fixa-ia-api-service \
  --region "$REGION" \
  --query 'services[].{
    Nome:serviceName,
    Estado:status,
    Desejadas:desiredCount,
    Executando:runningCount
  }' \
  --output table

echo ""
echo "Ativacao enviada ao ECS."
echo "Confira a saude dos Target Groups antes do DNS."