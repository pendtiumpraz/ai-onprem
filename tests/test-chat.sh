#!/usr/bin/env bash
# Test LLM chat endpoint secara interactive

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

source .env 2>/dev/null || true
GATEWAY_HOST="${GATEWAY_HOST:-https://localhost:${GATEWAY_HTTPS_PORT:-443}}"
MODEL="${LLM_SERVED_NAME:-qwen3-32b}"

echo "Testing chat endpoint @ $GATEWAY_HOST"
echo "Model: $MODEL"
echo ""

curl -ksS -N -X POST "$GATEWAY_HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{
    "model": "$MODEL",
    "messages": [
        {"role": "system", "content": "You are a UU PDP compliance assistant. Respond in Bahasa Indonesia, concise."},
        {"role": "user", "content": "Jelaskan kewajiban DPO menurut Pasal 53 UU PDP"}
    ],
    "max_tokens": 500,
    "temperature": 0.4,
    "stream": false
}
JSON
echo ""
