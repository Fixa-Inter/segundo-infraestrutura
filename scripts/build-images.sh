#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="us-east-1"

BACKEND="${1:-}"
VERSION="${2:-v1}"

VALID_BACKENDS=("mobile" "web" "nosql" "ia")

if [[ -z "$BACKEND" ]]; then
  echo "Uso: $0 mobile|web|nosql|ia|all [versao]"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "Tag Docker invalida."
  exit 1
fi

for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Dependencia ausente: $cmd"
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker nao esta funcionando."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

build_and_push() {
  local api="$1"
  local app_dir="${ROOT}/apps/${api}"
  local repo="fixa/${api}-api"
  local image="${REGISTRY}/${repo}:${VERSION}"

  if [[ ! -f "${app_dir}/Dockerfile" ]]; then
    echo "Dockerfile nao encontrado em apps/${api}/"
    exit 1
  fi

  # O repositório deve ter sido criado pelo Terraform.
  aws ecr describe-repositories \
    --repository-names "$repo" \
    --region "$REGION" \
    >/dev/null

  # Como as tags são imutáveis, não sobrescrevemos.
  if aws ecr describe-images \
    --repository-name "$repo" \
    --image-ids "imageTag=${VERSION}" \
    --region "$REGION" \
    >/dev/null 2>&1; then
    echo "A imagem ${repo}:${VERSION} ja existe."
    echo "Escolha outra versao para publicar alteracoes."
    return
  fi

  echo ""
  echo "Construindo ${api}:${VERSION}..."

  docker build \
    --platform linux/amd64 \
    -t "$image" \
    "$app_dir"

  echo "Enviando ${image}..."

  docker push "$image"

  echo "Verificando imagem publicada..."

  aws ecr describe-images \
    --repository-name "$repo" \
    --image-ids "imageTag=${VERSION}" \
    --region "$REGION" \
    --query 'imageDetails[0].imageDigest' \
    --output text

  echo "[OK] ${api}:${VERSION}"
}

# Atualiza o codigo antes de construir as imagens
"${ROOT}/scripts/sync-repos.sh" "$BACKEND"

if [[ "$BACKEND" == "all" ]]; then
  SELECTED=("${VALID_BACKENDS[@]}")
else
  case " ${VALID_BACKENDS[*]} " in
    *" $BACKEND "*) SELECTED=("$BACKEND") ;;
    *)
      echo "Backend desconhecido: $BACKEND"
      exit 1
      ;;
  esac
fi

echo "Conta AWS: ${ACCOUNT_ID}"
echo "Regiao: ${REGION}"

# Faz login somente quando existe imagem a publicar.
echo "Autenticando no ECR..."

aws ecr get-login-password --region "$REGION" |
  docker login \
    --username AWS \
    --password-stdin "$REGISTRY"

for api in "${SELECTED[@]}"; do
  build_and_push "$api"
done

echo ""
echo "Publicacao concluida."