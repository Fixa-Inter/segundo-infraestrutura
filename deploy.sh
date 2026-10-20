
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT}/terraform"
REGION="us-east-1"
VERSION="${1:-v1}"

for cmd in aws terraform docker git python3; do
  command -v "$cmd" >/dev/null || {
    echo "Dependencia ausente: $cmd"
    exit 1
  }
done

if [[ ! "$VERSION" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Versao de imagem invalida"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

STATE_DIR="${ROOT}/.states/${ACCOUNT_ID}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

export TF_DATA_DIR="${STATE_DIR}/.terraform"
export AWS_DEFAULT_REGION="$REGION"

echo "===================================="
echo "      FIXA - DEPLOY AUTOMATICO"
echo "===================================="
echo "Conta: $ACCOUNT_ID"
echo "Regiao: $REGION"
echo "Versao: $VERSION"
echo ""

# Etapa 1: prepara Terraform
echo "[1/4] Inicializando Terraform..."

terraform -chdir="$TF_DIR" init \
  -reconfigure \
  -backend-config="path=${STATE_DIR}/terraform.tfstate" \
  -input=false

terraform -chdir="$TF_DIR" validate

# Etapa 2: cria infraestrutura declarada
echo "[2/4] Planejando infraestrutura..."

terraform -chdir="$TF_DIR" plan \
  -out="${STATE_DIR}/deploy.tfplan"

read -r -p \
  "Aplicar o plano acima? (sim/nao): " \
  CONFIRM

if [[ "$CONFIRM" != "sim" ]]; then
  echo "Operacao cancelada."
  exit 0
fi

terraform -chdir="$TF_DIR" apply \
  "${STATE_DIR}/deploy.tfplan"

rm -f "${STATE_DIR}/deploy.tfplan"

# Etapa 4: compila e publica imagens
echo "[4/4] Construindo e publicando Docker..."

# build-images.sh ja identifica a conta e
# envia as imagens para os respectivos ECRs.
"$ROOT/scripts/build-images.sh" all "$VERSION"

echo ""
echo "[5/5] Sincronizando variaveis e segredos..."

"$ROOT/scripts/setup-env.sh"

echo ""
read -r -p \
  "Ativar as quatro APIs agora? (sim/nao): " \
  ACTIVATE

if [[ "$ACTIVATE" == "sim" ]]; then
  "$ROOT/scripts/activate-apis.sh" "$VERSION"
fi

echo ""
echo "===================================="
echo "   FIXA - PREPARACAO CONCLUIDA"
echo "===================================="
echo "Conta AWS: $ACCOUNT_ID"
echo "Versao Docker: $VERSION"
echo "Segredos SSM sincronizados."
echo ""
echo "Proxima fase: ativacao dos ECS Services."