# Referensi Perintah AI On-Prem

Perintah untuk memasang, menjalankan, dan menguji stack AI on-prem (vLLM + TEI + PaddleOCR + NGINX gateway + Prometheus). Semua skrip dijalankan dari root folder `ai-onprem/` (skrip berpindah ke root sendiri) dan membaca `.env` hasil `switch-profile.sh`.

## Daftar Isi

- [Skrip operasional (`scripts/`)](#skrip-operasional-scripts)
- [Skrip uji (`tests/`)](#skrip-uji-tests)
- [Perintah docker compose](#perintah-docker-compose)
- [Perintah gateway dan GPU](#perintah-gateway-dan-gpu)
- [Urutan instalasi singkat](#urutan-instalasi-singkat)

---

## Skrip operasional (`scripts/`)

| Skrip | Argumen | Fungsi | Catatan |
|---|---|---|---|
| `sudo bash scripts/install-prereqs.sh` | - | Ubuntu 22.04/24.04: update paket, driver NVIDIA R550 server, Docker Engine + Compose v2, NVIDIA Container Toolkit (`nvidia-ctk runtime configure`), user `privasimu` + `/opt/privasimu/{models,tls,logs}`. Hanya menampilkan saran aturan UFW | Wajib root. Butuh internet. **Reboot** setelahnya |
| `bash scripts/switch-profile.sh [profil]` | `qwen3-32b` (stabil) \| `qwen3.6-27b` (pilot). Tanpa argumen → menu interaktif | Menyalin `.env.profiles/<profil>.env` ke `.env` (`.env` lama dicadangkan `.env.backup.<waktu>`). Bila stack berjalan, menawarkan `docker compose down` + `start.sh` | Suntingan manual di `.env` hilang saat ganti profil (ada di berkas cadangan) |
| `bash scripts/download-models.sh` | - (env opsional: `HF_TOKEN`, `LLM_REPO`, `VLM_REPO`, `EMBED_REPO`) | Mengunduh model dari HuggingFace ke `$MODELS_DIR`: LLM sesuai profil, VLM Qwen2.5-VL-7B (hanya bila `VLM_MODEL_DIR` diisi, profil `qwen3-32b`), embedding bge-m3. Memasang `huggingface_hub[cli,hf_transfer]` bila belum ada | Interaktif (konfirmasi per model). Butuh internet; untuk air-gap jalankan di mesin lain lalu salin `models/` |
| `bash scripts/start.sh` | - | Memeriksa `.env`, folder model LLM, dan sertifikat `${TLS_DIR}/fullchain.pem` + `privkey.pem` (menawarkan membuat self-signed), lalu `docker compose up -d` dan `ps` | Self-signed dari skrip ini hanya ber-CN tanpa SAN; untuk backend Privasimu pakai perintah `openssl` dengan SAN di `QUICKSTART.md` |
| `bash scripts/stop.sh` | - | `docker compose down` | Volume (cache, metrik) tetap |
| `bash scripts/restart.sh` | - | `docker compose restart` lalu `ps` | Tidak membaca ulang `.env`; setelah ubah `.env` pakai `stop.sh` + `start.sh` |
| `bash scripts/status.sh` | - | Profil aktif, `docker compose ps`, utilisasi GPU (`nvidia-smi`), kesehatan gateway `/healthz`, vLLM, VLM (bila profil `vlm-fallback`), TEI, PaddleOCR, ukuran folder model | Baca saja |
| `bash scripts/logs.sh [service...]` | Nama service, mis. `vllm`, `gateway`, `ocr` (boleh beberapa) | `docker compose logs -f --tail=100` untuk semua atau service tertentu | Ctrl+C untuk keluar |
| `bash scripts/test-endpoints.sh` | - (env: `GATEWAY_HOST`, bawaan `https://localhost:443`) | Uji integrasi lewat gateway: `/healthz`, `/v1/models`, chat completion, `/embed/embed`, target Prometheus. Exit 1 bila ada yang gagal, lalu mencetak langkah koneksi ke backend | Prasyarat sebelum integrasi Privasimu. Tidak menguji OCR (pakai `tests/test-ocr.sh`) |

## Skrip uji (`tests/`)

Semua memakai `curl -k` ke `GATEWAY_HOST` (bawaan `https://localhost:${GATEWAY_HTTPS_PORT:-443}`).

| Skrip | Argumen | Endpoint | Fungsi |
|---|---|---|---|
| `bash tests/test-chat.sh` | - | `POST /v1/chat/completions` | Satu pertanyaan UU PDP ke model `LLM_SERVED_NAME` (non-streaming, 500 token) |
| `bash tests/test-embed.sh` | - | `POST /embed/embed` | Embedding tiga kalimat; keluaran array vektor |
| `bash tests/test-ocr.sh <gambar>` | Path gambar (wajib) | `POST /ocr/predict/ocr_system` body `{"images":["<base64>"]}` | Kontrak yang sama dengan cadangan PaddleOCR backend Privasimu |
| `bash tests/test-vision.sh [gambar\|URL]` | File lokal (dikirim sebagai data URL), URL gambar, atau kosong (URL contoh Wikimedia, butuh internet) | `qwen3.6-27b` → `/v1/chat/completions`; `qwen3-32b` → `/vlm/v1/chat/completions` | Uji model vision: deskripsi gambar / ekstraksi teks dokumen |

## Perintah docker compose

Dijalankan dari `ai-onprem/`. Service: `vllm`, `vlm-fallback` (profil compose `vlm-fallback`), `embeddings`, `ocr`, `gateway`, `prometheus`. Container: `privasimu-vllm`, `privasimu-vlm`, `privasimu-embeddings`, `privasimu-ocr`, `privasimu-gateway`, `privasimu-prometheus`.

| Perintah | Fungsi |
|---|---|
| `docker compose up -d` | Menyalakan stack (profil dari `COMPOSE_PROFILES` di `.env`) |
| `docker compose up -d <service>` | Menyalakan / membuat ulang satu service setelah ubah konfigurasi |
| `docker compose ps` | Status + health container |
| `docker compose logs -f --tail=100 <service>` | Tail log |
| `docker compose restart <service>` | Restart satu service (mis. `ocr` setelah crash) |
| `docker compose stop ocr` | Mematikan PaddleOCR untuk menghemat VRAM. Backend Privasimu lalu melewati cadangan PaddleOCR (health check gagal) tanpa galat |
| `docker compose down` | Menghentikan dan menghapus container (volume tetap) |
| `docker compose pull` | Menarik image baru (butuh registry/internet) |
| `docker compose config` | Menampilkan konfigurasi akhir setelah substitusi `.env` (cek variabel) |
| `docker compose exec -T vllm curl -fsS http://localhost:8000/health` | Health vLLM langsung (internal) |
| `docker compose exec -T embeddings curl -fsS http://localhost:80/health` | Health TEI |
| `docker compose exec -T ocr curl -fsS http://localhost:8868/` | Health PaddleOCR (sama dengan cek kesehatan backend `GET {OCR_PADDLE_URL}/`) |

## Perintah gateway dan GPU

| Perintah | Fungsi |
|---|---|
| `curl -k https://<ip-gpu>/healthz` | Health gateway (`ok`) |
| `docker exec privasimu-gateway nginx -t && docker exec privasimu-gateway nginx -s reload` | Validasi + muat ulang konfigurasi NGINX tanpa downtime |
| `docker exec privasimu-gateway sh -c "grep ' 429 ' /var/log/nginx/ai-access.log \| grep -o 'tenant=[^ ]*' \| sort \| uniq -c \| sort -rn"` | Tenant yang paling sering kena rate limit |
| `nvidia-smi` / `nvtop` | Pemakaian GPU/VRAM |
| `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi` | Verifikasi GPU terlihat dari Docker |
| `openssl s_client -connect <ip-gpu>:443 -servername <host> </dev/null \| openssl x509 -noout -text \| grep -A1 "Subject Alternative Name"` | Cek SAN sertifikat gateway |

## Urutan instalasi singkat

```bash
sudo bash scripts/install-prereqs.sh && sudo reboot
bash scripts/switch-profile.sh qwen3-32b      # atau qwen3.6-27b
bash scripts/download-models.sh
bash scripts/start.sh
bash scripts/test-endpoints.sh
bash tests/test-ocr.sh contoh.jpg             # bila cadangan OCR backend akan dipakai
```

Lanjutkan ke [`PRIVASIMU_INTEGRATION.md`](./PRIVASIMU_INTEGRATION.md) untuk menghubungkan backend Privasimu.
