/**
 * Sidecar embedding ONNX — melayani model kecil terkuantisasi (int8) di CPU.
 *
 * Kontrak HTTP-nya sengaja dibuat sama dengan Text Embeddings Inference (TEI)
 * milik HuggingFace supaya keduanya bisa saling menggantikan tanpa mengubah
 * pemanggil di Laravel:
 *
 *   GET  /health          -> 200 saat siap
 *   POST /embed           -> body {"inputs": ["...", "..."], "model": "id"}
 *                            balasan [[float, ...], ...] searah urutan input
 *
 * Tambahan di luar TEI:
 *   GET  /models          -> daftar model yang dikenal + status termuat
 *   POST /embed  field "kind": "query" | "passage" (default "passage")
 *        Keluarga E5 dan BGE menuntut imbuhan berbeda antara sisi query dan
 *        sisi dokumen; tanpa itu skor kemiripannya melenceng.
 *
 * Sumber berkas model, berurutan:
 *   1. MODELS_DIR/<id>/     — hasil unduhan mode "local" dari panel root.
 *   2. BLOB_BASE_URL/<id>/  — mode "blob"; berkas diunduh sekali ke cache.
 *
 * Model dimuat malas (saat pertama diminta) dan disimpan di memori, jadi
 * mengganti model aktif dari panel root tidak menuntut restart container.
 */

'use strict';

const express = require('express');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const PORT = Number(process.env.PORT || 8091);
const MODELS_DIR = process.env.MODELS_DIR || '/models';
const CACHE_DIR = process.env.CACHE_DIR || '/tmp/embed-cache';
const BLOB_BASE_URL = (process.env.BLOB_BASE_URL || '').replace(/\/+$/, '');
const DEFAULT_MODEL = process.env.EMBED_MODEL || 'minilm-l6-v2';
const MAX_BATCH = Number(process.env.MAX_BATCH || 64);

const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, 'models.json'), 'utf8'));
const MODELS = catalog.models;
const FILES = catalog.files;

/** @type {Map<string, Promise<{ extractor: Function, meta: object }>>} */
const loading = new Map();

let transformers = null;

/** Impor dinamis: @huggingface/transformers hanya tersedia sebagai ESM. */
async function getTransformers() {
    if (!transformers) {
        transformers = await import('@huggingface/transformers');
        // Sidecar tidak boleh diam-diam menarik model dari internet: berkas
        // harus datang lewat panel root (lokal atau blob) supaya artefak yang
        // dipakai produksi selalu yang sudah ditinjau.
        transformers.env.allowRemoteModels = false;
        transformers.env.allowLocalModels = true;
    }
    return transformers;
}

function log(...args) {
    console.log(`[embed-onnx ${new Date().toISOString()}]`, ...args);
}

/** Apakah seluruh berkas model sudah ada di direktori tertentu. */
function isComplete(dir) {
    return FILES.every((f) => {
        const p = path.join(dir, ...f.split('/'));
        try {
            return fs.statSync(p).size > 0;
        } catch {
            return false;
        }
    });
}

/** Unduh berkas model dari blob ke cache lokal. */
async function fetchFromBlob(modelId, destDir) {
    if (!BLOB_BASE_URL) {
        throw new Error(
            `Model "${modelId}" tidak ada di ${MODELS_DIR} dan BLOB_BASE_URL belum diset`
        );
    }

    for (const file of FILES) {
        const target = path.join(destDir, ...file.split('/'));
        try {
            if (fs.statSync(target).size > 0) continue;
        } catch {
            /* belum ada — lanjut unduh */
        }

        const url = `${BLOB_BASE_URL}/${modelId}/${file}`;
        log(`unduh ${url}`);

        const res = await fetch(url);
        if (!res.ok) {
            throw new Error(`Gagal mengunduh ${file} untuk ${modelId} (HTTP ${res.status})`);
        }

        await fsp.mkdir(path.dirname(target), { recursive: true });
        await fsp.writeFile(target, Buffer.from(await res.arrayBuffer()));
    }
}

/**
 * Pastikan berkas model tersedia lokal, lalu kembalikan direktori induk dan
 * nama foldernya (bentuk yang diminta transformers.js).
 */
async function resolveModelDir(modelId) {
    const localDir = path.join(MODELS_DIR, modelId);
    if (isComplete(localDir)) {
        return { base: MODELS_DIR, name: modelId, source: 'local' };
    }

    const cacheDir = path.join(CACHE_DIR, modelId);
    if (!isComplete(cacheDir)) {
        await fsp.mkdir(cacheDir, { recursive: true });
        await fetchFromBlob(modelId, cacheDir);
    }

    if (!isComplete(cacheDir)) {
        throw new Error(`Berkas model ${modelId} tidak lengkap setelah pengunduhan`);
    }

    return { base: CACHE_DIR, name: modelId, source: 'blob' };
}

/** Muat (sekali) pipeline feature-extraction untuk satu model. */
function loadModel(modelId) {
    if (loading.has(modelId)) return loading.get(modelId);

    const meta = MODELS[modelId];
    if (!meta) {
        return Promise.reject(new Error(`Model tidak dikenal: ${modelId}`));
    }

    const task = (async () => {
        const t0 = Date.now();
        const { base, name, source } = await resolveModelDir(modelId);
        const tf = await getTransformers();

        tf.env.localModelPath = base;

        const extractor = await tf.pipeline('feature-extraction', name, {
            // q8 memetakan ke onnx/model_quantized.onnx — varian yang diunduh
            // panel root. Tanpa ini transformers.js mencari model fp32 yang
            // memang tidak ikut diunduh.
            dtype: 'q8',
            local_files_only: true,
        });

        log(`model ${modelId} siap dari ${source} dalam ${Date.now() - t0} ms`);
        return { extractor, meta };
    })();

    // Kegagalan tidak boleh dikenang selamanya: hapus dari cache supaya
    // percobaan berikutnya (mis. setelah berkas diunduh ulang) bisa berhasil.
    task.catch(() => loading.delete(modelId));
    loading.set(modelId, task);
    return task;
}

const app = express();
app.use(express.json({ limit: '8mb' }));

app.get('/health', (_req, res) => res.json({ status: 'ok', default_model: DEFAULT_MODEL }));

app.get('/models', (_req, res) => {
    res.json({
        default: DEFAULT_MODEL,
        models_dir: MODELS_DIR,
        blob_base_url: BLOB_BASE_URL || null,
        models: Object.entries(MODELS).map(([id, m]) => ({
            id,
            repo: m.repo,
            dimension: m.dimension,
            pooling: m.pooling,
            loaded: loading.has(id),
            on_disk: isComplete(path.join(MODELS_DIR, id)) || isComplete(path.join(CACHE_DIR, id)),
        })),
    });
});

app.post('/embed', async (req, res) => {
    const body = req.body || {};
    const inputs = Array.isArray(body.inputs)
        ? body.inputs
        : typeof body.inputs === 'string'
            ? [body.inputs]
            : null;

    if (!inputs || inputs.length === 0) {
        return res.status(422).json({ error: 'field "inputs" wajib berisi string atau array string' });
    }
    if (inputs.some((t) => typeof t !== 'string')) {
        return res.status(422).json({ error: 'semua elemen "inputs" harus string' });
    }
    if (inputs.length > MAX_BATCH) {
        return res.status(422).json({ error: `batch maksimal ${MAX_BATCH}, diterima ${inputs.length}` });
    }

    const modelId = body.model || DEFAULT_MODEL;
    const kind = body.kind === 'query' ? 'query' : 'passage';

    try {
        const { extractor, meta } = await loadModel(modelId);

        const prefix = (meta.prefix && meta.prefix[kind]) || '';
        const texts = prefix ? inputs.map((t) => prefix + t) : inputs;

        const output = await extractor(texts, {
            pooling: meta.pooling,
            normalize: meta.normalize !== false,
        });

        // tolist() memberi array bersarang [batch][dim]; untuk satu input
        // bentuknya bisa datar, jadi dibungkus ulang agar konsisten.
        let vectors = output.tolist();
        if (vectors.length > 0 && typeof vectors[0] === 'number') {
            vectors = [vectors];
        }

        res.json(vectors);
    } catch (e) {
        log('embed gagal:', e.message);
        res.status(500).json({ error: e.message });
    }
});

app.listen(PORT, '0.0.0.0', () => {
    log(`mendengarkan di :${PORT} — model default ${DEFAULT_MODEL}, dir ${MODELS_DIR}`);
});
