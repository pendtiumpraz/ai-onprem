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

# 4. TLS cert (self-signed untuk testing). SAN wajib memuat IP/DNS yang
#    dipakai backend Privasimu di API Base URL (ganti 10.0.0.50).
mkdir -p /opt/privasimu/tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /opt/privasimu/tls/privkey.pem \
  -out /opt/privasimu/tls/fullchain.pem \
  -subj '/CN=privasimu-ai-gateway' \
  -addext 'subjectAltName=IP:10.0.0.50,DNS:privasimu-ai-gateway'

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

Bukan lewat `.env` backend — provider AI adalah pengaturan platform di UI Privasimu (login root/superadmin):

1. **Platform Admin → System Settings → Deployment** → mode `onprem`
2. **`/settings/ai-providers`** → Tambah Provider, API Base URL `https://<gpu-server-ip>/v1` → Tambah Model, ID Model `qwen3-32b` (= `LLM_SERVED_NAME`)
3. **Settings → AI Providers** → API key `onprem-no-auth` (min. 8 karakter, vLLM tidak memeriksa) → Test → set model aktif Chat + Agent (+ Document)
4. Di server backend: `php artisan ai:cek` → mode `agent`/`chat`/`document` harus menunjuk provider on-prem

Backend on-prem wajib punya `APP_KEY` tetap (compose on-prem gagal start tanpa itu): buat sekali dengan `echo "base64:$(openssl rand -base64 32)"`, jangan diganti saat update.

Tidak perlu restart backend. Buka dashboard → AI Agent → test chat. Detail (embedding TEI, vision, TLS, offline): [`docs/PRIVASIMU_INTEGRATION.md`](./docs/PRIVASIMU_INTEGRATION.md).

## Common Gotchas

1. **vLLM OOM saat startup** — turunkan `LLM_GPU_MEM_UTIL` dari 0.80 ke 0.70.
2. **TLS cert invalid** — backend Privasimu tidak punya opsi `allow_self_signed`. Chat, embedding, dan OCR men-skip verifikasi hanya bila mode `onprem` **dan** URL memakai IP privat; untuk hostname DNS isi `AI_CA_BUNDLE` (CA sistem + CA internal). Lihat Step 4 di integrasi.
3. **Rate limit 429** — kuota `ai_chat` (30 r/menit) dihitung **per tenant** lewat header `X-Privasimu-Tenant` dari backend, ditambah plafon gabungan `ai_chat_ip` (300 r/menit) untuk seluruh backend. Tuning: `nginx/nginx.conf` (`rate`) / `nginx/conf.d/ai-services.conf` (`burst`) — lihat [Rate limit per tenant](./docs/PRIVASIMU_INTEGRATION.md#rate-limit-per-tenant).
4. **vLLM slow first request** — warmup normal, request ke-2 dan seterusnya cepat.

Untuk troubleshoot detail, lihat [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md).
