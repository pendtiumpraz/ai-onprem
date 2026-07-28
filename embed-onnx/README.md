# Sidecar Embedding ONNX

Melayani model embedding kecil ber-format ONNX terkuantisasi (int8) di CPU,
dengan kontrak HTTP yang sama seperti TEI sehingga bisa saling menggantikan.

Dipakai oleh mode **local** dan **blob** pada panel root
*Platform Config → Model Embedding*. Mode **api** tidak memakai sidecar ini
sama sekali.

## Kenapa terpisah dari service `embeddings` (TEI)

| | TEI (`embeddings`) | Sidecar ini (`embed-onnx`) |
|---|---|---|
| Model | bge-m3, 1024 dim | MiniLM / BGE-small / E5-small, 384 dim |
| Presisi | fp16 | int8 terkuantisasi |
| Ukuran | ~2 GB | 23 – 118 MB |
| Perangkat | GPU (compose minta nvidia) | CPU |
| Cocok untuk | throughput tinggi, on-prem berGPU | VPS kecil, deployment hemat |

## Kontrak HTTP

```
GET  /health     -> {"status":"ok","default_model":"minilm-l6-v2"}
GET  /models     -> daftar model + status termuat / ada di disk
POST /embed      -> {"inputs":["teks"],"model":"minilm-l6-v2","kind":"passage"}
                    balasan [[0.01, -0.03, ...]]  (searah urutan input)
```

`kind` bernilai `query` atau `passage` (default `passage`). Keluarga E5 dan
BGE memakai imbuhan berbeda di kedua sisi; melewatkannya membuat skor
kemiripan melenceng tanpa memunculkan error apa pun.

## Variabel lingkungan

| Variabel | Default | Keterangan |
|---|---|---|
| `PORT` | `8091` | Port dengar |
| `MODELS_DIR` | `/models` | Direktori artefak hasil unduhan mode *local* |
| `CACHE_DIR` | `/tmp/embed-cache` | Tempat menyimpan unduhan mode *blob* |
| `BLOB_BASE_URL` | — | Awalan URL publik Vercel Blob, mis. `https://<store>.public.blob.vercel-storage.com/embedding-models`. Wajib untuk mode *blob*. |
| `EMBED_MODEL` | `minilm-l6-v2` | Model default bila request tidak menyebut `model` |
| `MAX_BATCH` | `64` | Batas jumlah teks per request |

Sidecar sengaja **tidak** boleh menarik model langsung dari HuggingFace
(`allowRemoteModels = false`). Artefak harus disediakan lewat panel root agar
yang berjalan di produksi selalu berkas yang sudah ditinjau.

## Menjalankan

```bash
# Berdiri sendiri (mode local, artefak sudah diunduh panel root)
docker build -t privasimu-embed-onnx .
docker run --rm -p 8091:8091 \
  -v /srv/privasimu/models:/models:ro \
  privasimu-embed-onnx

# Mode blob
docker run --rm -p 8091:8091 \
  -e BLOB_BASE_URL=https://<store>.public.blob.vercel-storage.com/embedding-models \
  privasimu-embed-onnx
```

Arahkan backend ke sidecar lewat `.env`:

```
AI_EMBEDDING_ENABLED=true
AI_EMBEDDING_LOCAL_URL=http://127.0.0.1:8091
AI_EMBEDDING_MODELS_DIR=/srv/privasimu/models
```

Nilai `AI_EMBEDDING_MODELS_DIR` harus menunjuk direktori yang sama dengan yang
di-mount ke `/models` — panel root menulis ke sana, sidecar membacanya.

## Setelah mengganti model

Seluruh model di katalog menghasilkan 384 dimensi, jadi skema kolom vektor
tidak berubah. Tetapi **ruang vektornya berbeda**: vektor lama dan baru tidak
sebanding. Jalankan embed ulang setelah berganti model, jika tidak hasil
pencarian akan tampak acak tanpa error apa pun:

```bash
php artisan embeddings:backfill
```
