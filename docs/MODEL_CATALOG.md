# Model Catalog & Quantization Options

Panduan pilihan model untuk berbagai skenario hardware + use case.

## Dual Profile Strategy

Stack Privasimu on-prem mendukung 2 profile siap-pakai — ganti via `bash scripts/switch-profile.sh`:

### Profile A: `qwen3-32b` (Stable / Production — default)

| Komponen | Model | Quant | VRAM | Peran |
|---|---|---|---|---|
| **Primary LLM** | `Qwen/Qwen3-32B-AWQ` | AWQ Q4 | ~20 GB | Chat, tool calling, auto-fill |
| **VLM Fallback** | `Qwen/Qwen2.5-VL-7B-Instruct` | FP16 | ~15 GB | Document analyzer, OCR scan fallback |
| **Embedding** | `BAAI/bge-m3` | FP16 | ~2 GB | PII scan, semantic |
| **OCR** | PaddleOCR | — | ~3 GB | Quick-path OCR (high volume) |

**Target:** 5 deal klien enterprise sekarang. Battle-tested, vLLM support mature, AWQ widely available.
**Total VRAM:** ~40 GB (pas di L40S 48GB atau H100 80GB dengan headroom).

### Profile B: `qwen3.6-27b` (Pilot / Next-Gen)

| Komponen | Model | Quant | VRAM | Peran |
|---|---|---|---|---|
| **Primary LLM + VLM** | `Qwen/Qwen3.6-27B` | FP16 / AWQ* | 54 GB / 14 GB | Chat + vision + tool calling (semua dalam 1 model) |
| **Embedding** | `BAAI/bge-m3` | FP16 | ~2 GB | PII scan |
| **OCR** | PaddleOCR | — | ~3 GB | Quick-path OCR |

**Target:** Pilot klien opt-in. Stack lebih simple (drop Qwen2.5-VL-7B), context 262k native, hybrid DeltaNet arch.

*AWQ quant tersedia tergantung release date — cek https://huggingface.co/Qwen

**Prerequisites:**
- vLLM version yang support Gated DeltaNet architecture
- FP16 mode: H100 80GB only
- AWQ Q4 mode: L40S 48GB juga OK

**Tradeoffs:**
- ✅ Document analyzer native vision — no OCR pipeline needed untuk scan complex docs
- ✅ 262k context — baca kontrak 400+ halaman dalam 1 prompt
- ✅ Stack simpler — 1 model bukan 2
- ⚠️ Baru release, need pilot validation 2-4 minggu sebelum roll out ke klien
- ⚠️ Tool calling parser mungkin butuh adjustment (test dulu dengan `tests/test-chat.sh`)

## LLM Alternative Matrix

Sesuaikan dengan kebutuhan klien:

### Dense Model (lebih predictable)

| Model | Quant | VRAM | Strengths | Weakness |
|---|---|---|---|---|
| `Qwen/Qwen3-32B-AWQ` | AWQ Q4 | 20 GB | Best Indo, tool calling kuat, 128k ctx | — |
| `Qwen/Qwen3-14B-AWQ` | AWQ Q4 | 9 GB | Fast, fit 24 GB card, bagus untuk low-cost | Kapasitas reasoning sedikit turun |
| `Qwen/Qwen2.5-72B-Instruct-AWQ` | AWQ Q4 | 40 GB | Excellent reasoning | H100 only, lambat (40+ token/s) |
| `meta-llama/Llama-3.3-70B-Instruct-AWQ` | AWQ Q4 | 40 GB | Solid tool calling | Indo OK tapi kalah dari Qwen |
| `google/gemma-2-27b-it` | — | 54 GB FP16 / 14 GB Q4 | Official Google | Tool calling lemah untuk Privasimu workflow |
| `mistralai/Mistral-Small-Instruct-2409` | FP16 | 44 GB | Good Indo | 22B param, overkill dibanding Qwen 14B |

### MoE Model (throughput kencang, VRAM lebih kecil)

| Model | Quant | VRAM | Strengths |
|---|---|---|---|
| `Qwen/Qwen3-30B-A3B` | Q4/Q8 | 16-30 GB | MoE: 3B active param, inference cepat |
| `deepseek-ai/DeepSeek-V2-Lite-Chat` | Q4 | 14 GB | Very fast, decent Indo |
| `mistralai/Mixtral-8x7B-Instruct-v0.1` | Q4 | 24 GB | Battle-tested, tool calling decent |

### Vision Language Model (document understanding)

| Model | Quant | VRAM | Use |
|---|---|---|---|
| `Qwen/Qwen2.5-VL-7B-Instruct` | FP16 | 15 GB | OCR scan fallback + layout parsing |
| `Qwen/Qwen2.5-VL-32B-Instruct` | AWQ Q4 | 20 GB | Heavy document understanding (kontrak scan) |
| `microsoft/Phi-3.5-vision-instruct` | FP16 | 8 GB | Lightweight, cocok kalau dual-GPU |

## Embedding Model Matrix

| Model | Dim | Languages | VRAM | Use Case |
|---|---|---|---|---|
| **`BAAI/bge-m3`** (default) | 1024 | 100+ (termasuk Indo) | 2 GB | Universal |
| `BAAI/bge-reranker-v2-m3` | — | Multi | 2 GB | Rerank setelah retrieval |
| `intfloat/multilingual-e5-large` | 1024 | Multi | 2 GB | Alternative untuk bge-m3 |
| `Qwen/Qwen3-Embedding-8B` | 4096 | Multi | 16 GB | State-of-art (kalau GPU mewah) |

## OCR Alternative

| Engine | Deployment | Akurasi (Indo) | VRAM | Use |
|---|---|---|---|---|
| **PaddleOCR** (default) | Docker GPU | Bagus untuk cetak | 3 GB | KTP, form, receipt |
| Tesseract 5 | CPU | Sedang | 0 | Budget fallback |
| docTR | CPU/GPU | Bagus | 2 GB | Layout-aware |
| Qwen2.5-VL-7B | GPU | Excellent | 15 GB | Complex layout atau scan jelek |
| Google Vision API | Cloud | Excellent | — | ❌ Bukan on-prem (skip) |

## Quantization Format Explained

| Format | Bit | VRAM saving | Quality loss | Speed |
|---|---|---|---|---|
| **FP16** | 16-bit | 0% (baseline) | 0 | 1× |
| **FP8** | 8-bit | ~50% | Minimal | 1.5× (H100) |
| **INT8/Q8** | 8-bit | ~50% | Tiny | 1.2× |
| **AWQ/GPTQ Q4** | 4-bit | ~75% | Small | 1.3× |
| **Q3/Q2 (GGUF)** | 3/2-bit | ~80% | Noticeable | Varies |

**Recommendation for Privasimu on-prem:** AWQ Q4 (default). Balance best antara VRAM efficiency, inference speed, dan quality.

## Memory Math Reference

Formula untuk estimate VRAM needed:
```
VRAM ≈ (params × bytes_per_param) + (context × 0.5 GB/8k tokens) + 4GB overhead
```

Contoh Qwen3-32B AWQ Q4 @ 32k context:
```
32B × 0.5 bytes (Q4)    = 16 GB
32k × 0.5 / 8           = 2 GB KV cache
Overhead                 = 4 GB
---
Total                    ≈ 22 GB → fit di L40S 48GB dengan headroom
```

Formula for H100 80GB:
```
Qwen3-32B AWQ Q4 @ 128k context
= 16 + 8 + 4 = 28 GB → headroom 50+ GB untuk concurrent
```

## Download Commands Reference

```bash
# Primary LLM
huggingface-cli download Qwen/Qwen3-32B-AWQ \
    --local-dir /opt/privasimu/models/Qwen3-32B-AWQ

# Embedding
huggingface-cli download BAAI/bge-m3 \
    --local-dir /opt/privasimu/models/bge-m3

# Optional VLM
huggingface-cli download Qwen/Qwen2.5-VL-7B-Instruct \
    --local-dir /opt/privasimu/models/Qwen2.5-VL-7B-Instruct

# Alternative untuk tier Starter yang tight budget:
huggingface-cli download Qwen/Qwen3-14B-AWQ \
    --local-dir /opt/privasimu/models/Qwen3-14B-AWQ
```

Cek license setiap model sebelum download — commercial use clause berbeda:
- Qwen3: Apache 2.0 ✅ free commercial
- Llama 3.3: Llama License — OK untuk <700M MAU
- Gemma 2: Gemma Terms — OK commercial
- DeepSeek V3: DeepSeek License — OK commercial

## Model Update Cadence

- **Minor patch** (bugfix vLLM): auto-update via image pin
- **Model upgrade** (Qwen3 → Qwen4): staged rollout per klien, 1 klien pilot dulu
- **Architecture change** (dense → MoE): require klien approval + downtime window

Privasimu Engineering akan announce update via email + release notes di docs portal.
