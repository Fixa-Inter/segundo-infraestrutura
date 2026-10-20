#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

LEGACY=false
DELETE_SECRETS=false

for arg in "$@"; do
  case "$arg" in
    --legacy)
      LEGACY=true
      ;;
    --delete-secrets)
      DELETE_SECRETS=true
      ;;
    *)
      echo "Opcao desconhecida: $arg"
      exit 1
      ;;
  esac
done

for cmd in terraform aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Dependencia ausente: $cmd"
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

if [[ "$LEGACY" == true ]]; then
  # Projeto antigo, com os arquivos .tf na raiz
  TF_DIR="$ROOT"
  PLAN_DIR="$ROOT/.destroy-plans"
  mkdir -p "$PLAN_DIR"
else
  # Projeto novo, com arquivos .tf em terraform/
  TF_DIR="$ROOT/terraform"
  STATE_DIR="$ROOT/.states/$ACCOUNT_ID"
  PLAN_DIR="$STATE_DIR"

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  # Mesma configuracao usada pelo deploy.sh
  export TF_DATA_DIR="$STATE_DIR/.terraform"

  terraform -chdir="$TF_DIR" init \
    -reconfigure \
    -backend-config="path=$STATE_DIR/terraform.tfstate" \
    -input=false
fi

mkdir -p "$PLAN_DIR"
chmod 700 "$PLAN_DIR"

PLAN_FILE="$PLAN_DIR/destroy.tfplan"

echo ""
echo "======================================="
echo "          FIXA - DESTROY"
echo "======================================="
echo "Conta AWS: $ACCOUNT_ID"
echo "Regiao: $REGION"
echo "Projeto: $TF_DIR"
echo "======================================="

# Impede tentar destruir um ambiente sem State
STATE_RESOURCES=$(terraform -chdir="$TF_DIR" state list)

if [[ -z "$STATE_RESOURCES" ]]; then
  echo "Nenhum recurso encontrado no Terraform State."
  echo "Nada sera destruido."
  exit 0
fi

echo ""
echo "Recursos gerenciados pelo Terraform:"
echo "$STATE_RESOURCES"

echo ""
echo "Gerando plano de destruicao..."

terraform -chdir="$TF_DIR" plan \
  -destroy \
  -out="$PLAN_FILE"

echo ""
echo "ATENCAO: os recursos listados acima"
echo "serao removidos da AWS."
echo ""
read -r -p \
  "Digite o ID da conta ($ACCOUNT_ID) para confirmar: " \
  CONFIRM_ACCOUNT

if [[ "$CONFIRM_ACCOUNT" != "$ACCOUNT_ID" ]]; then
  echo "Confirmacao incorreta. Operacao cancelada."
  exit 1
fi

echo ""
echo "Executando destruicao..."

terraform -chdir="$TF_DIR" apply \
  "$PLAN_FILE"

rm -f "$PLAN_FILE"

echo ""
echo "[OK] Destruicao Terraform concluida."

if [[ "$DELETE_SECRETS" == true ]]; then
  echo ""
  echo "Limpeza opcional dos segredos SSM."
  echo "Prefixo: /fixa/"

  read -r -p \
    "Digite APAGAR-SEGREDOS para confirmar: " \
    CONFIRM_SECRETS

  if [[ "$CONFIRM_SECRETS" == "APAGAR-SEGREDOS" ]]; then
    python3 - <<'PY'
import boto3

ssm = boto3.client("ssm", region_name="us-east-1")
paginator = ssm.get_paginator("get_parameters_by_path")

names = []

for page in paginator.paginate(
    Path="/fixa/",
    Recursive=True,
    WithDecryption=False,
):
    for parameter in page.get("Parameters", []):
        name = parameter["Name"]
        if name.startswith("/fixa/"):
            names.append(name)

for index in range(0, len(names), 10):
    batch = names[index:index + 10]
    response = ssm.delete_parameters(Names=batch)

    for name in response.get("DeletedParameters", []):
        print(f"[OK] Excluido: {name}")

    for name in response.get("InvalidParameters", []):
        print(f"[AVISO] Nao excluido: {name}")

print("Limpeza de parametros concluida.")
PY
  else
    echo "Segredos SSM preservados."
  fi
else
  echo "Segredos SSM preservados."
fi

echo ""
echo "Dominio e DNS da Hostinger preservados."
echo "Operacao concluida."