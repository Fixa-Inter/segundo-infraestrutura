#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
mode="${1:-validation}"
shift || true
init_context
python3 "$ROOT/scripts/hostinger-dns.py" "$mode" "$STATE_DIR" "$@"
