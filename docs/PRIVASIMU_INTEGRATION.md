# Integrasi ke Privasimu Backend

Setelah AI stack up, langkah ini connect backend Privasimu Nexus klien ke endpoint AI lokal.

> **Penting — bukan lewat `.env`.** Provider AI di backend Privasimu adalah **pengaturan platform** yang disimpan di database (tabel `ai_providers`, `ai_models`, `ai_provider_configs`, `ai_active_selections`) dan diatur root/superadmin lewat UI. Tenant tidak bisa memilih provider sendiri — semua organisasi memakai pilihan platform (`AiProviderController::getActiveConfig()`). Variabel seperti `AI_PROVIDER=openai-compatible`, `AI_PROVIDER_BASE_URL`, `AI_PROVIDER_MODEL`, `EMBEDDING_PROVIDER_BASE_URL`, `OCR_PROVIDER_BASE_URL` **tidak dibaca backend** — jangan dipakai.

## Daftar Isi

- [Prerequisites](#prerequisites)
- [Step 1 — Mode deployment `onprem`](#step-1--mode-deployment-onprem)
- [Step 2 — Daftarkan GPU server sebagai provider AI](#step-2--daftarkan-gpu-server-sebagai-provider-ai)
- [Step 3 — API key + pilih model aktif](#step-3--api-key--pilih-model-aktif)
- [Step 4 — TLS antara backend dan gateway](#step-4--tls-antara-backend-dan-gateway)
- [Step 5 — Embedding (RAG) ke TEI](#step-5--embedding-rag-ke-tei)
- [Step 6 — OCR dan vision](#step-6--ocr-dan-vision)
- [Step 7 — Verifikasi](#step-7--verifikasi)
- [Deployment offline / air-gapped (sisi backend)](#deployment-offline--air-gapped-sisi-backend)
- [Kredit AI di on-prem](#kredit-ai-di-on-prem)
- [Tuning, fallback, rollback](#tuning-fallback-rollback)
- [Known limitations backend](#known-limitations-backend)

## Prerequisites

- [x] AI stack running + `scripts/test-endpoints.sh` passed
- [x] GPU server IP reachable dari backend Privasimu, port 443 terbuka (backend → GPU server)
- [x] TLS cert gateway punya SAN yang cocok dengan alamat yang dipakai backend (lihat [Step 4](#step-4--tls-antara-backend-dan-gateway))
- [x] Backend on-prem punya **`APP_KEY`** tetap. `backend/docker/docker-compose.onprem.yml` mewajibkannya (`APP_KEY: ${APP_KEY:?...}`) dan `docker/entrypoint.sh` berhenti di `APP_ENV=production` bila kosong. Buat **sekali** di host lalu simpan di `.env.onprem`:
  ```bash
  echo "base64:$(openssl rand -base64 32)"
  ```
  Jangan pernah diganti saat update — kunci API provider AI dan kolom terenkripsi lain tidak akan terbaca lagi.
- [x] Akun **root** atau **superadmin** di Privasimu (menu provider AI ditolak 403 untuk user tenant)
- [x] Lisensi aktif organisasi **bukan** paket `basic` — paket basic ditolak 403 untuk fitur AI (cek via `php artisan ai:cek`)
- [x] Untuk RAG/embedding: database PostgreSQL **dengan extension pgvector** (lihat [Step 5](#step-5--embedding-rag-ke-tei))

## Step 1 — Mode deployment `onprem`

**Platform Admin → System Settings** (`/platform-admin/system-settings`) → tab **Deployment** → mode `onprem` → Simpan.

Efeknya:
- Verifikasi TLS di-skip untuk host privat (self-signed internal) — lihat Step 4.
- Kuota kredit AI tidak lagi membatasi (lihat [Kredit AI](#kredit-ai-di-on-prem)).
- Aksi on-prem-only aktif (mis. reveal hasil scan Data Discovery).

Catatan: env `AI_DEPLOYMENT_MODE` hanya fallback. Seeder menulis `deployment.mode=saas` ke `system_settings`, dan nilai DB selalu menang atas env (`SettingsServiceProvider`). Jadi ubah lewat UI. Cache setting 5 menit, di-invalidate otomatis saat disimpan dari UI.

## Step 2 — Daftarkan GPU server sebagai provider AI

Backend tidak punya provider bawaan bernama "openai-compatible". Yang ada: katalog provider (OpenAI, Anthropic, DeepSeek, OpenRouter, dst.) yang **semuanya** dipanggil dengan kontrak OpenAI (`POST {api_base_url}/chat/completions`). Jadi vLLM cukup didaftarkan sebagai provider kustom.

Buka **`/settings/ai-providers`** (katalog provider, root/superadmin) → **Tambah Provider**:

| Field | Nilai |
|---|---|
| Nama Provider | `Privasimu On-Prem (vLLM)` |
| Slug | `onprem-vllm` |
| API Base URL | `https://10.0.0.50/v1` — **wajib diakhiri `/v1`**, backend menambahkan `/chat/completions` sendiri |
| Auth Header / Auth Prefix | `Authorization` / `Bearer` (default) |
| Tools, Streaming, Active | centang semua |

Lalu **Tambah Model** di provider tersebut:

| Field | Profile `qwen3-32b` | Profile `qwen3.6-27b` |
|---|---|---|
| ID Model | `qwen3-32b` (= `LLM_SERVED_NAME`, harus persis) | `qwen3.6-27b` |
| Jendela Konteks | `32768` (= `LLM_MAX_CONTEXT`) | `65536` |
| Tools | centang | centang |
| Vision | **jangan** | centang (VLM built-in) |
| Harga input/output | `0` | `0` |

Khusus profile `qwen3-32b`, kalau butuh vision (OCR dokumen pindaian via AI), tambah **provider kedua** `onprem-vlm` dengan API Base URL `https://10.0.0.50/vlm/v1` dan model `qwen2.5-vl` (= `VLM_SERVED_NAME`), flag Vision dicentang.

## Step 3 — API key + pilih model aktif

Buka **Settings** (`/settings`) → section **AI Providers** ("Penyedia AI (LLM)"):

1. **Simpan API key** untuk provider `onprem-vllm`. vLLM di stack ini tidak memeriksa token, tapi backend **wajib** punya key: string kosong membuat AI dianggap tidak tersedia, dan validasi minimal 8 karakter. Isi mis. `onprem-no-auth`. Kalau token auth NGINX diaktifkan (`nginx/conf.d/ai-services.conf`), isi token itu.
2. **Test** — backend mengirim `chat/completions` kecil (`max_tokens: 5`) ke provider.
3. **Pilih model aktif per mode**:

| Mode | Dipakai untuk | Isi dengan |
|---|---|---|
| Chat | Auto-fill, analisis, Policy/Contract Review, hampir semua fitur AI | `qwen3-32b` / `qwen3.6-27b` |
| Agent | AI Agent (tool calling, streaming). Kosong → pakai Chat | sama dengan Chat |
| Document | File yang diunggah ke AI Agent, field mapping import dokumen, vision OCR. Kosong → pakai Chat | profile B: model utama; profile A: `qwen2.5-vl` **hanya** kalau vision dibutuhkan (model 7B ini juga yang akan menjawab pertanyaan atas file unggahan) |
| Avatar / Suara | Opsional | — |

Perubahan berlaku langsung, tanpa restart backend. Provider cloud lain di katalog sebaiknya dinonaktifkan untuk site offline (lihat [offline](#deployment-offline--air-gapped-sisi-backend)).

## Step 4 — TLS antara backend dan gateway

Backend memakai dua jalur HTTP dengan aturan TLS berbeda:

| Panggilan | Kode | Verifikasi TLS |
|---|---|---|
| Chat, Agent, vision OCR, Test connection | `App\Support\OutboundHttp` | **Di-skip hanya jika** mode `onprem` **dan** host = `localhost`, `*.local`, atau **IP literal privat** (RFC1918). Hostname lain (mis. `ai-gw.bank.co.id`) tetap diverifikasi. |
| Embedding TEI (+ health check) | `EmbeddingService` (`Http::` langsung) | **Selalu diverifikasi**, apa pun modenya |

Konsekuensi praktis:
- **Paling simpel untuk chat:** pakai IP privat di API Base URL (`https://10.0.0.50/v1`) + mode `onprem` → self-signed OK.
- **Embedding via gateway HTTPS butuh cert yang dipercaya container backend.** Pakai cert dari CA internal klien, lalu tambahkan CA itu ke trust store container backend **dan** queue-worker. Cara yang bertahan saat container dibuat ulang — mount bundle gabungan:
  ```bash
  # di host backend
  cat /etc/ssl/certs/ca-certificates.crt /opt/privasimu/tls/internal-ca.crt \
    > /opt/privasimu/tls/ca-bundle-privasimu.crt
  ```
  ```yaml
  # docker-compose override untuk service backend dan queue-worker
  volumes:
    - /opt/privasimu/tls/ca-bundle-privasimu.crt:/etc/ssl/certs/ca-certificates.crt:ro
  ```
  Uji dari dalam container: `docker exec privasimu-backend curl -sS https://10.0.0.50/healthz` → `ok` tanpa `-k`.
- Cert harus punya **SAN** yang cocok dengan alamat di URL (IP atau DNS). Cert dengan CN saja ditolak klien TLS modern — lihat perintah `openssl` di [`QUICKSTART.md`](../QUICKSTART.md).

## Step 5 — Embedding (RAG) ke TEI

RAG dipakai AI Agent (`search_similar_ropa/dpia/breach`) dan indexing ROPA, DPIA, Breach, asesmen pihak ketiga, Knowledge Base. **Data Discovery / PII scan tidak memakai embedding.**

Syarat database:
- PostgreSQL + pgvector. Migrasi `create_vector_embeddings_table` membuat kolom `vector(1024)` **hanya jika** `CREATE EXTENSION vector` berhasil saat migrate; kalau gagal, kolom jadi JSON dan pencarian semantik tidak jalan. Image `postgres:16-alpine` di `backend/docker/docker-compose.onprem.yml` **tidak** berisi pgvector — ganti dengan image yang punya pgvector (mis. `pgvector/pgvector:pg16`) **sebelum** migrate pertama.
- MySQL/SQLite: menyalakan RAG ditolak (`422 RAG_REQUIRES_POSTGRES`).
- Dimensi: bge-m3 = 1024 = kolom `vector(1024)` = `config/ai_embedding.php` (`tei.dimension`). Jangan ganti ke model TEI berdimensi lain.

Langkah (semuanya lewat UI; nilai DB menang atas env `AI_EMBEDDING_*`):

1. **Root → Platform Config** (`/platform-config`) → panel **Model Embedding** → mode **API**. Mode default `blob` (dan `local`) selalu diarahkan ke sidecar ONNX `embed-onnx` dan **mengabaikan TEI** sepenuhnya.
2. **Platform Admin → System Settings → AI Embedding**:
   - Provider: `TEI`
   - TEI Base URL: `https://10.0.0.50/embed` — backend memanggil `POST {base}/embed` dan `GET {base}/health`, jadi gateway meneruskannya ke TEI `/embed` dan `/health`
   - Model: `bge-m3`
   - Aktifkan RAG
3. Index data lama: `php artisan embeddings:backfill`.

Alternatif tanpa TLS: kalau backend satu host Docker dengan stack AI dan container backend di-join ke network `privasimu-ai_ai-internal`, TEI Base URL bisa dibiarkan default `http://privasimu-embeddings:80`.

## Step 6 — OCR dan vision

- **Backend tidak memanggil endpoint `/ocr/` (PaddleOCR).** OCR di backend (`OcrScannerService`) berjalan di dalam container backend sendiri: Tesseract (`ind`+`eng`) untuk gambar dan PDF pindaian, `smalot/pdfparser` untuk PDF berteks.
- **Vision fallback** mengirim gambar halaman ke `POST {api_base_url}/chat/completions` dengan `image_url`. Model dipilih berurutan: model mode **Document** yang flag Vision-nya dicentang → model mode **Chat** yang Vision → provider bawaan `deepseek-vision` (cloud). Untuk site offline, pastikan salah satu dari dua yang pertama adalah model on-prem, dan provider `deepseek-vision` dinonaktifkan.
- Policy/Contract Review mode Vision membaca **semua** halaman lewat model vision (per halaman).
- Service `ocr` (PaddleOCR) di stack ini saat ini belum dikonsumsi backend. Boleh dibiarkan, atau dimatikan untuk menghemat VRAM (gateway tidak bergantung padanya).

## Step 7 — Verifikasi

```bash
# 1. Diagnosa AI per tenant (baca saja): mode deployment, provider/model/kunci
#    per mode (agent/chat/document), lisensi, kredit, galat provider terakhir
php artisan ai:cek
php artisan ai:cek --org="Nama Organisasi"

# 2. Smoke test langsung ke provider aktif
php artisan tinker
>>> (new \App\Services\AiService(null, 'chat'))->ask(
...   'Balas HANYA JSON {"jawaban": string}.',
...   'Jelaskan Pasal 31 UU PDP singkat', 300)
```

Output harus array dengan key `jawaban` berbahasa Indonesia. `null` = gagal — cek `storage/logs/laravel.log` (`AI Provider API error`). Di Docker: `docker exec -it privasimu-backend php artisan ai:cek`.

UI test:
1. Login sebagai DPO/Admin tenant → modul **AI Agent** → "Buatkan ROPA untuk aktivitas onboarding nasabah"
2. Response streaming 5-15 detik, Agent mengusulkan tool call `create_ropa` dengan approval gate
3. System Settings → AI Embedding menampilkan status TEI sehat (kalau RAG dipakai)

### Testing matrix per fitur

| Fitur Privasimu | Mode provider | Endpoint stack |
|---|---|---|
| AI Auto-Fill ROPA / DPIA / Breach / DSR | Chat | `/v1/chat/completions` (`response_format: json_object`, backend retry tanpa flag itu kalau 400) |
| AI Agent | Agent → Chat | `/v1/chat/completions` + `tools`, streaming |
| Upload file di AI Agent, import dokumen ROPA/DPIA | Document → Chat | `/v1/chat/completions` (atau `/vlm/v1/...`) |
| Policy / Contract Review, GAP remediation, AI Document Analyzer | Chat | `/v1/chat/completions` |
| OCR dokumen pindaian | Tesseract lokal + model Vision | `/v1/...` atau `/vlm/v1/...` |
| RAG (`search_similar_*`) | Embedding TEI | `/embed/embed` |

### Tool calling

Tools AI Agent didefinisikan dan dieksekusi di backend (`AiAgentToolExecutor::execute()`), model hanya mengusulkan `tool_calls`. Kalau tool calling tidak jalan:
1. Pastikan vLLM start dengan `--enable-auto-tool-choice --tool-call-parser hermes` (sudah default di `docker-compose.yml`)
2. Model yang dipilih untuk mode Agent memang model utama vLLM, bukan `qwen2.5-vl` (flag **Tools** di katalog hanya informasional — backend tetap mengirim `tools`)
3. Model memang reliable untuk tool calling (Qwen3 ya)

## Deployment offline / air-gapped (sisi backend)

Stack AI ini bisa sepenuhnya offline, tapi beberapa fitur backend tetap mencoba keluar ke internet:

1. **Matikan "AI boleh mengakses internet" per tenant** — admin tenant: **Pengaturan → Compliance (Kepatuhan)** (`PUT /api/pengaturan/ai-akses-web`). Default **ON**. Kalau OFF: sumber screening `web_search`, `adverse_media`, `privacy_policy` ditolak server dan disembunyikan di UI, scan berita negatif terjadwal dilewati, ekstrak profil pihak ketiga dari URL ditolak. Analisis dokumen unggahan tetap jalan.
2. **Daftar sanksi (OFAC SDN + UN Consolidated)** — `SanctionsListChecker` mengunduh `www.treasury.gov` dan `scsanctions.un.org` (cache 24 jam) dan **tidak** diatur oleh setelan di atas. Tanpa internet unduhan gagal diam-diam, daftar kosong ikut di-cache, dan hasil screening terbaca "tidak ada kecocokan" — **false negative**. Opsi:
   - izinkan egress HTTPS backend hanya ke dua host itu (firewall allowlist / proxy), atau
   - jangan pilih sumber `sanctions` saat screening dan lakukan pengecekan sanksi manual. Backend belum punya fitur impor daftar sanksi offline.
3. **Pencarian TPRM** (DuckDuckGo default, Serper, Brave — System Settings → Pencarian TPRM, atau env `TPRM_SEARCH_PROVIDER`, `SERPER_API_KEY`, `BRAVE_SEARCH_API_KEY`) semuanya butuh internet. Tidak relevan offline selama setelan nomor 1 OFF.
4. **Nonaktifkan provider AI cloud** di `/settings/ai-providers` (terutama `deepseek-vision`, fallback vision) supaya tidak ada panggilan keluar.
5. **Embedding**: jangan pakai mode `blob` (mengunduh model dari Vercel Blob). Pakai mode `api` + TEI (Step 5) atau `local`.
6. **Lisensi**: pakai `LICENSE_MODE=offline` (lihat `backend/docs/ONPREM_DEPLOY.md`).

## Kredit AI di on-prem

Dengan `deployment.mode=onprem`, `CreditService::hasCredit()` selalu lolos — tidak ada gate kuota, tidak ada reset bulanan, lisensi perpetual tidak diblokir karena kredit. Pemakaian tetap dicatat di `ai_credit_logs` untuk statistik (bobot per aksi di `CreditService::COSTS`, mis. `chat` 0.25, auto-fill 1, `policy_generator` 2, `telaah_vision` 0.25 per halaman). Gate lisensi (paket bukan `basic`) tetap berlaku.

```sql
SELECT org_id, action_type, module, status, credits_used,
       metadata, created_at
FROM ai_credit_logs
WHERE created_at > NOW() - INTERVAL '1 day'
ORDER BY created_at DESC
LIMIT 100;
```

`metadata` berisi token/model bila fitur mencatatnya. Latensi dan throughput aktual dilihat di Prometheus (vLLM metrics).

## Tuning, fallback, rollback

**Tuning:**
- `AI_TIMEOUT` (detik, default 180) — timeout HTTP ke provider untuk chat dan vision. Env ini harus diteruskan ke container backend (tidak ada di `environment:` compose on-prem secara default).
- System Settings → AI: `ai.max_concurrent_per_user` (job AI latar per user, default 5), `ai.jobs_enabled` (kill-switch job AI → 503).
- Backend memotong prompt di 24.000 karakter (~6.000 token) dan output di 4.000 token (`config/security.php`), jadi `LLM_MAX_CONTEXT=32768` sudah cukup.
- **Rate limit NGINX per IP**: semua request dari backend datang dari satu IP, jadi zona `ai_chat` (30 r/menit) dibagi seluruh user dan tenant. Naikkan sesuai jumlah user (`nginx/nginx.conf`) — backend tidak mengirim header per tenant.

**Fallback:** kalau provider error/down, `AiService` mengembalikan `null` dan fitur menampilkan pesan gagal ke user (bukan 500). Tidak ada env fallback otomatis ke provider lain.

**Rollback ke cloud:** Settings → AI Providers → pilih kembali model cloud untuk mode Chat/Agent/Document (key cloud harus tersimpan). Berlaku langsung, tanpa restart dan tanpa `config:clear`. Cache respons AI di-key per model, jadi tidak tercampur.

## Known limitations backend

Per versi backend saat ini:

- **Tidak ada konfigurasi provider via env.** `AI_PROVIDER`, `AI_PROVIDER_URL`, `AI_PROVIDER_API_KEY` di `config/ai.php` hanya "reference" dan tidak dibaca `AiService`.
- **`ai.local_llm_url`** (System Settings → AI, hint "OnPrem only — Ollama/vLLM endpoint") disimpan tapi tidak dipakai kode mana pun. Jangan andalkan — daftarkan provider seperti Step 2.
- **Embedding TEI selalu verifikasi TLS**, tidak mengikuti kebijakan on-prem `OutboundHttp`. Butuh CA yang dipercaya atau jalur HTTP internal.
- **PaddleOCR (`/ocr/`) tidak diintegrasikan.** OCR = Tesseract lokal + model vision.
- **Skip TLS on-prem hanya untuk IP literal privat / `localhost` / `*.local`**, bukan hostname DNS internal.
- **Daftar sanksi butuh internet** dan gagal diam-diam (false negative) saat offline; belum ada impor offline.
- **pgvector tidak ada** di image Postgres compose on-prem backend; RAG butuh image pgvector sebelum migrate.
