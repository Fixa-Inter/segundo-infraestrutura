#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verifica se os arquivos estao disponiveis
"$ROOT/scripts/check-env.sh"

# Nunca imprimir o conteudo dos arquivos .env
export AWS_DEFAULT_REGION="us-east-1"

for backend in mobile web nosql ia; do
  echo "Sincronizando configuracao: $backend"

  python3 "$ROOT/scripts/sync-secrets.py" "$backend"

  PUBLIC_FILE="$ROOT/env/${backend}.public.env"
  SECRETS_FILE="$ROOT/env/${backend}.secrets.json"

  if [[ ! -f "$PUBLIC_FILE" || ! -f "$SECRETS_FILE" ]]; then
    echo "[ERRO] Manifestos ausentes: $backend"
    exit 1
  fi

  chmod 600 "$PUBLIC_FILE" "$SECRETS_FILE"

  echo "[OK] Configuracao preparada: $backend"
done

echo "Todas as configuracoes foram sincronizadas."