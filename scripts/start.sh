#!/usr/bin/env bash
#
# Start Privasimu AI stack
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

if [[ ! -f .env ]]; then
    echo "❌ .env belum ada."
    echo ""
    echo "   Pilih profile:"
    echo "     bash scripts/switch-profile.sh qwen3-32b       # stable (default)"
    echo "     bash scripts/switch-profile.sh qwen3.6-27b     # pilot (next-gen)"
    echo ""
    exit 1
fi

# Display active profile
ACTIVE_PROFILE=$(grep "^PROFILE_NAME=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "unknown")
PROFILE_TIER=$(grep "^PROFILE_TIER=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "unknown")
echo "📋 Active profile: $ACTIVE_PROFILE [$PROFILE_TIER]"

# Verify model dir isi
source .env
if [[ ! -d "${MODELS_DIR}/${LLM_MODEL_DIR}" ]]; then
    echo "❌ Model LLM tidak ditemukan di ${MODELS_DIR}/${LLM_MODEL_DIR}"
    echo "   Run dulu: bash scripts/download-models.sh"
    exit 1
fi

# Verify TLS cert
if [[ ! -f "${TLS_DIR}/fullchain.pem" ]] || [[ ! -f "${TLS_DIR}/privkey.pem" ]]; then
    echo "⚠️  TLS cert tidak lengkap di ${TLS_DIR}/"
    echo "   Expected: ${TLS_DIR}/fullchain.pem + ${TLS_DIR}/privkey.pem"
    echo ""
    echo "   Opsi cepat (self-signed untuk testing):"
    echo "     mkdir -p ${TLS_DIR}"
    echo "     openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\"
    echo "       -keyout ${TLS_DIR}/privkey.pem \\"
    echo "       -out ${TLS_DIR}/fullchain.pem \\"
    echo "       -subj '/CN=privasimu-ai-gateway'"
    echo ""
    read -p "Generate self-signed cert sekarang? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "${TLS_DIR}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${TLS_DIR}/privkey.pem" \
            -out "${TLS_DIR}/fullchain.pem" \
            -subj '/CN=privasimu-ai-gateway'
        chmod 600 "${TLS_DIR}"/*.pem
        echo "✅ Self-signed cert generated"
    else
        exit 1
    fi
fi

echo "🚀 Starting Privasimu AI stack..."
docker compose up -d

echo ""
echo "⏳ Menunggu services healthy (LLM butuh ~2-3 menit pertama kali)..."
sleep 10

docker compose ps
echo ""
echo "✅ Stack running. Cek status: bash scripts/status.sh"
echo "📊 Tail logs: bash scripts/logs.sh"
