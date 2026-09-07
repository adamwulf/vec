# E12 image-OCR throughput / cold-warm-cache benchmark

Frozen at: 2026-09-07T09:35:32Z  
Corpus: `/Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/agent-f8aa66db/repo/experiments/E12-image-ocr/sample` — 18 frozen (sha256-pinned) image(s). Recognizer v1, requestRevision 3, maxPixelDim 4096. OS: Version 26.6.2 (Build 25G83). Build: release, 10 cores. Target extrapolation: 325000 images.

| jobs | pass | ok/att | fail | wall s | img/s | hits | misses | ocrCalls | peak RSS | mean RSS | est. 325000 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | cold | 18/18 | 0 | 26.59 | 0.68 | 0 | 18 | 18 | 273 MB | 216 MB | 133.4 h |
| 1 | warm | 18/18 | 0 | 0.01 | 1870.96 | 18 | 0 | 0 | 265 MB | 265 MB | 2.9 min |
| 4 | cold | 18/18 | 0 | 22.36 | 0.80 | 0 | 18 | 18 | 330 MB | 313 MB | 112.2 h |
| 4 | warm | 18/18 | 0 | 0.00 | 6320.87 | 18 | 0 | 0 | 310 MB | 310 MB | 51 s |
| 8 | cold | 18/18 | 0 | 26.11 | 0.69 | 0 | 18 | 18 | 356 MB | 242 MB | 130.9 h |
| 8 | warm | 18/18 | 0 | 0.00 | 11779.46 | 18 | 0 | 0 | 204 MB | 204 MB | 28 s |

### Notes

- Wall-clock and RSS are on the OCR recognizer only (ImageOCRCache + ImageOCR), driven by the harness at the stated job count; they do NOT include embedding or DB writes. All passes OCR a frozen, sha256-pinned snapshot (see frozen_images), so the bytes timed are provable and identical across cold, warm, and every job count.
- Cold = a fresh cache directory + a fresh ImageOCRCache instance. Warm = the SAME directory read by a FRESH ImageOCRCache instance whose resident LRU starts empty, so every result is served from the on-disk sidecar. This measures ONLY the disk-cache-hit path; it is NOT a fresh OS process. Process RSS and Vision's own internal caches PERSIST across the cold pass, the warm pass, and every job count within this single test process — so warm RSS is not a cold-start figure and cross-pass RSS deltas are not independent.
- Job counts run SEQUENTIALLY (1, then 4, then 8) in one process, so later iterations benefit from Vision/ANE warmup and OS file caches primed by earlier ones — a sequential-order bias that flatters higher job counts. With the tiny default corpus (18 frozen images) each pass is short and the rate is noisy; point VEC_E12_OCR_CORPUS_DIRECTORY at a larger frozen corpus for a stabler rate.
- RSS is process-wide (the whole test process, including Vision's caches and any resident OCR-cache entries), sampled on a background thread every ~20 ms; the reported peak is the max of the sampled peak and the immediate before/after reads, so a spike shorter than the sample interval can still be under-reported. It is a coarse proxy, not an OCR-only allocation figure.
- The target-count estimate is a LINEAR extrapolation of the measured images/second and assumes the frozen sample's image mix is representative — it is not (see the retrieval selection-bias note). Real-corpus images vary widely in size and text density, and ANE/Vision contention changes with scale, so treat the estimate as order-of-magnitude only.
- ImageOCR downscales any image whose largest side exceeds maxPixelDimension (4096) before recognition; small text in a very large image can be lost. This throughput number does not measure that fidelity loss.
