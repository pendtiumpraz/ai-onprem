# Integrasi ke Privasimu Backend

Setelah AI stack up, langkah ini connect backend Privasimu Nexus klien ke endpoint AI lokal.

## Prerequisites

- [x] AI stack running + `scripts/test-endpoints.sh` passed
- [x] GPU server IP reachable dari backend Privasimu
- [x] Port 443 terbuka di firewall (dari backend ke GPU server)
- [x] TLS cert valid atau backend di-config untuk accept self-signed

## Step 1 — Backend `.env` Configuration

Di server backend Privasimu klien, edit `.env`:

```env
# ============================================
# AI Provider — pointing ke GPU server on-prem
# ============================================
AI_PROVIDER=openai-compatible
AI_PROVIDER_BASE_URL=https://10.0.0.50/v1
AI_PROVIDER_MODEL=qwen3-32b
AI_PROVIDER_API_KEY=dummy-or-real-token

# Untuk self-signed cert (testing):
AI_PROVIDER_VERIFY_SSL=false

# Atau untuk production dengan cert CA klien:
AI_PROVIDER_VERIFY_SSL=true
AI_PROVIDER_CA_BUNDLE=/etc/ssl/certs/client-internal-ca.pem

# ============================================
# Embedding Provider
# ============================================
EMBEDDING_PROVIDER=tei
EMBEDDING_PROVIDER_BASE_URL=https://10.0.0.50/embed
EMBEDDING_PROVIDER_MODEL=bge-m3

# ============================================
# OCR Provider
# ============================================
OCR_PROVIDER=paddle
OCR_PROVIDER_BASE_URL=https://10.0.0.50/ocr

# ============================================
# Enable AI features (feature flags)
# ============================================
AI_AGENT_ENABLED=true
AI_AUTOFILL_ENABLED=true
AI_CONTRACT_REVIEW_ENABLED=true
AI_POLICY_REVIEW_ENABLED=true
AI_REMEDIATION_ENABLED=true
```

## Step 2 — Clear Config Cache

```bash
cd /path/to/privasimu-backend
php artisan config:clear
php artisan cache:clear
```

## Step 3 — Smoke Test dari Backend

```bash
# Test langsung via artisan tinker
php artisan tinker
>>> app(\App\Services\AiService::class)->chat([
...   ['role' => 'user', 'content' => 'Jelaskan Pasal 31 UU PDP singkat']
... ])
```

Output harus berupa string jawaban Bahasa Indonesia dari Qwen3.

## Step 4 — Full UI Test

1. Login ke Privasimu dashboard sebagai DPO/Admin
2. Buka modul **AI Agent** (chat)
3. Kirim message: "Buatkan ROPA untuk aktivitas onboarding nasabah"
4. Expect response streaming dalam 5-15 detik
5. AI Agent harus propose tool call `create_ropa` dengan approval gate

Kalau test UI berhasil, integrasi selesai.

## Step 5 — Per-Feature Testing Matrix

| Fitur Privasimu | Endpoint Dipakai | Cara Test |
|---|---|---|
| **AI Auto-Fill ROPA** | `/v1/chat/completions` | Buka ROPA → tombol "AI Auto-Fill" → input aktivitas → check 7 section terisi |
| **AI Auto-Fill DPIA** | `/v1/chat/completions` | Buka DPIA → AI Auto-Fill → check 21 kategori |
| **AI Agent** | `/v1/chat/completions` + tool calling | Chat + "List semua ROPA risk HIGH" — Agent harus call tool |
| **AI Contract Review** | `/v1/chat/completions` | Upload DPA PDF → trigger review → risk report keluar |
| **AI Policy Review** | `/v1/chat/completions` | Upload policy → gap report per-pasal UU PDP |
| **AI Remediation Plan** | `/v1/chat/completions` | Run GAP assessment → "Generate Remediation Plan" |
| **PII Semantic Scan** | `/embed/embed` | Run Data Discovery scan → kolom baru → classification accuracy |
| **OCR KTP / Form** | `/ocr/` | Upload KTP scan → extract NIK, nama, alamat |

## Error Codes & Response Contract

### `/v1/chat/completions` success (streaming)

```json
data: {"id":"xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":"Halo"}}]}
data: {"id":"xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":" dunia"}}]}
data: [DONE]
```

### `/v1/chat/completions` success (non-streaming)

```json
{
  "id": "cmpl-xxx",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "...",
      "tool_calls": [...]
    },
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 150, "completion_tokens": 300, "total_tokens": 450}
}
```

### `/embed/embed` success

```json
[
  [0.0123, -0.0456, 0.0789, ...],   // vector untuk input[0], 1024 dim
  [0.0987, 0.0654, -0.0321, ...]    // vector untuk input[1]
]
```

### Common HTTP Status Code

| Code | Penyebab | Action |
|---|---|---|
| `200` | OK | — |
| `400` | Malformed request (JSON invalid, model not found) | Cek payload di backend |
| `401` | Token invalid (kalau enable token auth) | Verify `AI_PROVIDER_API_KEY` |
| `429` | Rate limit | Adjust NGINX rate limit atau throttle backend |
| `500` | vLLM error | Cek `docker compose logs vllm` |
| `502` | NGINX tidak reach vLLM | vLLM down / starting — `scripts/status.sh` |
| `503` | vLLM preemption / OOM | Kurangi concurrent load atau upgrade GPU |

## Tool Calling Integration

Privasimu AI Agent (`AiAgentToolExecutor`) registered tools:

```json
{
  "type": "function",
  "function": {
    "name": "create_ropa",
    "description": "Create a new ROPA record",
    "parameters": {
      "type": "object",
      "properties": {
        "processing_activity": {"type": "string"},
        "purpose": {"type": "string"},
        ...
      }
    }
  }
}
```

vLLM + Qwen3 emit tool calls via hermes parser format. Backend `AiAgentToolExecutor::execute()` akan dispatch ke match expression yang sesuai.

**Important:** kalau tool calling tidak work:
1. Pastikan vLLM started dengan `--enable-auto-tool-choice --tool-call-parser hermes`
2. Verify model yang dipakai support tool calling (Qwen3 ya, Gemma 2 tidak reliable)
3. Check system prompt backend tidak override tool instructions

## Performance Tuning per Tenant

Kalau ada 5 klien enterprise share 1 GPU (misal Starter L40S):

```env
# Backend .env — stabilize concurrency
AI_MAX_CONCURRENT_REQUESTS=8
AI_REQUEST_TIMEOUT=180
AI_RETRY_ON_429=true
AI_RETRY_MAX=3
AI_RETRY_BACKOFF_MS=2000
```

Di NGINX, tune rate limit per /tenant:
```nginx
# nginx/conf.d/ai-services.conf
map $http_x_tenant_id $tenant_zone {
    default "default";
    ~^tenant-(.+)$ $1;
}
limit_req_zone $tenant_zone zone=per_tenant:10m rate=50r/m;
```

Backend set header `X-Tenant-Id: tenant-{org_id}` di setiap request.

## Monitoring from Backend Side

Log setiap AI request ke `ai_credit_logs` (sudah built-in via `CreditService`):

```sql
SELECT org_id, feature, tokens_in, tokens_out, cost_cents, latency_ms, created_at
FROM ai_credit_logs
WHERE created_at > NOW() - INTERVAL 1 DAY
ORDER BY latency_ms DESC
LIMIT 100;
```

Cross-check dengan vLLM metrics di Prometheus — seharusnya match.

## Fallback Strategy

Kalau AI stack down atau overload, backend Privasimu default ke graceful degradation:

```env
AI_FALLBACK_ON_ERROR=true
AI_FALLBACK_MESSAGE="AI sedang tidak tersedia — silakan isi manual atau coba lagi nanti."
```

User tidak get 500 error, tapi UI prompt fallback.

## Rollback Plan

Kalau integrasi bermasalah, revert backend ke cloud AI:

```env
# Revert ke OpenRouter/OpenAI
AI_PROVIDER=openrouter
AI_PROVIDER_BASE_URL=https://openrouter.ai/api/v1
AI_PROVIDER_MODEL=deepseek/deepseek-chat
AI_PROVIDER_API_KEY=sk-or-xxx
```

```bash
php artisan config:clear
```

Zero downtime — switch di config, tidak butuh restart backend.
