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
- [Step 6 — OCR (PaddleOCR) dan vision](#step-6--ocr-paddleocr-dan-vision)
- [Step 7 — Verifikasi](#step-7--verifikasi)
- [Deployment offline / air-gapped (sisi backend)](#deployment-offline--air-gapped-sisi-backend)
- [Kredit AI di on-prem](#kredit-ai-di-on-prem)
- [Tuning, fallback, rollback](#tuning-fallback-rollback)
- [Rate limit per tenant](#rate-limit-per-tenant)
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

Semua panggilan backend ke gateway AI — chat, agent, vision OCR, test connection, **embedding TEI** (termasuk health check), dan **cadangan PaddleOCR** — lewat satu pintu `App\Support\OutboundHttp`, jadi aturan TLS-nya sama:

| Kondisi | Verifikasi TLS |
|---|---|
| Mode `saas` | **Selalu diverifikasi** |
| Mode `onprem` + host `localhost`, `*.local`, `*.localhost`, atau **IP literal privat/reserved** (RFC1918, loopback, link-local) | **Di-skip** (self-signed internal OK) |
| Mode `onprem` + hostname lain (mis. `ai-gw.bank.co.id`) atau IP publik | Diverifikasi, memakai trust store bawaan atau `AI_CA_BUNDLE` bila diisi |

Konsekuensi praktis:
- **Paling simpel:** pakai IP privat di semua URL (`https://10.0.0.50/v1`, `https://10.0.0.50/embed`, `https://10.0.0.50/ocr`) + mode `onprem` → self-signed OK untuk chat, embedding, dan OCR sekaligus.
- **Hostname DNS internal** (cert dari CA internal klien) → verifikasi tetap jalan. Dua cara membuat CA internal dipercaya:

  **A. `AI_CA_BUNDLE` (disarankan).** Path berkas PEM yang dipakai `OutboundHttp` sebagai trust store (env `AI_CA_BUNDLE`, atau baris `system_settings` `ai.ca_bundle` yang menang atas env — belum ada di UI System Settings, jadi env adalah jalur utama). Bundle ini **menggantikan** trust store bawaan untuk **semua** panggilan keluar lewat `OutboundHttp` — termasuk provider AI cloud, server lisensi, dan server update — jadi isinya **wajib gabungan CA sistem + CA internal**. Bundle berisi CA internal saja membuat semua panggilan ke host publik gagal TLS. Path kosong atau tidak terbaca → trust store bawaan dipakai (dicatat sekali sebagai warning `OutboundHttp: AI_CA_BUNDLE tidak terbaca`).
  ```bash
  # di host backend
  cat /etc/ssl/certs/ca-certificates.crt /opt/privasimu/tls/internal-ca.crt \
    > /opt/privasimu/tls/ca-bundle-privasimu.crt
  ```
  ```yaml
  # docker-compose override untuk service backend DAN queue-worker
  environment:
    AI_CA_BUNDLE: /etc/privasimu/ca-bundle-privasimu.crt
  volumes:
    - /opt/privasimu/tls/ca-bundle-privasimu.crt:/etc/privasimu/ca-bundle-privasimu.crt:ro
  ```
  Setelah mengubah env, buat ulang container (`up -d backend queue-worker`); entrypoint backend menjalankan ulang `config:cache`.

  **B. Ganti trust store container.** Mount bundle gabungan yang sama ke `/etc/ssl/certs/ca-certificates.crt` di `backend` dan `queue-worker`. Berlaku juga untuk proses lain di container (curl, git).

  Uji dari dalam container: `docker exec privasimu-backend curl -sS --cacert /etc/privasimu/ca-bundle-privasimu.crt https://ai-gw.bank.co.id/healthz` → `ok` (cara B: tanpa `--cacert`).
- Cert harus punya **SAN** yang cocok dengan alamat di URL (IP atau DNS). Cert dengan CN saja ditolak klien TLS modern — lihat perintah `openssl` di [`QUICKSTART.md`](../QUICKSTART.md).

## Step 5 — Embedding (RAG) ke TEI

RAG dipakai AI Agent (`search_similar_ropa/dpia/breach`) dan indexing ROPA, DPIA, Breach, asesmen pihak ketiga, Knowledge Base. **Data Discovery / PII scan tidak memakai embedding.**

Syarat database:
- PostgreSQL + pgvector. `backend/docker/docker-compose.onprem.yml` memakai image `pgvector/pgvector:pg16` untuk `landlord-db` dan `tenant-db`; instalasi baru memasang extension otomatis (`backend/docker/postgres-init/01-pgvector.sh`). **Instalasi lama** yang dimigrasi dengan `postgres:16-alpine` punya kolom JSON — ikuti *Upgrade ke pgvector* di `backend/docs/ONPREM_DEPLOY.md` (ganti image, `REINDEX`, `CREATE EXTENSION`, `php artisan migrate`, `php artisan embeddings:backfill`).
- DB tenant terisolasi dibuat provisioner tanpa extension (user tenant bukan superuser). Setelah isolasi, jalankan `backend/docker/pgvector-upgrade.sql` di DB tenant itu (perintah di ONPREM_DEPLOY.md).
- MySQL/SQLite (termasuk compose full-stack di root repo, MySQL 8): menyalakan RAG ditolak (`422 RAG_REQUIRES_POSTGRES`).
- Dimensi: kolom `embedding` bertipe `vector` **tanpa dimensi tetap** (migrasi `2026_10_18_000001_pgvector_kolom_embedding_fleksibel`), jadi bge-m3 (1024), minilm (384), dan OpenAI (1536) semuanya diterima. Pencarian selalu difilter per `embedding_model`; setelah mengganti model, jalankan `php artisan embeddings:backfill`.

Langkah (semuanya lewat UI; nilai DB menang atas env `AI_EMBEDDING_*`):

1. **Root → Platform Config** (`/platform-config`) → panel **Model Embedding** → mode **API**. Mode default `blob` (dan `local`) selalu diarahkan ke sidecar ONNX `embed-onnx` dan **mengabaikan TEI** sepenuhnya.
2. **Platform Admin → System Settings → AI Embedding**:
   - Provider: `TEI`
   - TEI Base URL: `https://10.0.0.50/embed` — backend memanggil `POST {base}/embed` dan `GET {base}/health`, jadi gateway meneruskannya ke TEI `/embed` dan `/health`
   - Model: `bge-m3`
   - Aktifkan RAG
3. Index data lama: `php artisan embeddings:backfill`.

TLS embedding mengikuti [Step 4](#step-4--tls-antara-backend-dan-gateway): IP privat + mode `onprem` cukup dengan self-signed; hostname DNS butuh CA yang dipercaya (`AI_CA_BUNDLE`).

Alternatif tanpa TLS: kalau backend satu host Docker dengan stack AI dan container backend di-join ke network `privasimu-ai_ai-internal`, TEI Base URL bisa dibiarkan default `http://privasimu-embeddings:80`.

## Step 6 — OCR (PaddleOCR) dan vision

OCR backend (`OcrScannerService`) berjalan berurutan:

1. **Primer, lokal di container backend:** `smalot/pdfparser` untuk PDF berteks; Tesseract (`ind`+`eng`) untuk gambar dan halaman PDF pindaian (dirasterisasi Imagick / `pdftoppm`).
2. **Cadangan PaddleOCR (opsional)** — dipakai **hanya bila** hasil Tesseract gagal/kosong atau di bawah `OCR_PADDLE_MIN_CHARS`, URL PaddleOCR terisi, **dan** cek kesehatan lulus. Hasil Paddle hanya dipakai bila lebih panjang dari hasil Tesseract. Tidak dikonfigurasi atau service mati → langkah ini dilewati tanpa galat (perilaku lama).
3. **Cadangan vision** — bila teks masih di bawah ambang: gambar halaman dikirim ke `POST {api_base_url}/chat/completions` dengan `image_url`.

Mesin yang menghasilkan teks tercatat di field `engine` (`tesseract`, `paddleocr`, `pdfparser`, `vision`, dst.) dan di log (`OCR cadangan ke PaddleOCR`).

### Mengaktifkan cadangan PaddleOCR

Isi di `backend/.env.onprem` dan teruskan ke service `backend` **dan** `queue-worker` (OCR juga berjalan di job antrean), atau atur lewat baris `system_settings` `ocr.paddle_url` / `ocr.paddle_api_key` (nilai DB menang atas env; belum ada di UI System Settings):

| Env | Setting DB | Bawaan | Arti |
|---|---|---|---|
| `OCR_PADDLE_URL` | `ocr.paddle_url` | kosong (nonaktif) | Base URL route gateway, mis. `https://10.0.0.50/ocr` |
| `OCR_PADDLE_API_KEY` | `ocr.paddle_api_key` | kosong | Dikirim sebagai `Authorization: Bearer <kunci>` bila diisi (mis. bila token auth NGINX diaktifkan) |
| `OCR_PADDLE_TIMEOUT` | - | `60` | Timeout (detik, min. 5) per halaman |
| `OCR_PADDLE_HEALTH_TTL` | - | `60` | Lama cache hasil cek kesehatan (detik) |
| `OCR_PADDLE_MIN_CHARS` | - | `100` | Hasil Tesseract di bawah jumlah karakter ini dianggap gagal → coba Paddle |
| `OCR_PADDLE_MIN_SCORE` | - | `0.5` | Baris hasil PaddleOCR dengan skor di bawah ini dibuang |

Compose on-prem backend belum meneruskan variabel `OCR_PADDLE_*` secara bawaan; tambahkan ke blok `environment` kedua service (override), atau pakai setting DB.

Kontrak yang dipanggil backend (sama dengan `tests/test-ocr.sh`):

| Panggilan | Request |
|---|---|
| Cek kesehatan | `GET {OCR_PADDLE_URL}/` → harus 2xx (timeout 5 dtk), hasil di-cache `OCR_PADDLE_HEALTH_TTL` detik |
| OCR per gambar/halaman | `POST {OCR_PADDLE_URL}/predict/ocr_system` body `{"images": ["<base64 tanpa prefix data:>"]}` |

TLS mengikuti [Step 4](#step-4--tls-antara-backend-dan-gateway) (`OutboundHttp`, termasuk `AI_CA_BUNDLE`). PDF diproses per halaman; halaman yang gagal dilewati (log `PaddleOCR gagal`). Gateway membatasi body `/ocr/` 20 MB dan `proxy_read_timeout` 120 dtk.

Uji dari host backend:
```bash
docker exec privasimu-backend curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.0.50/ocr/   # 200
```

Mematikan service `ocr` (hemat VRAM) aman: cek kesehatan gagal dan backend langsung ke cadangan vision.

### Vision

- Model dipilih berurutan: model mode **Document** yang flag Vision-nya dicentang → model mode **Chat** yang Vision → provider bawaan `deepseek-vision` (cloud). Untuk site offline, pastikan salah satu dari dua yang pertama adalah model on-prem, dan provider `deepseek-vision` dinonaktifkan.
- Policy/Contract Review mode Vision membaca **semua** halaman lewat model vision (per halaman).

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
| OCR dokumen pindaian | Tesseract lokal → PaddleOCR (opsional) → model Vision | `/ocr/predict/ocr_system`, lalu `/v1/...` atau `/vlm/v1/...` |
| RAG (`search_similar_*`) | Embedding TEI | `/embed/embed` |

### Tool calling

Tools AI Agent didefinisikan dan dieksekusi di backend (`AiAgentToolExecutor::execute()`), model hanya mengusulkan `tool_calls`. Kalau tool calling tidak jalan:
1. Pastikan vLLM start dengan `--enable-auto-tool-choice --tool-call-parser hermes` (sudah default di `docker-compose.yml`)
2. Model yang dipilih untuk mode Agent memang model utama vLLM, bukan `qwen2.5-vl` (flag **Tools** di katalog hanya informasional — backend tetap mengirim `tools`)
3. Model memang reliable untuk tool calling (Qwen3 ya)

## Deployment offline / air-gapped (sisi backend)

Stack AI ini bisa sepenuhnya offline, tapi beberapa fitur backend tetap mencoba keluar ke internet:

1. **Matikan "AI boleh mengakses internet" per tenant** — admin tenant: **Pengaturan → Compliance (Kepatuhan)** (`PUT /api/pengaturan/ai-akses-web`). Default **ON**. Kalau OFF: sumber screening `web_search`, `adverse_media`, `privacy_policy` ditolak server dan disembunyikan di UI, scan berita negatif terjadwal dilewati, ekstrak profil pihak ketiga dari URL ditolak. Analisis dokumen unggahan tetap jalan.
2. **Daftar sanksi (OFAC SDN + UN Consolidated)** — `SanctionsListChecker` mengunduh `www.treasury.gov` dan `scsanctions.un.org` (tidak diatur setelan nomor 1); `sanksi:perbarui` mengunduh ulang tiap hari 01:30 (zona waktu aplikasi, UTC). Unduhan gagal tidak pernah di-cache sebagai daftar kosong; salinan baik terakhir di `storage/app/sanctions` tetap dipakai. Untuk situs tanpa internet:
   - matikan unduhan online: env `TPRM_SANKSI_UNDUH_ONLINE=false` atau baris `system_settings` `tprm.sanksi_unduh_online=false` (DB menang; belum ada di UI). Env diteruskan ke container lewat override compose `backend` + `queue-worker`. `sanksi:perbarui` lalu berhenti tanpa galat;
   - unduh berkas di mesin yang punya internet — `https://www.treasury.gov/ofac/downloads/sdn.csv` dan `https://scsanctions.un.org/resources/xml/en/consolidated.xml` — salin ke server, lalu impor (ulangi berkala, mis. mingguan):
     ```bash
     php artisan sanksi:impor /path/sdn.csv --sumber=ofac
     php artisan sanksi:impor /path/consolidated.xml --sumber=un
     php artisan sanksi:perbarui    # saat unduhan dimatikan: hanya menampilkan status (sumber, waktu, jumlah nama)
     ```
     `--sumber` bisa dihilangkan (ditebak dari ekstensi `.csv` / `.xml`). Di Docker, salin berkas ke volume storage dulu (`docker cp sdn.csv privasimu-backend:/var/www/html/storage/app/`).
   - alternatif: izinkan egress HTTPS backend hanya ke dua host itu (firewall allowlist / proxy).

   Bila satu atau kedua daftar tidak tersedia, hasil screening **tidak** lagi terbaca "tidak ada kecocokan": muncul temuan "Daftar sanksi tidak tersedia — hasil sanksi belum diperiksa" (atau "pemeriksaan sanksi tidak lengkap" bila hanya satu daftar yang hilang).
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
- `AI_TIMEOUT` (detik, default 180) — timeout HTTP ke provider untuk chat dan vision. Diatur di `backend/.env.onprem`; compose on-prem meneruskannya ke `backend` **dan** `queue-worker` (blok `x-ai-env`). Jaga di bawah `proxy_read_timeout` gateway (600 dtk).
- System Settings → AI: `ai.max_concurrent_per_user` (job AI latar per user, default 5), `ai.jobs_enabled` (kill-switch job AI → 503).
- Backend memotong prompt di 24.000 karakter (~6.000 token) dan output di 4.000 token (`config/security.php`), jadi `LLM_MAX_CONTEXT=32768` sudah cukup.
- **Rate limit**: per tenant, lihat [Rate limit per tenant](#rate-limit-per-tenant).

**Fallback:** kalau provider error/down, `AiService` mengembalikan `null` dan fitur menampilkan pesan gagal ke user (bukan 500). Tidak ada env fallback otomatis ke provider lain.

**Rollback ke cloud:** Settings → AI Providers → pilih kembali model cloud untuk mode Chat/Agent/Document (key cloud harus tersimpan). Berlaku langsung, tanpa restart dan tanpa `config:clear`. Cache respons AI di-key per model, jadi tidak tercampur.

## Rate limit per tenant

Semua request backend datang dari **satu IP**, jadi dulu zona `ai_chat` (30 r/menit per IP) dibagi seluruh tenant — satu tenant yang sibuk membuat tenant lain kena 429. Sekarang:

1. `AiService` (backend) mengirim header `X-Privasimu-Tenant` di setiap `chat/completions`:
   - tenant → `HMAC-SHA256(org_id, APP_KEY)` dipotong 16 heksa (tidak bisa dibalik ke UUID, tidak bisa dikorelasikan antar-instalasi);
   - panggilan tanpa org (platform/root, scheduler) → `platform`.
2. `nginx/nginx.conf` memetakan header itu ke `$ai_rate_key` (`t:<nilai>`); header kosong/format aneh → `ip:<IP klien>` (perilaku lama). Zona `ai_chat`, `ai_embed`, `ai_ocr` dikunci `$ai_rate_key`, jadi **tiap tenant punya ember sendiri**.
3. Plafon gabungan per IP (`ai_chat_ip`, `ai_embed_ip`, `ai_ocr_ip`) tetap ada, karena header dikirim klien dan bisa dipalsukan untuk mendapat ember baru. Plafon ini yang melindungi GPU.
4. Kena limit → HTTP **429** (`limit_req_status` global, termasuk `/vlm/v1/`).

Tuning (`nginx/nginx.conf` untuk `rate`, `nginx/conf.d/ai-services.conf` untuk `burst`):

| Zona | Default | Arti | Naikkan bila |
|---|---|---|---|
| `ai_chat` | 30 r/menit, burst 20 | per tenant | satu tenant dengan banyak user rutin kena 429 |
| `ai_chat_ip` | 300 r/menit, burst 100 | total backend | banyak tenant aktif bersamaan; set ≈ tenant aktif × rate per tenant, tapi jangan melebihi throughput GPU |
| `ai_embed` / `ai_embed_ip` | 300 / 3000 r/menit | embedding | backfill besar (`embeddings:backfill`) |
| `ai_ocr` / `ai_ocr_ip` | 60 / 600 r/menit | OCR (cadangan PaddleOCR, 1 request per halaman) | banyak PDF pindaian diproses bersamaan |

Pantau pembagian beban per tenant di access log (`tenant=<hash>` di akhir baris):

```bash
docker exec privasimu-gateway sh -c "grep ' 429 ' /var/log/nginx/ai-access.log | grep -o 'tenant=[^ ]*' | sort | uniq -c | sort -rn"
```

Mencari tenant dari hash (di host backend): `php artisan tinker` → `\App\Services\AiService::tenantHeader('<org_id>')`.

Setelah mengubah config: `docker exec privasimu-gateway nginx -t && docker exec privasimu-gateway nginx -s reload`.

## Known limitations backend

Per versi backend saat ini:

- **Tidak ada konfigurasi provider via env.** `AI_PROVIDER`, `AI_PROVIDER_URL`, `AI_PROVIDER_API_KEY` di `config/ai.php` hanya "reference" dan tidak dibaca `AiService`.
- **`ai.local_llm_url`** deprecated dan sudah dihapus dari UI System Settings; tidak dibaca kode mana pun. Daftarkan provider seperti Step 2.
- **Skip TLS on-prem hanya untuk IP literal privat / `localhost` / `*.local`**, bukan hostname DNS internal — untuk hostname internal pakai `AI_CA_BUNDLE` (Step 4).
- **`backend/docker/docker-compose.onprem.yml` belum meneruskan `AI_CA_BUNDLE` dan `OCR_PADDLE_*`** (blok `x-ai-env` hanya berisi `AI_TIMEOUT`, `AI_DEPLOYMENT_MODE`, `AI_EMBEDDING_*`). Tambahkan lewat override compose untuk `backend` dan `queue-worker`, atau isi baris `system_settings` (`ai.ca_bundle`, `ocr.paddle_url`, `ocr.paddle_api_key`). Hal yang sama berlaku untuk `TPRM_SANKSI_UNDUH_ONLINE`.
- **PaddleOCR hanya cadangan** untuk hasil Tesseract yang gagal/tipis, bukan pengganti Tesseract; tidak ada mode "PaddleOCR saja".
- **Header `X-Privasimu-Tenant` baru dikirim `AiService`.** Panggilan LLM yang tidak lewat `AiService` — streaming AI Agent (`AiAgentController`), AI Chat (`AiChatController`), Avatar, field mapping impor dokumen (`AiFieldMappingService`), vision OCR dan cadangan PaddleOCR (`OcrScannerService`), dan embedding (`EmbeddingService`) — belum membawanya, jadi masih jatuh ke ember per-IP (`ip:<IP backend>`). Header bisa ditambahkan di sana dengan `AiService::tenantHeader($orgId)`.
- **DB tenant terisolasi tidak otomatis punya pgvector** (provisioner memakai `template0` + user tenant non-superuser). Jalankan `backend/docker/pgvector-upgrade.sql` setelah isolasi.
