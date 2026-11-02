#!/usr/bin/env bash
# Ciclo de vida do bucket comum sem consultar Object Lock.
set -euo pipefail
umask 077
MODE="${1:-}"
: "${FIXA_BUCKET_NAME:?Nome do bucket ausente}"
: "${FIXA_BUCKET_OWNER:?Conta do bucket ausente}"
: "${FIXA_BUCKET_REGION:?Regiao do bucket ausente}"
[[ "$FIXA_BUCKET_REGION" == us-east-1 ]] || { echo 'Regiao inesperada'; exit 1; }
[[ "$FIXA_BUCKET_OWNER" =~ ^[0-9]{12}$ ]] || { echo 'Conta invalida'; exit 1; }
[[ "$FIXA_BUCKET_NAME" == "fixa-secrets-$FIXA_BUCKET_OWNER-$FIXA_BUCKET_REGION" ]] || { echo 'Nome de bucket inesperado'; exit 1; }
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$FIXA_BUCKET_REGION" --no-cli-pager)
[[ "$CURRENT_ACCOUNT" == "$FIXA_BUCKET_OWNER" ]] || { echo 'Conta AWS diverge do bucket'; exit 1; }
ERROR_FILE=$(mktemp)
trap 'rm -f "$ERROR_FILE"' EXIT
if aws s3api head-bucket --bucket "$FIXA_BUCKET_NAME" \
  --expected-bucket-owner "$FIXA_BUCKET_OWNER" --region "$FIXA_BUCKET_REGION" \
  --no-cli-pager 2>"$ERROR_FILE"; then
  EXISTS=true
elif grep -Eq '\((404|NotFound|NoSuchBucket)\)' "$ERROR_FILE"; then
  EXISTS=false
else
  echo '[ERRO] Nao foi possivel consultar bucket/proprietario. Confira permissao S3 e rede.' >&2
  exit 1
fi
case "$MODE" in
  ensure)
    if [[ "$EXISTS" == false ]]; then
      aws s3api create-bucket --bucket "$FIXA_BUCKET_NAME" \
        --region "$FIXA_BUCKET_REGION" --no-cli-pager >/dev/null
      aws s3api wait bucket-exists --bucket "$FIXA_BUCKET_NAME" \
        --expected-bucket-owner "$FIXA_BUCKET_OWNER" --region "$FIXA_BUCKET_REGION" --no-cli-pager
    fi
    echo '[OK] Bucket Firebase disponivel. Protecoes serao aplicadas pelo Terraform.'
    ;;
  delete)
    if [[ "$EXISTS" == true ]]; then
      # Sem --force: bucket nao vazio impede a exclusao.
      aws s3api delete-bucket --bucket "$FIXA_BUCKET_NAME" \
        --expected-bucket-owner "$FIXA_BUCKET_OWNER" --region "$FIXA_BUCKET_REGION" --no-cli-pager
    fi
    ;;
  *) echo 'Modo invalido: use ensure ou delete' >&2; exit 1 ;;
esac
