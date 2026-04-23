#!/usr/bin/env bash
#
# Privasimu Nexus — Model Downloader
#
# Download LLM + embedding model dari HuggingFace Hub ke $MODELS_DIR.
# WAJIB dijalankan oleh admin klien di lingkungan yang masih punya akses internet.
# Setelah download selesai, stack bisa run fully offline.
#
# Total footprint: ~25 GB
#   Qwen3-32B-AWQ        ~20 GB
#   bge-m3               ~2 GB
#   Qwen2.5-VL-7B (opt)  ~15 GB
#

set -euo pipefail

# Load .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if [[ ! -f .env ]]; then
    echo "❌ .env belum ada. Pilih profile dulu:"
    echo "   bash scripts/switch-profile.sh qwen3-32b       # stable"
    echo "   bash scripts/switch-profile.sh qwen3.6-27b     # pilot"
    exit 1
fi
set -a
source .env
set +a

ACTIVE_PROFILE="${PROFILE_NAME:-unknown}"
echo "📋 Active profile: $ACTIVE_PROFILE"

MODELS_DIR="${MODELS_DIR:-/opt/privasimu/models}"
mkdir -p "$MODELS_DIR"

echo "===================================================="
echo " Privasimu Nexus — Model Downloader"
echo "===================================================="
echo "Target directory: $MODELS_DIR"
echo ""

# Check python + huggingface-cli
if ! command -v python3 &> /dev/null; then
    echo "❌ python3 tidak ditemukan. Install dulu: apt install python3 python3-pip"
    exit 1
fi

if ! command -v huggingface-cli &> /dev/null; then
    echo "🔽 Install huggingface-hub CLI..."
    pip3 install --upgrade huggingface_hub[cli,hf_transfer] 2>/dev/null || \
    pip3 install --upgrade --break-system-packages huggingface_hub[cli,hf_transfer]
fi

# Enable fast transfer
export HF_HUB_ENABLE_HF_TRANSFER=1

# Optional HuggingFace token (untuk gated model)
if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "🔑 HF_TOKEN detected — login ke HuggingFace"
    huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential
fi

# ==============================================================================
# LLM — determine repo dari profile active
# ==============================================================================
# Map profile → HF repo
case "$ACTIVE_PROFILE" in
    qwen3-32b)
        LLM_REPO="${LLM_REPO:-Qwen/Qwen3-32B-AWQ}"
        LLM_SIZE_EST="~20 GB"
        ;;
    qwen3.6-27b)
        LLM_REPO="${LLM_REPO:-Qwen/Qwen3.6-27B}"
        LLM_SIZE_EST="~54 GB (FP16) atau ~14 GB (AWQ kalau variant tersedia)"
        ;;
    *)
        LLM_REPO="${LLM_REPO:-Qwen/Qwen3-32B-AWQ}"
        LLM_SIZE_EST="~20 GB"
        ;;
esac

LLM_TARGET="$MODELS_DIR/${LLM_MODEL_DIR}"

echo ""
echo "===================================================="
echo " [1/3] Download Primary LLM: $LLM_REPO"
echo "===================================================="
echo "Target: $LLM_TARGET"
echo "Estimasi size: $LLM_SIZE_EST"
echo ""
read -p "Lanjutkan download? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    huggingface-cli download "$LLM_REPO" \
        --local-dir "$LLM_TARGET" \
        --local-dir-use-symlinks False
    echo "✅ LLM downloaded: $LLM_TARGET"
fi

# ==============================================================================
# VLM Fallback (hanya di profile qwen3-32b yang butuh)
# ==============================================================================
if [[ -n "${VLM_MODEL_DIR:-}" ]]; then
    VLM_REPO="${VLM_REPO:-Qwen/Qwen2.5-VL-7B-Instruct}"
    VLM_TARGET="$MODELS_DIR/${VLM_MODEL_DIR}"
    echo ""
    echo "===================================================="
    echo " [1b/3] Download VLM Fallback: $VLM_REPO"
    echo "===================================================="
    echo "Target: $VLM_TARGET"
    echo "Estimasi size: ~15 GB"
    echo ""
    read -p "Lanjutkan download? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        huggingface-cli download "$VLM_REPO" \
            --local-dir "$VLM_TARGET" \
            --local-dir-use-symlinks False
        echo "✅ VLM downloaded: $VLM_TARGET"
    fi
else
    echo ""
    echo "ℹ️  Profile $ACTIVE_PROFILE: VLM built-in di main model, skip fallback VLM download."
fi

# ==============================================================================
# Embeddings — bge-m3
# ==============================================================================
EMBED_REPO="${EMBED_REPO:-BAAI/bge-m3}"
EMBED_TARGET="$MODELS_DIR/${EMBED_MODEL_DIR:-bge-m3}"

echo ""
echo "===================================================="
echo " [2/3] Download Embedding: $EMBED_REPO"
echo "===================================================="
echo "Target: $EMBED_TARGET"
echo "Estimasi size: ~2 GB"
echo ""
read -p "Lanjutkan download? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    huggingface-cli download "$EMBED_REPO" \
        --local-dir "$EMBED_TARGET" \
        --local-dir-use-symlinks False
    echo "✅ Embedding downloaded: $EMBED_TARGET"
fi


# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "===================================================="
echo " ✅ Model Download Complete"
echo "===================================================="
echo ""
echo "Contents of $MODELS_DIR:"
du -sh "$MODELS_DIR"/* 2>/dev/null | sort -h || true
echo ""
echo "📋 Next steps:"
echo "   1. Verify config di .env match nama folder"
echo "   2. Start stack: bash scripts/start.sh"
echo "   3. Test: bash scripts/test-endpoints.sh"
echo ""
