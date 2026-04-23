#!/usr/bin/env bash
# Test OCR endpoint
#
# Usage:
#   bash tests/test-ocr.sh path/to/image.jpg
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

source .env 2>/dev/null || true
GATEWAY_HOST="${GATEWAY_HOST:-https://localhost:${GATEWAY_HTTPS_PORT:-443}}"

IMAGE="${1:-}"

if [[ -z "$IMAGE" ]] || [[ ! -f "$IMAGE" ]]; then
    echo "Usage: bash tests/test-ocr.sh <path-to-image>"
    echo "Example: bash tests/test-ocr.sh tests/sample-ktp.jpg"
    exit 1
fi

echo "Testing OCR @ $GATEWAY_HOST/ocr/"
echo "Image: $IMAGE"
echo ""

# Encode image to base64
IMAGE_B64=$(base64 -w 0 < "$IMAGE")

curl -ksS -X POST "$GATEWAY_HOST/ocr/predict/ocr_system" \
    -H "Content-Type: application/json" \
    -d "{\"images\": [\"$IMAGE_B64\"]}"

echo ""
