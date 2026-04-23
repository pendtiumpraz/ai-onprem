# Troubleshooting — Privasimu AI On-Prem

## Quick Diagnostic

```bash
bash scripts/status.sh      # Overview kesehatan
bash scripts/logs.sh vllm   # Log service spesifik
docker compose ps           # Container state
nvidia-smi                  # GPU utilization
df -h /opt/privasimu        # Disk space
```

## Common Issues

### 1. `nvidia-smi` tidak ditemukan / Docker tidak lihat GPU

**Gejala:**
```
Error response from daemon: could not select device driver "nvidia" with capabilities: [[gpu]]
```

**Solusi:**
```bash
# 1. Verify NVIDIA driver
nvidia-smi

# 2. Verify NVIDIA Container Toolkit
nvidia-ctk --version

# 3. Reinstall Container Toolkit runtime config
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 4. Test GPU dari container
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

Kalau masih error, kemungkinan driver tidak match CUDA version. Reinstall:
```bash
sudo apt purge nvidia-* libnvidia-*
sudo apt install nvidia-driver-550-server
sudo reboot
```

---

### 2. vLLM Out of Memory (OOM) saat startup

**Gejala (log):**
```
torch.cuda.OutOfMemoryError: CUDA out of memory. Tried to allocate X.XX GiB
```

**Solusi, cascade:**

```bash
# A. Turunkan GPU memory utilization
# Edit .env:
LLM_GPU_MEM_UTIL=0.70    # dari 0.80

# B. Turunkan max context
LLM_MAX_CONTEXT=16384    # dari 32768

# C. Pastikan tidak ada process lain pakai GPU
nvidia-smi
sudo fuser -v /dev/nvidia*   # list PID pakai GPU

# D. Kalau masih OOM di L40S 48GB dengan Qwen3-32B, coba Qwen3-14B atau Qwen2.5-32B Q4 lebih tight
```

Restart: `bash scripts/restart.sh`

---

### 3. vLLM Hang saat Model Loading (lebih dari 5 menit)

**Gejala:**
```
INFO 04-24 10:00:00 llm_engine.py:X] Loading model weights...
# Stuck selama 5+ menit
```

**Debug:**
```bash
# Cek disk I/O — model loading bottleneck di NVMe
iotop

# Cek model files complete
ls -lh /opt/privasimu/models/Qwen3-32B-AWQ/
du -sh /opt/privasimu/models/Qwen3-32B-AWQ/

# Expected: ~20 GB, ada file safetensors / *.bin
```

Kalau file corrupt atau incomplete:
```bash
# Re-download
rm -rf /opt/privasimu/models/Qwen3-32B-AWQ
bash scripts/download-models.sh
```

---

### 4. NGINX 502 Bad Gateway

**Gejala:**
```
curl -k https://localhost/v1/models
→ 502 Bad Gateway
```

**Cek urutan:**

```bash
# 1. vLLM sudah up?
docker compose ps vllm
# Status harus "Up (healthy)" — kalau "starting", tunggu

# 2. vLLM responsive?
docker compose exec vllm curl http://localhost:8000/health

# 3. Network bisa reach?
docker compose exec gateway wget -qO- http://privasimu-vllm:8000/health

# 4. NGINX log
docker compose logs gateway --tail 50
```

Common fix:
```bash
docker compose restart gateway
```

---

### 5. Streaming Response Terputus / Timeout

**Gejala:**
AI chat mulai streaming token, tiba-tiba terputus di tengah response panjang.

**Solusi:**
Edit `nginx/conf.d/ai-services.conf`:
```nginx
proxy_read_timeout 900s;    # default 600s, tambah jadi 15 menit
proxy_send_timeout 900s;
```

Reload:
```bash
docker compose exec gateway nginx -s reload
```

---

### 6. Rate Limit 429 Terlalu Aggressive

**Gejala:**
User dapat `429 Too Many Requests` padahal cuma sedikit concurrent.

**Solusi:**
Edit `nginx/nginx.conf`:
```nginx
limit_req_zone $binary_remote_addr zone=ai_chat:10m rate=100r/m;   # dari 30r/m
```

Atau turunkan burst di `nginx/conf.d/ai-services.conf`:
```nginx
limit_req zone=ai_chat burst=50 nodelay;   # dari burst=20
```

---

### 7. TLS Certificate Invalid / Browser Warning

**Gejala:**
Browser atau curl reject self-signed cert.

**Opsi:**

**A. Untuk testing/internal** — bypass:
```bash
# curl
curl -k https://...

# Privasimu backend .env
AI_PROVIDER_ALLOW_SELF_SIGNED=true
```

**B. Untuk production** — pakai cert dari CA internal klien:
```bash
# Copy cert dari CA klien
cp company-ca.crt /opt/privasimu/tls/fullchain.pem
cp company-ca.key /opt/privasimu/tls/privkey.pem

# Restart gateway
docker compose restart gateway
```

---

### 8. PaddleOCR Crash atau Tidak Start

**Gejala:**
```
docker compose ps ocr
→ status "Restarting" atau "Exited"
```

**Debug:**
```bash
docker compose logs ocr --tail 100
```

Common causes:
- GPU memory conflict dengan vLLM — set `OCR_GPU_ID=1` (kalau ada GPU kedua)
- CUDA driver version mismatch — image expect CUDA 11.7, driver terlalu lama

**Workaround** — disable OCR, pakai CPU PaddleOCR atau external service:
```yaml
# di docker-compose.yml, comment service ocr
# di backend Privasimu, set OCR_PROVIDER=cpu atau external
```

---

### 9. Embedding Endpoint Return Empty / Malformed

**Gejala:**
```
POST /embed/embed → empty array atau 500
```

**Cek:**
```bash
# bge-m3 model complete?
ls /opt/privasimu/models/bge-m3/
# Expected: config.json, pytorch_model.bin atau model.safetensors, tokenizer files

# TEI log
docker compose logs embeddings --tail 50
```

Kalau model corrupt, re-download:
```bash
rm -rf /opt/privasimu/models/bge-m3
bash scripts/download-models.sh
```

---

### 10. Prometheus Tidak Bisa Akses / Target Down

**Gejala:**
```
curl http://localhost:9090/api/v1/targets
→ vllm target "DOWN"
```

**Cek:**
```bash
# Dari container prometheus, reach vLLM?
docker compose exec prometheus wget -qO- http://privasimu-vllm:8000/metrics | head

# Cek network
docker compose exec prometheus ping privasimu-vllm
```

Restart:
```bash
docker compose restart prometheus
```

---

### 11. Storage Hampir Penuh

**Gejala:**
```
df -h /opt/privasimu
→ 90%+ full
```

**Cek apa yang besar:**
```bash
du -sh /opt/privasimu/*
du -sh /var/lib/docker/volumes/privasimu-ai_prometheus-data
```

**Clean up:**
```bash
# Prometheus data — tune retention
# Edit .env: METRICS_RETENTION=14d  (dari 30d)
docker compose restart prometheus

# Docker unused images
docker image prune -a

# Old logs
docker compose logs --tail 0 vllm > /dev/null     # clear
```

---

### 12. GPU Temperature Tinggi / Thermal Throttle

**Gejala:**
```bash
nvidia-smi
→ GPU Temperature: 85°C+ (throttle zone)
```

**Action items:**
- Cek airflow — rack cooling cukup?
- Cek GPU fan (kalau passive L40S — pastikan server fan profile high)
- Reduce concurrent load — turunkan `LLM_MAX_CONTEXT` atau set rate limit lebih ketat
- Verify data center ambient temperature <24°C

---

## Escalation Path

Kalau masalah tidak resolve dalam 30 menit:

1. **Collect diagnostics:**
   ```bash
   # Dump semua log + status ke satu file
   {
       echo "=== nvidia-smi ==="
       nvidia-smi
       echo "=== docker compose ps ==="
       docker compose ps
       echo "=== vllm logs ==="
       docker compose logs vllm --tail 200
       echo "=== embeddings logs ==="
       docker compose logs embeddings --tail 100
       echo "=== gateway logs ==="
       docker compose logs gateway --tail 100
   } > /tmp/privasimu-debug-$(date +%Y%m%d-%H%M).log
   ```

2. **Contact Privasimu Engineering:**
   - Email: ops@privasimu.com
   - Subject: `[Onprem AI] <client-name> — <short-description>`
   - Attach: debug log di atas
   - Include: client name, deployment version, tanggal deploy

3. **Remote diagnosis** — kalau klien allow, kami join via:
   - SSH (via bastion klien)
   - Screen share (Zoom/Teams)
   - Read-only Grafana dashboard share

## Known Limitations

- vLLM 0.8.x: Qwen3 tool-calling kadang mis-parse kalau system prompt panjang. Workaround: shorten system prompt.
- TEI 1.5: bge-m3 tidak support batch > 16k tokens — chunk input dari backend.
- PaddleOCR: akurasi rendah untuk scan kualitas buruk (<150 DPI) — fallback ke Qwen2.5-VL-7B.
- Windows as deploy target: **tidak supported**. NVIDIA Container Toolkit hanya di Linux. Untuk dev di Windows gunakan WSL2 + Docker Desktop.
