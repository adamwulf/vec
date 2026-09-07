#!/usr/bin/env python3
"""Freeze or verify the committed E12 image sample, before any ranking.

Walks sample/ for image files, records path/bytes/sha256 plus advisory
metadata (origin real|synthetic, role target|distractor, and — for the real
images — the LinksDatabase source path they were copied from), and writes
sample/manifest.json. Re-run with --check to verify the frozen bytes and the
sampling invariants without rewriting the manifest.

The manifest is the anti-drift gate: the Swift harness requires it, verifies
its {path,bytes,sha256} set exactly equals the frozen snapshot, and binds its
sha256 into run provenance BEFORE indexing, so the fixed rubric labels can
never be scored against a sample that changed after labeling.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "sample"
MANIFEST = SAMPLE / "manifest.json"

# Image extensions the sample may contain. Mirrors ImageOCR.supportedExtensions
# (minus the runtime-conditional avif and the rejected svg/svgz); the frozen
# sample happens to use only png + jpg.
IMAGE_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp"}

# The four real rubric TARGETS (queries point at these). Value = the
# human-readable subject, for documentation only.
REAL_TARGETS = {
    "real/fbi-jan6-charges-chart.png": "bar chart: FBI Jan-6 charges, 1,575 total through Jan. 2025",
    "real/ot-sequence-diagram.png": "operational-transformation sequence diagram (Client A / Server / Client B)",
    "real/fractional-index-steps.png": "fractional-indexing insertion steps diagram",
    "real/minecraft-atmosphere-thumbnail.jpg": "YouTube Minecraft thumbnail 'ATMOSPHERE / BDOUBLEO'",
}
# Real images kept only as unlabeled competing candidates (no query).
REAL_DISTRACTORS = {
    "real/code-editor-showcase.png": "code-editor syntax-highlighting showcase (dense code text)",
    "real/app-icon-crystal.png": "stylized blue-crystal app icon (essentially no text)",
}
# Provenance: the LinksDatabase path each real image was copied from. These are
# the user's own locally-archived link assets; recorded for traceability only.
REAL_PROVENANCE = {
    "real/fbi-jan6-charges-chart.png":
        "/tmp/LinksDatabase/Notion-Addendum/183f32f4-36c1-8156-a6da-cb85e8230f14.localized/assets/CleanShot_2025-01-21_at_22.30.112x.png",
    "real/ot-sequence-diagram.png":
        "/tmp/LinksDatabase/Notion/00689cc5-609a-4b17-ad65-118dcef26089.localized/assets/1776b926cb9d4eb62d24e3c4330e060c4511a49fc3dc561f6433bda24106ab44.png",
    "real/fractional-index-steps.png":
        "/tmp/LinksDatabase/Notion/00689cc5-609a-4b17-ad65-118dcef26089.localized/assets/85519dc93ce6290597976822eb018ff5b8850c3af073d0033093a301384973d4.png",
    "real/minecraft-atmosphere-thumbnail.jpg":
        "/tmp/LinksDatabase/YouTube/__h_aNi5UeY.localized/assets/hq720.jpg",
    "real/code-editor-showcase.png":
        "/tmp/LinksDatabase/Notion/004fd054-d53e-40ec-a230-fb2acf485b7e.localized/assets/3ba60fbbf7c33e62d8797549421f9b2473a472416e4f7a9d95c742d131b7fe23.png",
    "real/app-icon-crystal.png":
        "/tmp/LinksDatabase/Notion/004fd054-d53e-40ec-a230-fb2acf485b7e.localized/assets/af178b4b045f50e57855a140324d86728a15c46d677a41ad28f46db45623711f.png",
}
# The one synthetic image no query points at.
SYNTHETIC_DISTRACTORS = {"synthetic/knitting-gauge.png"}


def inventory(path):
    data = path.read_bytes()
    rel = path.relative_to(SAMPLE).as_posix()
    origin = "real" if rel.startswith("real/") else "synthetic"
    if origin == "real":
        role = "target" if rel in REAL_TARGETS else "distractor"
    else:
        role = "distractor" if rel in SYNTHETIC_DISTRACTORS else "target"
    entry = {
        "path": rel,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "origin": origin,
        "role": role,
    }
    if origin == "real":
        entry["source_path"] = REAL_PROVENANCE.get(rel)
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="Verify the frozen manifest without rewriting it")
    args = parser.parse_args()

    paths = sorted(p for p in SAMPLE.rglob("*")
                   if p.is_file() and p.suffix.lower().lstrip(".") in IMAGE_EXTS)
    files = [inventory(p) for p in paths]

    real = [f for f in files if f["origin"] == "real"]
    synthetic = [f for f in files if f["origin"] == "synthetic"]
    targets = [f for f in files if f["role"] == "target"]

    # Frozen sampling invariants (fixed committed corpus).
    assert len(files) == 18, f"Expected 18 image files, found {len(files)}"
    assert len(real) == 6, f"Expected 6 real images, found {len(real)}"
    assert len(synthetic) == 12, f"Expected 12 synthetic images, found {len(synthetic)}"
    assert sum(f["role"] == "target" for f in real) == 4, "Expected 4 real targets"
    assert sum(f["role"] == "target" for f in synthetic) == 11, "Expected 11 synthetic targets"
    assert len(targets) == 15, f"Expected 15 rubric targets, found {len(targets)}"
    # Every declared real target/distractor and provenance path must resolve.
    present = {f["path"] for f in files}
    for p in list(REAL_TARGETS) + list(REAL_DISTRACTORS):
        assert p in present, f"Declared real image missing from sample: {p}"
    assert all(f.get("source_path") for f in real), "Every real image needs a source_path"

    if args.check:
        assert MANIFEST.exists(), "No manifest to check; run without --check first"
        assert json.loads(MANIFEST.read_text())["files"] == files, "Frozen sample changed"
        print(f"Verified {len(files)} image hashes and sampling invariants "
              f"({len(real)} real / {len(synthetic)} synthetic, {len(targets)} targets).")
    else:
        assert not MANIFEST.exists(), \
            "Manifest already exists; use --check, do not overwrite a frozen sample"
        result = {
            "schema_version": 1,
            "experiment": "E12-image-ocr",
            "frozen_at": datetime.now(timezone.utc).isoformat(),
            "real_source": "/tmp/LinksDatabase (user-local link-archive assets)",
            "real_files": len(real),
            "synthetic_files": len(synthetic),
            "target_files": len(targets),
            "scope": ("Four real text-bearing image targets plus eleven explicitly "
                      "synthetic distinct-topic rendered images, with two real and one "
                      "synthetic distractor. Selected for legible, text-dominant, "
                      "mutually-distinct content; NOT representative of the real "
                      "thumbnail/photo-heavy image corpus. No claim of real-corpus "
                      "accuracy. Queries target what each image SAYS, not external truth."),
            "files": files,
        }
        MANIFEST.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print(f"Frozen {len(files)} images in {MANIFEST}.")


if __name__ == "__main__":
    main()
