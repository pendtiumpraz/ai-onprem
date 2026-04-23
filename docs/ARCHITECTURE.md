# AI Stack Architecture

Dokumen ini menjelaskan bagaimana komponen stack AI Privasimu Nexus on-premise bekerja bersama.

## Diagram Stack

```
┌──────────────────────────────────────────────────────────────────┐
│                     CLIENT INFRASTRUCTURE                        │
│                                                                  │
│  ┌────────────────────────────┐                                  │
│  │  Privasimu Backend (PHP)   │                                  │
│  │  - Laravel 12              │                                  │
│  │  - AiService provider      │                                  │
│  │  - EmbeddingsService       │                                  │
│  │  - OcrService              │                                  │
│  └────────────┬───────────────┘                                  │
│               │ HTTPS (internal VLAN)                            │
│               ↓                                                  │
│  ┌────────────────────────────────────────────────────────┐      │
│  │            GPU SERVER (L40S 48GB / H100 80GB)          │      │
│  │                                                        │      │
│  │  ┌──────────────────────────────────────────────┐      │      │
│  │  │  NGINX Gateway (port 443 TLS)                │      │      │
│  │  │  - Reverse proxy                             │      │      │
│  │  │  - Rate limiting                             │      │      │
│  │  │  - Streaming SSE passthrough                 │      │      │
│  │  └──┬─────────┬─────────┬──────────────────────┘      │      │
│  │     │         │         │                              │      │
│  │     ↓ /v1/*   ↓ /embed  ↓ /ocr                         │      │
│  │  ┌─────┐  ┌──────┐  ┌────────┐                        │      │
│  │  │vLLM │  │ TEI  │  │  OCR   │                        │      │
│  │  │8000 │  │  80  │  │ 8868   │                        │      │
│  │  └──┬──┘  └──┬───┘  └───┬────┘                        │      │
│  │     │        │          │                              │      │
│  │     └────────┼──────────┘                              │      │
│  │              ↓                                         │      │
│  │        ┌───────────┐                                   │      │
│  │        │  NVIDIA   │                                   │      │
│  │        │  GPU      │  L40S 48GB / H100 80GB            │      │
│  │        └───────────┘                                   │      │
│  │                                                        │      │
│  │  ┌──────────────────────────────────────────────┐      │      │
│  │  │  Prometheus (9090) — internal metrics       │      │      │
│  │  └──────────────────────────────────────────────┘      │      │
│  │                                                        │      │
│  │  /opt/privasimu/models/ (read-only mount)              │      │
│  │    ├── Qwen3-32B-AWQ/                                  │      │
│  │    ├── bge-m3/                                         │      │
│  │    └── Qwen2.5-VL-7B/ (opsional)                       │      │
│  └────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────┘
```

## Service Responsibilities

### 1. NGINX Gateway

- **Port**: 80 (redirect) → 443 (TLS)
- **Peran**: Single entry point, TLS termination, rate limiting, routing
- **Routing**:
  - `/v1/*` → `vllm:8000` (OpenAI-compatible chat/completions)
  - `/embed/*` → `embeddings:80` (TEI, path stripped)
  - `/ocr/*` → `ocr:8868` (PaddleOCR, path stripped)
  - `/healthz` → static "ok"
- **Streaming**: `proxy_buffering off` untuk SSE (LLM streaming)
- **Rate limit zones**:
  - `ai_chat` — 30 req/menit per IP (LLM heavy workload)
  - `ai_embed` — 300 req/menit per IP (light)
  - `ai_ocr` — 60 req/menit per IP

### 2. vLLM

- **Port**: 8000 (internal)
- **Model**: Qwen3-32B AWQ Q4 (primary)
- **API**: OpenAI-compatible
  - `GET /v1/models` — list
  - `POST /v1/chat/completions` — chat
  - `POST /v1/completions` — legacy completion
- **Features enabled**:
  - `--enable-auto-tool-choice` — function calling untuk AI Agent
  - `--tool-call-parser hermes` — parser output format tool
  - `--quantization awq` — AWQ 4-bit
- **Memory**:
  - `--gpu-memory-utilization 0.80` — reserve 80% VRAM
  - KV cache dinamis dari sisa 20%
- **Metrics**: `/metrics` Prometheus-compatible

### 3. TEI (Text Embeddings Inference)

- **Port**: 80 (internal)
- **Model**: bge-m3 (multilingual, 1024 dim)
- **API**:
  - `POST /embed` — batch embedding
  - `POST /rerank` — reranking (kalau butuh)
  - `GET /health` — health
- **Max batch**: 16384 tokens, 128 concurrent

### 4. PaddleOCR

- **Port**: 8868 (internal)
- **Language**: `en` (handles Indonesian + English + number)
- **Use case**: KTP scan, form fisik, receipt OCR
- **Input**: base64 image, output JSON bounding box + text

### 5. Prometheus

- **Port**: 9090 (bound ke 127.0.0.1 only)
- **Retention**: 30 hari default
- **Scrape targets**: vLLM, TEI, Prometheus sendiri
- **Key metrics**:
  - `vllm:num_requests_running` — concurrent inference
  - `vllm:time_to_first_token_seconds` — TTFT
  - `vllm:gpu_cache_usage_perc` — KV cache util
  - `vllm:num_preemptions_total` — OOM preemption count

## Request Flow

### Contoh: ROPA Auto-Fill

```
1. User klik "AI Auto-Fill" di ROPA wizard
2. Privasimu backend:
   POST https://<gpu-server>/v1/chat/completions
   {
     "model": "qwen3-32b",
     "messages": [...],
     "tools": [...]
   }
3. NGINX → vLLM backend
4. vLLM load model (sudah di VRAM), generate response
5. Response streamed back via NGINX → backend → UI
6. Backend parse tool_calls, eksekusi AI Agent tool locally
7. Result disimpan ke database
```

### Contoh: PII Scanner Embedding

```
1. Backend scan kolom baru di Information System
2. Backend batch-kirim 50 sample value:
   POST https://<gpu-server>/embed/embed
   {"inputs": [...50 values...]}
3. NGINX → TEI
4. TEI return 50× vector[1024]
5. Backend compare ke pre-computed PII category vectors
6. Classify column PII category berdasar cosine similarity
```

## Data Flow & Storage

- **Model weights**: `/opt/privasimu/models/` → mount read-only ke container
- **Prometheus data**: named Docker volume `prometheus-data`
- **NGINX logs**: ephemeral container logs (redirect ke external log aggregator kalau perlu)
- **No tenant data di GPU server** — request processed, response returned, nothing persisted di AI stack

## Scaling Paths

### Vertical
- L40S (48GB) → upgrade ke H100 (80GB)
- Single GPU → multi-GPU tensor parallel (`LLM_TP_SIZE=2`)

### Horizontal
- Tambah GPU server kedua, extend NGINX upstream:
  ```nginx
  upstream vllm_backend {
      server vllm-1:8000;
      server vllm-2:8000;
      keepalive 32;
  }
  ```
- Load balance round-robin atau `least_conn`

### Model Upgrade Path
1. Download model baru ke `$MODELS_DIR/ModelName/`
2. Update `LLM_MODEL_DIR` di `.env`
3. `bash scripts/restart.sh`
4. Test endpoint
5. Kalau OK, lanjut. Kalau error, revert `.env`, restart lagi.

## Security Boundary

- GPU server **tidak punya internet egress** setelah setup (firewall rule di klien side)
- NGINX TLS cert **wajib** untuk production — self-signed boleh untuk internal (backend Privasimu config `allow_self_signed=true`)
- Token auth optional via NGINX — activate kalau klien minta
- Model weight + config file di `/opt/privasimu/` dengan `chown privasimu:privasimu chmod 700`

## Monitoring Integration

Kalau klien punya Grafana existing:

```
Grafana (klien) → Prometheus (localhost:9090 via SSH tunnel atau VPN) → scrape vLLM
```

Export Prometheus metrics ke external via `external_url` di config atau via Thanos/Mimir kalau klien pakai federation.
