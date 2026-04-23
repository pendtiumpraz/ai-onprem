#!/usr/bin/env bash
#
# Stop Privasimu AI stack
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

echo "🛑 Stopping Privasimu AI stack..."
docker compose down

echo "✅ Stack stopped"
