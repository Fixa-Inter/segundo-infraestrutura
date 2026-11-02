#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "Informe a tag publicada"
init_context
[[ -s "$STATE_DIR/terraform.tfstate" ]] || fail "Execute deploy.sh primeiro"
source "$ROOT/scripts/activation.sh"
activate "$VERSION"
