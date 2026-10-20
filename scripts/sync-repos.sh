
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="$ROOT/apps"

declare -A REPOS=(
  [mobile]="segundo-api-app"
  [web]="segundo-api-web"
  [nosql]="segundo-api-nosql"
  [ia]="segundo-inteligencia-artificial"
)

BACKENDS=(mobile web nosql ia)
SELECTED="${1:-all}"

command -v git >/dev/null || {
  echo "Git nao instalado"
  exit 1
}

mkdir -p "$APPS_DIR"

sync_repo() {
  local backend="$1"
  local repo="${REPOS[$backend]}"
  local url="https://github.com/Fixa-Inter/${repo}.git"
  local dest="${APPS_DIR}/${backend}"

  echo ""
  echo "Sincronizando $backend..."

  if [[ ! -d "$dest" ]]; then
    git clone --branch main "$url" "$dest"
  else
    if [[ ! -d "$dest/.git" ]]; then
      echo "ERRO: $dest nao e um repositorio Git"
      return 1
    fi

    # Verifica se o checkout corresponde ao repo esperado
    local origin
    origin=$(git -C "$dest" remote get-url origin)

    if [[ "$origin" != "$url" ]]; then
      echo "ERRO: origin inesperado em $dest"
      echo "Encontrado: $origin"
      return 1
    fi

    # Nunca descarta mudancas locais silenciosamente
    if [[ -n "$(git -C "$dest" status --porcelain)" ]]; then
      echo "ERRO: existem alteracoes locais em $dest"
      echo "Salve ou reverta antes de sincronizar."
      return 1
    fi

    if [[ "$(git -C "$dest" branch --show-current)" != "main" ]]; then
      echo "ERRO: branch local diferente de main"
      return 1
    fi

    git -C "$dest" fetch origin main
    git -C "$dest" merge --ff-only origin/main
  fi

  if [[ ! -f "$dest/Dockerfile" ]]; then
    echo "ERRO: Dockerfile ausente em $dest"
    return 1
  fi

  echo "Commit utilizado:"
  git -C "$dest" rev-parse --short HEAD
}

if [[ "$SELECTED" == "all" ]]; then
  for backend in "${BACKENDS[@]}"; do
    sync_repo "$backend"
  done
elif [[ -n "${REPOS[$SELECTED]:-}" ]]; then
  sync_repo "$SELECTED"
else
  echo "Uso: $0 mobile|web|nosql|ia|all"
  exit 1
fi

echo ""
echo "[OK] Repositorios sincronizados."