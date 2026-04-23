#!/usr/bin/env bash
# Test embedding endpoint

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

source .env 2>/dev/null || true
GATEWAY_HOST="${GATEWAY_HOST:-https://localhost:${GATEWAY_HTTPS_PORT:-443}}"

echo "Testing embedding @ $GATEWAY_HOST/embed/embed"
echo ""

curl -ksS -X POST "$GATEWAY_HOST/embed/embed" \
    -H "Content-Type: application/json" \
    -d @- <<'JSON'
{
    "inputs": [
        "UU Pelindungan Data Pribadi Indonesia",
        "KOMDIGI notification 72 hours",
        "Personal data breach management"
    ]
}
JSON
echo ""
