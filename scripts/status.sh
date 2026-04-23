#!/usr/bin/env bash
#
# Privasimu AI — Health Status Check
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

echo "===================================================="
echo " Privasimu AI — Status Check"
echo "===================================================="

ACTIVE_PROFILE=$(grep "^PROFILE_NAME=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "unknown")
PROFILE_DESC=$(grep "^PROFILE_DESC=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
echo "📋 Profile: $ACTIVE_PROFILE"
echo "   $PROFILE_DESC"

echo ""
echo "📦 Container status:"
docker compose ps

echo ""
echo "🎮 GPU Utilization:"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv
else
    echo "   nvidia-smi tidak tersedia"
fi

echo ""
echo "🔌 Endpoint health:"
source .env 2>/dev/null || true

# vLLM
if curl -fsS http://localhost:${GATEWAY_HTTPS_PORT:-443}/healthz -k &>/dev/null; then
    echo "   ✅ Gateway (NGINX)    → alive"
else
    echo "   ❌ Gateway (NGINX)    → DOWN"
fi

# Direct vLLM (internal)
if docker compose exec -T vllm curl -fsS http://localhost:8000/health &>/dev/null; then
    echo "   ✅ vLLM LLM           → alive"
else
    echo "   ❌ vLLM LLM           → DOWN / loading"
fi

# VLM fallback (hanya di profile qwen3-32b)
if [[ "${COMPOSE_PROFILES:-}" == *"vlm-fallback"* ]] || grep -q "^COMPOSE_PROFILES=vlm-fallback" .env 2>/dev/null; then
    if docker compose exec -T vlm-fallback curl -fsS http://localhost:8001/health &>/dev/null; then
        echo "   ✅ VLM Fallback       → alive (Qwen2.5-VL-7B)"
    else
        echo "   ⚠️  VLM Fallback       → DOWN / loading"
    fi
else
    echo "   ℹ️  VLM Fallback       → SKIPPED (built-in VLM di main model)"
fi

# TEI embeddings
if docker compose exec -T embeddings curl -fsS http://localhost:80/health &>/dev/null; then
    echo "   ✅ TEI Embeddings     → alive"
else
    echo "   ❌ TEI Embeddings     → DOWN / loading"
fi

# OCR
if docker compose exec -T ocr curl -fsS http://localhost:8868/ &>/dev/null; then
    echo "   ✅ PaddleOCR          → alive"
else
    echo "   ⚠️  PaddleOCR          → DOWN / loading (check: docker compose logs ocr)"
fi

echo ""
echo "💾 Model storage:"
if [[ -n "${MODELS_DIR:-}" ]] && [[ -d "$MODELS_DIR" ]]; then
    du -sh "$MODELS_DIR"/*/ 2>/dev/null || echo "   Empty"
fi

echo ""
