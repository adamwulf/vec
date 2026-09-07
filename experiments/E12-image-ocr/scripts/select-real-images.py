#!/usr/bin/env python3
"""Deterministically select a capped, unbiased real-image sample for the E12
throughput benchmark, stage it, and record full provenance.

Selection rule (fixed, reproducible, unbiased by OCR success or rank):
  1. Recursively find every file under ROOT whose lowercase extension is in the
     frozen ImageOCR supported set (unsupported formats are the ONLY exclusion).
  2. Sort the absolute paths ascending (a stable total order).
  3. Stride-sample with step = max(1, total // TARGET), taking ALL indices
     0, step, 2*step, ... < total, so the sample spans the WHOLE sorted corpus
     (tail included) rather than clustering in one folder or truncating the
     end. The resulting count is near TARGET (never truncated to it); the
     script rejects a count outside [100, 200] so it stays within the cap.
  4. Copy each selected file into STAGE_DIR under an index-prefixed name
     (`NNNN__<basename>`) to avoid cross-folder basename collisions while
     preserving the sorted order.

Emits a provenance JSON (source path, staged name, bytes, sha256 for every
selected file, plus the selection parameters) so the exact sample can be
audited and reproduced.
"""
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

# Frozen ImageOCR raster set (avif is runtime-conditional; none present here).
SUPPORTED = {"jpg", "jpeg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp"}


def sha256_file(path):
    h = hashlib.sha256()
    total = 0
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
            total += len(chunk)
    return total, h.hexdigest()


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: select-real-images.py <root> <stage_dir> <provenance.json> <target_count>")
    root = Path(sys.argv[1]).resolve()
    stage = Path(sys.argv[2]).resolve()
    prov_path = Path(sys.argv[3]).resolve()
    target = int(sys.argv[4])
    if not root.is_dir():
        sys.exit(f"root {root} is not a directory")
    if target < 1:
        sys.exit("target_count must be >= 1")

    all_paths = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            if ext in SUPPORTED:
                all_paths.append(os.path.join(dirpath, name))
    all_paths.sort()
    total = len(all_paths)
    if total == 0:
        sys.exit(f"no supported images under {root}")

    step = max(1, total // target)
    selected_idx = list(range(0, total, step))  # all stride picks; NOT truncated to target
    selected = [all_paths[i] for i in selected_idx]
    if not (100 <= len(selected) <= 200):
        sys.exit(f"selected count {len(selected)} outside [100, 200]; adjust target (total={total}, step={step})")

    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    files_meta = []
    for order, src in enumerate(selected):
        base = os.path.basename(src)
        staged_name = f"{order:04d}__{base}"
        dst = stage / staged_name
        shutil.copy2(src, dst)
        nbytes, digest = sha256_file(dst)
        files_meta.append({
            "order": order,
            "staged_name": staged_name,
            "source_path": src,
            "bytes": nbytes,
            "sha256": digest,
        })

    provenance = {
        "experiment": "E12-image-ocr",
        "purpose": "capped real-image throughput sample",
        "source_root": str(root),
        "supported_extensions": sorted(SUPPORTED),
        "total_supported_found": total,
        "selection_rule": "sort absolute paths ascending; stride step=max(1, total//target); take ALL indices 0,step,2*step,...<total (spans full corpus incl. tail; NOT truncated to target). Unbiased by OCR success/rank; only unsupported formats excluded.",
        "target_count": target,
        "stride_step": step,
        "selected_count": len(selected),
        "stage_dir": str(stage),
        "files": files_meta,
    }
    prov_path.parent.mkdir(parents=True, exist_ok=True)
    with open(prov_path, "w") as fh:
        json.dump(provenance, fh, indent=2, sort_keys=True)
    print(f"selected {len(selected)}/{total} images (step={step}) -> {stage}")
    print(f"provenance -> {prov_path}")


if __name__ == "__main__":
    main()
