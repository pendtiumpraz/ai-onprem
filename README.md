# Privasimu Nexus — On-Premise AI Stack

Deploy-ready AI inference stack untuk Privasimu Nexus on-premise. Run di GPU server klien (L40S 48GB atau H100 80GB), connect Privasimu backend via OpenAI-compatible API.

Folder ini **tidak berisi model weight** — model di-download on-site oleh admin klien via script yang sudah disediakan. Zero bandwidth waste, zero risk model leak via repo.

## Isi Stack

| Service | Image | Fungsi | Port (internal) |
|---|---|---|---|
| **vLLM** | `vllm/vllm-openai:latest` | LLM serving (Qwen3-32B AWQ Q4) | `8000` |
| **TEI** | `ghcr.io/huggingface/text-embeddings-inference:1.5` | Embedding serving (bge-m3) | `8080` |
| **PaddleOCR** | `paddlecloud/paddleocr-gpu:latest` | OCR untuk KTP/dokumen fisik | `8868` |
| **NGINX** | `nginx:1.27-alpine` | Reverse proxy + TLS | `443` |
| **Prometheus** | `prom/prometheus:latest` | Metrics collector | `9090` |

Privasimu backend klien → NGINX → vLLM/TEI/OCR. Satu endpoint untuk semua.

## Prerequisites

- **OS**: Ubuntu 22.04 / 24.04 LTS Server (fresh install recommended)
- **GPU**: NVIDIA L40S 48GB atau H100 80GB (tested), A100 80GB juga supported
- **CPU**: 16+ cores recommended
- **RAM**: 128 GB+ (64 GB minimum)
- **Storage**: 2 TB+ NVMe (model + cache + logs)
- **Network**: Akses internet saat setup (untuk pull Docker images + download model). Setelah itu bisa air-gap.

## Quick Start

```bash
# 1. Copy folder ini ke GPU server
scp -r ai-onprem/ admin@gpu-server:/opt/privasimu/

ssh admin@gpu-server
cd /opt/privasimu/ai-onprem

# 2. Install prerequisites (NVIDIA driver + Docker + nvidia-container-toolkit)
sudo bash scripts/install-prereqs.sh
sudo reboot    # Wajib reboot setelah install NVIDIA driver

# 3. Verify GPU visible ke Docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi

# 4. Pilih profile AI
bash scripts/switch-profile.sh qwen3-32b      # stable — default untuk 5 klien production
# ATAU
bash scripts/switch-profile.sh qwen3.6-27b    # pilot — Qwen 3.6 27B with built-in VLM

# 5. Download model (user/admin klien yang eksekusi — bukan kami)
bash scripts/download-models.sh

# 6. Start stack
bash scripts/start.sh

# 7. Test endpoints
bash scripts/test-endpoints.sh
bash tests/test-vision.sh   # optional: test vision capability
```

## Dual Profile Strategy

Stack ini mendukung 2 profile yang bisa di-swap real-time:

### Profile A — `qwen3-32b` (Stable Production)
- **Qwen3-32B** (text) + **Qwen2.5-VL-7B** (vision fallback)
- Battle-tested, AWQ Q4, mature vLLM support
- Untuk 5 klien enterprise yang sudah committed
- VRAM footprint ~40 GB → fit L40S 48GB atau H100 80GB

### Profile B — `qwen3.6-27b` (Pilot — Next-Gen)
- **Qwen3.6-27B** (chat + VLM built-in di satu model)
- 262k native context, hybrid DeltaNet architecture
- Stack simpler (drop Qwen2.5-VL service)
- Document analyzer + mapping jauh lebih kuat via native vision
- ⚠️ Need pilot test 2-4 minggu — gunakan untuk opt-in klien

**Switching:**
```bash
bash scripts/switch-profile.sh qwen3.6-27b    # pilot
bash scripts/switch-profile.sh qwen3-32b      # rollback ke stable
```

Script otomatis prompt restart stack setelah switch. Tidak ada data loss — model weight tetap di disk.

## Folder Structure

```
ai-onprem/
├── README.md                      ← You are here
├── QUICKSTART.md                  ← Fast-path setup untuk yang sudah berpengalaman
├── docker-compose.yml             ← Main orchestration
├── docker-compose.override.yml    ← Local overrides (ignored by git)
├── .env.example                   ← Config template — copy ke .env
├── nginx/
│   ├── nginx.conf                 ← Main NGINX config
│   └── conf.d/
│       └── ai-services.conf       ← Reverse proxy rules
├── prometheus/
│   └── prometheus.yml             ← Scrape targets
├── models/                        ← Model weights go here (user downloads)
│   └── .gitkeep
├── scripts/
│   ├── install-prereqs.sh         ← Install NVIDIA + Docker stack
│   ├── download-models.sh         ← Download Qwen3-32B + bge-m3 (user runs)
│   ├── start.sh                   ← Start all services
│   ├── stop.sh                    ← Stop all services
│   ├── restart.sh                 ← Restart
│   ├── status.sh                  ← Check health
│   ├── logs.sh                    ← Tail logs
│   └── test-endpoints.sh          ← Verify endpoints alive + functional
├── tests/
│   ├── test-chat.sh               ← Test LLM chat endpoint
│   ├── test-embed.sh              ← Test embedding endpoint
│   └── test-ocr.sh                ← Test OCR endpoint
└── docs/
    ├── ARCHITECTURE.md            ← How the stack fits together
    ├── TROUBLESHOOTING.md         ← Common issues + fixes
    ├── PRIVASIMU_INTEGRATION.md   ← How to connect Privasimu backend
    └── MODEL_CATALOG.md           ← Model choices + quantization options
```

## Connecting to Privasimu Backend

Setelah stack up, edit `.env` di backend Privasimu klien:

```env
AI_PROVIDER=openai-compatible
AI_PROVIDER_BASE_URL=http://<gpu-server-ip>:443/v1
AI_PROVIDER_MODEL=qwen3-32b
AI_PROVIDER_API_KEY=<optional-token>

EMBEDDING_PROVIDER_BASE_URL=http://<gpu-server-ip>:443/embed
OCR_PROVIDER_BASE_URL=http://<gpu-server-ip>:443/ocr
```

Zero code change di backend. Restart `php artisan serve` selesai.

Lihat [`docs/PRIVASIMU_INTEGRATION.md`](./docs/PRIVASIMU_INTEGRATION.md) untuk langkah detail.

## Air-Gap Deployment

Kalau klien minta fully air-gapped (bank, pemerintah):

1. Download model di mesin dengan internet, copy ke USB encrypted
2. Pull Docker images ke mesin dengan internet:
   ```bash
   docker pull vllm/vllm-openai:latest
   docker pull ghcr.io/huggingface/text-embeddings-inference:1.5
   docker pull paddlecloud/paddleocr-gpu:latest
   docker pull nginx:1.27-alpine
   docker pull prom/prometheus:latest

   docker save -o privasimu-ai-images.tar \
     vllm/vllm-openai:latest \
     ghcr.io/huggingface/text-embeddings-inference:1.5 \
     paddlecloud/paddleocr-gpu:latest \
     nginx:1.27-alpine \
     prom/prometheus:latest
   ```
3. Transfer `privasimu-ai-images.tar` + `models/` ke GPU server via USB
4. Di GPU server: `docker load -i privasimu-ai-images.tar`
5. Lanjut seperti biasa — sudah tidak butuh internet lagi

## Security Notes

- GPU server **tidak boleh punya akses Internet egress** setelah setup. Firewall rule di klien-side WAJIB.
- NGINX TLS mandatory untuk production — lihat `nginx/conf.d/ai-services.conf`
- Gunakan self-signed cert internal atau CA internal klien (bukan Let's Encrypt — tidak bisa validate tanpa internet)
- Model weight + tenant data store di `/opt/privasimu/` dengan `chmod 700` — hanya user `privasimu` yang akses

## Monitoring

Prometheus scrape vLLM + NGINX metrics. Grafana tidak di-bundle (klien biasanya sudah punya Grafana di SOC mereka). Import dashboard JSON dari `docs/grafana-dashboards/` (coming).

Metrics penting yang di-expose:
- `vllm:num_requests_running` — concurrent inference
- `vllm:time_to_first_token_seconds` — TTFT latency
- `vllm:gpu_cache_usage_perc` — KV cache utilization
- `nginx_http_requests_total` — request rate

## Versioning

Stack ini dimulai versi **1.0** (April 2026). Semua tag image **di-pin** di `.env.example` — jangan pakai `:latest` untuk production, commit `.env` klien dengan tag spesifik.

## Support

Untuk isu teknis: ops@privasimu.com
Escalation: CTO via Privasimu support portal

## Lisensi

Copyright (c) 2026 PT Sentra Proteksi Data Teknologi Indonesia.
Unauthorized redistribution prohibited. Untuk klien berlisensi Privasimu Nexus Enterprise Perpetual.
