# Quick Start — Privasimu AI On-Prem

Fast-path untuk yang sudah paham Docker + NVIDIA. Untuk panduan lengkap, baca [`README.md`](./README.md).

## TL;DR (fresh Ubuntu 24.04 GPU server)

```bash
# 1. System setup + NVIDIA + Docker
sudo bash scripts/install-prereqs.sh
sudo reboot

# 2. Config
cp .env.example .env
vi .env  # verify MODELS_DIR, TLS_DIR, GPU IDs

# 3. Download models (~25 GB, butuh internet)
bash scripts/download-models.sh

# 4. TLS cert (self-signed untuk testing)
mkdir -p /opt/privasimu/tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /opt/privasimu/tls/privkey.pem \
  -out /opt/privasimu/tls/fullchain.pem \
  -subj '/CN=privasimu-ai-gateway'

# 5. Start
bash scripts/start.sh

# 6. Wait 2-3 minutes (LLM first-load), then test
bash scripts/test-endpoints.sh
```

## Ekspektasi Waktu

| Step | Durasi |
|---|---|
| Install prereqs + reboot | 10 menit |
| Download models (network-dependent, ~25 GB) | 15-60 menit |
| First docker compose up | 3 menit (pull images) |
| vLLM first model load | 2-3 menit |
| Test endpoints | <1 menit |
| **Total fresh deploy** | **~30-90 menit** |

## Verification Checklist

Setelah `bash scripts/test-endpoints.sh` lulus semua:

- [ ] `curl -k https://localhost/healthz` → `ok`
- [ ] `curl -k https://localhost/v1/models` → list model
- [ ] Chat completion response dalam Bahasa Indonesia
- [ ] Embedding response array float
- [ ] `nvidia-smi` show utilization saat request
- [ ] `docker compose ps` semua `Up (healthy)`

## Connect Privasimu Backend

Di server backend Privasimu klien, edit `.env`:

```env
AI_PROVIDER=openai-compatible
AI_PROVIDER_BASE_URL=https://<gpu-server-ip>/v1
AI_PROVIDER_MODEL=qwen3-32b
AI_PROVIDER_API_KEY=dummy-ignored

EMBEDDING_PROVIDER_BASE_URL=https://<gpu-server-ip>/embed
OCR_PROVIDER_BASE_URL=https://<gpu-server-ip>/ocr
```

Restart backend, buka Privasimu dashboard → AI Agent → test chat.

## Common Gotchas

1. **vLLM OOM saat startup** — turunkan `LLM_GPU_MEM_UTIL` dari 0.80 ke 0.70.
2. **TLS cert invalid** — backend Privasimu klien harus trust cert self-signed, atau pakai `-k`/allow_self_signed di HTTP client config.
3. **Rate limit 429** — adjust `limit_req` di `nginx/conf.d/ai-services.conf` sesuai jumlah user.
4. **vLLM slow first request** — warmup normal, request ke-2 dan seterusnya cepat.

Untuk troubleshoot detail, lihat [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md).
