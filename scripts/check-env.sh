#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT/env"

BACKENDS=(mobile web nosql ia)

echo "Verificando configuracoes das APIs..."

for backend in "${BACKENDS[@]}"; do
  file="$ENV_DIR/$backend.env"

  if [[ ! -f "$file" ]]; then
    echo "[ERRO] Arquivo ausente: env/$backend.env"
    exit 1
  fi

  if [[ ! -s "$file" ]]; then
    echo "[ERRO] Arquivo vazio: env/$backend.env"
    exit 1
  fi

  if ! grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file"; then
    echo "[ERRO] Nenhuma variavel encontrada em $backend.env"
    exit 1
  fi

  chmod 600 "$file"

  echo "[OK] $backend.env"
done

echo "Todos os arquivos .env foram encontrados."