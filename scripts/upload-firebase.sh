#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [[ "${1:-}" == --check && "$#" == 1 ]]; then
  python3 "$ROOT/scripts/upload-firebase.py" --check
  exit 0
fi
[[ "$#" == 0 ]] || fail "Uso: ./scripts/upload-firebase.sh [--check]"
init_context
python3 "$ROOT/scripts/upload-firebase.py" --state-dir "$STATE_DIR"
