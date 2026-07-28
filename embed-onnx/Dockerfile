# Sidecar embedding ONNX — CPU saja, tidak butuh GPU.
#
# Sengaja dipisah dari service `embeddings` (TEI) di docker-compose: TEI
# menjalankan model bge-m3 fp16 di GPU untuk throughput tinggi, sedangkan
# sidecar ini menjalankan model int8 berukuran 23-118 MB di CPU untuk
# deployment kecil / VPS tanpa GPU.

FROM node:20-bookworm-slim

WORKDIR /app

# onnxruntime-node membawa binary pra-kompilasi; hanya butuh ca-certificates
# untuk mengunduh artefak dari blob saat mode "blob".
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js models.json ./

# /models diisi panel root (mode local) dan di-mount read-only.
# /tmp/embed-cache dipakai saat mode blob.
ENV PORT=8091 \
    MODELS_DIR=/models \
    CACHE_DIR=/tmp/embed-cache \
    NODE_ENV=production

EXPOSE 8091

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
    CMD curl -fsS http://localhost:8091/health || exit 1

CMD ["node", "server.js"]
