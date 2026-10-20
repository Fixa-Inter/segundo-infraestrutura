#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
init_context
python3 "$ROOT/scripts/check-deployment.py" "$STATE_DIR"
