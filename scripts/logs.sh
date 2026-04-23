#!/usr/bin/env bash
#
# Tail logs dari semua services (atau specific service)
#
# Usage:
#   bash scripts/logs.sh              # semua
#   bash scripts/logs.sh vllm         # cuma vllm
#   bash scripts/logs.sh vllm gateway # multi
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

if [[ $# -eq 0 ]]; then
    docker compose logs -f --tail=100
else
    docker compose logs -f --tail=100 "$@"
fi
