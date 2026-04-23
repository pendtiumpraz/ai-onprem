#!/usr/bin/env bash
#
# Test semua endpoint AI stack
# Pastikan start.sh sudah run + semua service healthy dulu.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

source .env 2>/dev/null || true

GATEWAY_HOST="${GATEWAY_HOST:-https://localhost:${GATEWAY_HTTPS_PORT:-443}}"
CURL_OPTS="-ksS --max-time 120"

echo "===================================================="
echo " Privasimu AI — Endpoint Integration Tests"
echo "===================================================="
echo "Gateway: $GATEWAY_HOST"
echo ""

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local expected="$2"
    local cmd="$3"
    echo -n "  → $name ... "
    if eval "$cmd" | grep -q "$expected" 2>/dev/null; then
        echo "✅ PASS"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
echo "[1] Gateway health"
# =============================================================================
run_test "healthz responds 200 ok" "ok" \
    "curl $CURL_OPTS $GATEWAY_HOST/healthz"

# =============================================================================
echo ""
echo "[2] vLLM — list models"
# =============================================================================
run_test "v1/models returns qwen3-32b" "${LLM_SERVED_NAME:-qwen3-32b}" \
    "curl $CURL_OPTS $GATEWAY_HOST/v1/models"

# =============================================================================
echo ""
echo "[3] vLLM — chat completion"
# =============================================================================
CHAT_PAYLOAD='{
    "model": "'${LLM_SERVED_NAME:-qwen3-32b}'",
    "messages": [
        {"role": "system", "content": "You are Privasimu AI assistant. Respond in Indonesian."},
        {"role": "user", "content": "Apa itu UU PDP Indonesia? Jawab singkat 2 kalimat."}
    ],
    "max_tokens": 120,
    "temperature": 0.3
}'

echo "    (testing chat, tunggu ~10 detik...)"
run_test "chat completion returns valid response" "content" \
    "curl $CURL_OPTS -X POST $GATEWAY_HOST/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '$CHAT_PAYLOAD'"

# =============================================================================
echo ""
echo "[4] Embedding"
# =============================================================================
EMBED_PAYLOAD='{
    "inputs": ["UU Pelindungan Data Pribadi", "KOMDIGI regulation"]
}'

run_test "embed returns vector array" "[0." \
    "curl $CURL_OPTS -X POST $GATEWAY_HOST/embed/embed \
        -H 'Content-Type: application/json' \
        -d '$EMBED_PAYLOAD'"

# =============================================================================
echo ""
echo "[5] Metrics (Prometheus)"
# =============================================================================
run_test "vllm metrics exposed" "vllm:" \
    "curl $CURL_OPTS http://localhost:${PROMETHEUS_PORT:-9090}/api/v1/targets 2>&1 || echo miss"

# =============================================================================
echo ""
echo "===================================================="
echo " Results: $PASS passed, $FAIL failed"
echo "===================================================="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "💡 Troubleshooting:"
    echo "   - Cek logs: bash scripts/logs.sh"
    echo "   - Cek status: bash scripts/status.sh"
    echo "   - vLLM loading pertama kali bisa 2-3 menit — tunggu dan test ulang"
    exit 1
fi

echo ""
echo "✅ Semua test lulus. Stack siap pakai."
echo ""
echo "Connect Privasimu backend:"
echo "   AI_PROVIDER_BASE_URL=$GATEWAY_HOST/v1"
echo "   AI_PROVIDER_MODEL=${LLM_SERVED_NAME:-qwen3-32b}"
