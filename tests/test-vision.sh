#!/usr/bin/env bash
#
# Test vision endpoint (multimodal chat completion)
#
# Usage:
#   bash tests/test-vision.sh                          # test dengan sample URL
#   bash tests/test-vision.sh path/to/image.jpg        # test dengan file lokal
#   bash tests/test-vision.sh "https://example.com/x.jpg"  # test dengan URL remote
#
# Auto-detect profile:
#   qwen3.6-27b  → call /v1/chat/completions (built-in vision)
#   qwen3-32b    → call /vlm/v1/chat/completions (separate VLM service)
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

source .env 2>/dev/null || { echo "❌ .env belum ada. Jalankan bash scripts/switch-profile.sh"; exit 1; }

GATEWAY_HOST="${GATEWAY_HOST:-https://localhost:${GATEWAY_HTTPS_PORT:-443}}"
PROFILE="${PROFILE_NAME:-unknown}"

# Auto-route berdasar profile
if [[ "$PROFILE" == "qwen3.6-27b" ]]; then
    ENDPOINT="$GATEWAY_HOST/v1/chat/completions"
    MODEL="${LLM_SERVED_NAME:-qwen3.6-27b}"
    echo "📋 Profile: $PROFILE — using built-in VLM (main model)"
elif [[ "$PROFILE" == "qwen3-32b" ]]; then
    ENDPOINT="$GATEWAY_HOST/vlm/v1/chat/completions"
    MODEL="${VLM_SERVED_NAME:-qwen2.5-vl}"
    echo "📋 Profile: $PROFILE — using Qwen2.5-VL-7B fallback service"
else
    echo "⚠️  Unknown profile, defaulting ke main /v1 endpoint"
    ENDPOINT="$GATEWAY_HOST/v1/chat/completions"
    MODEL="${LLM_SERVED_NAME:-qwen3.6-27b}"
fi

echo "Endpoint: $ENDPOINT"
echo "Model:    $MODEL"
echo ""

# Argument: image file atau URL
INPUT="${1:-}"

if [[ -z "$INPUT" ]]; then
    # Default: tes dengan image URL publik (kalau ada internet)
    IMAGE_URL="https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/200px-Cat03.jpg"
    echo "🖼️  No image provided. Using test URL: $IMAGE_URL"
elif [[ "$INPUT" =~ ^https?:// ]]; then
    IMAGE_URL="$INPUT"
elif [[ -f "$INPUT" ]]; then
    # Encode ke base64 data URL
    EXT="${INPUT##*.}"
    MIME="image/jpeg"
    case "$EXT" in
        png|PNG) MIME="image/png" ;;
        jpg|JPG|jpeg|JPEG) MIME="image/jpeg" ;;
        webp|WEBP) MIME="image/webp" ;;
    esac
    B64=$(base64 -w 0 < "$INPUT")
    IMAGE_URL="data:$MIME;base64,$B64"
    echo "🖼️  Image file: $INPUT (encoded as data URL)"
else
    echo "❌ Input tidak valid: $INPUT"
    exit 1
fi

echo ""
echo "🚀 Sending vision request..."
echo ""

curl -ksS -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{
    "model": "$MODEL",
    "messages": [
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Jelaskan apa yang kamu lihat di gambar ini dalam Bahasa Indonesia. Kalau ini dokumen, extract text penting seperti nama, NIK, alamat, nomor dokumen, tanggal, dll."
                },
                {
                    "type": "image_url",
                    "image_url": {
                        "url": "$IMAGE_URL"
                    }
                }
            ]
        }
    ],
    "max_tokens": 800,
    "temperature": 0.2,
    "stream": false
}
JSON

echo ""
echo ""
echo "✅ Test done."
