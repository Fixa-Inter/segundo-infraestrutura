#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="us-east-1"

BACKEND="${1:-}"
VERSION="${2:-}"

VALID_BACKENDS=("mobile" "web" "nosql" "ia")

if [[ -z "$BACKEND" ]]; then
  echo "Uso: $0 mobile|web|nosql|ia|all [versao]"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
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
  local commit receipt digest recipe base_image
  commit=$(git -C "$app_dir" rev-parse HEAD)
  recipe=$(python3 - "$ROOT" "$api" <<'PYCODE'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]);api=sys.argv[2]
paths=[root/'apps'/api/'Dockerfile']
if api=='mobile':
    paths += [root/'runtime/mobile'/name for name in ('Dockerfile','entrypoint.py','.dockerignore')]
h=hashlib.sha256()
for p in paths:
    h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PYCODE
)
  receipt="$ROOT/.states/$ACCOUNT_ID/$REGION/images/${api}-${VERSION}.json"
  mkdir -p "$(dirname "$receipt")"

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
  if digest=$(aws ecr describe-images \
    --repository-name "$repo" --image-ids "imageTag=${VERSION}" \
    --region "$REGION" --query 'imageDetails[0].imageDigest' --output text 2>"${receipt}.error"); then
    python3 - "$receipt" "$commit" "$digest" "$recipe" <<'PYCODE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
if not p.is_file():
    sys.exit('Tag existente sem comprovante local do build. Escolha uma nova versao.')
x=json.loads(p.read_text())
if x['commit']!=sys.argv[2] or x['digest']!=sys.argv[3] or x.get('recipe')!=sys.argv[4]:
    sys.exit('Tag imutavel pertence a outro commit/digest/receita de imagem. Escolha uma nova versao.')
PYCODE
    echo "[OK] Imagem existente corresponde ao commit/digest registrado: $api:$VERSION"
    return
  else
    if ! grep -q 'ImageNotFoundException' "${receipt}.error"; then
      echo "Erro ao consultar imagem ECR; build interrompido para nao confundir permissao/rede com imagem ausente."
      return 1
    fi
  fi
  rm -f "${receipt}.error"

  echo ""
  echo "Construindo ${api}:${VERSION}..."

  if [[ "$api" == mobile ]]; then
    base_image="fixa-mobile-build:$VERSION"
    docker build --platform linux/amd64 -t "$base_image" "$app_dir"
    # Contexto limitado a runtime/mobile: nunca envia env/firebase.json ao Docker.
    docker build --platform linux/amd64 \
      --build-arg "BASE_IMAGE=$base_image" \
      --label "org.opencontainers.image.revision=$commit" \
      -t "$image" "$ROOT/runtime/mobile"
  else
    docker build --platform linux/amd64 \
      --label "org.opencontainers.image.revision=$commit" \
      -t "$image" "$app_dir"
  fi

  echo "Enviando ${image}..."

  docker push "$image"

  echo "Verificando imagem publicada..."

  digest=$(aws ecr describe-images \
    --repository-name "$repo" --image-ids "imageTag=${VERSION}" \
    --region "$REGION" --query 'imageDetails[0].imageDigest' --output text)
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "Digest ECR invalido"; exit 1; }
  python3 - "$receipt" "$commit" "$digest" "$recipe" <<'PYCODE'
import json,sys,os
from pathlib import Path
os.umask(0o077)
p=Path(sys.argv[1]); temp=p.with_suffix('.tmp')
temp.write_text(json.dumps({'commit':sys.argv[2],'digest':sys.argv[3],'recipe':sys.argv[4]}))
temp.replace(p)
PYCODE

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

# Autentica o Docker sem exibir senha.
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