#!/usr/bin/env python3
"""Freeze or verify the committed 16-file E11 caption sample, before ranking."""
import argparse
from datetime import datetime, timezone
import hashlib
import html
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "sample"
MANIFEST = SAMPLE / "manifest.json"
TIMING = re.compile(r"^\s*((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})\s+-->\s+((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})(?:\s.*)?$")
VOICE = re.compile(r"<v(?:\.[^\s>]+)*\s+([^>]+)>")


def seconds(timestamp):
    result = 0
    for part in timestamp.split(":"):
        result = result * 60 + float(part)
    return result


def inventory(path):
    data = path.read_bytes()
    source = data.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    cues = []
    for block in re.split(r"\n[ \t]*\n", source):
        lines = block.splitlines()
        first = lines[0].strip() if lines else ""
        if first.split(maxsplit=1)[:1] not in [["WEBVTT"], ["NOTE"], ["STYLE"], ["REGION"]]:
            for i in range(min(2, len(lines))):
                match = TIMING.fullmatch(lines[i])
                if match:
                    payload = "\n".join(lines[i + 1:])
                    words = html.unescape(re.sub(r"<[^>]*>", "", payload)).split()
                    cues.append((seconds(match[1]), seconds(match[2]), words))
                    break
    rolling = 0
    for previous, current in zip(cues, cues[1:]):
        if previous[0] <= current[0] < previous[1]:
            limit = min(len(previous[2]), len(current[2]))
            if any(previous[2][-n:] == current[2][:n] for n in range(limit, 1, -1)):
                rolling += 1
    relative = path.relative_to(SAMPLE).as_posix()
    real = relative.startswith("real/")
    assert cues and all(end > start for start, end, _ in cues), f"No valid cues or bad durations: {path}"
    return {"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "origin": "real" if real else "synthetic", "cue_count": len(cues),
            "first_start_seconds": cues[0][0], "last_end_seconds": max(c[1] for c in cues),
            "speaker_names": sorted({html.unescape(name).strip() for name in VOICE.findall(source)}),
            "rolling_overlap_transitions": rolling,
            "raw_cue_words_including_repeats": sum(len(c[2]) for c in cues)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the frozen manifest without rewriting it")
    args = parser.parse_args()
    files = [inventory(path) for path in sorted(SAMPLE.rglob("*.vtt"))]
    assert len(files) == 16, f"Expected 16 VTT files, found {len(files)}"
    assert sum(f["origin"] == "real" for f in files) == 1, "Expected exactly one real file"
    assert sum(f["cue_count"] >= 200 for f in files) >= 6, "Expected at least six long files"
    assert sum(f["cue_count"] <= 60 for f in files) >= 6, "Expected several short files"
    assert sum(f["rolling_overlap_transitions"] >= 2 for f in files) >= 2, "Expected two rolling files"
    assert any(f["speaker_names"] for f in files) and any(not f["speaker_names"] for f in files)
    original = Path("/tmp/LinksDatabase/YouTube/__4ZMGgQqKE.localized/__4ZMGgQqKE.en.vtt")
    if original.exists():
        assert next(f["sha256"] for f in files if f["origin"] == "real") == hashlib.sha256(original.read_bytes()).hexdigest()
    if args.check:
        assert json.loads(MANIFEST.read_text())["files"] == files, "Frozen sample changed"
        print(f"Verified {len(files)} caption hashes and sampling requirements.")
    else:
        assert not MANIFEST.exists(), "Manifest already exists; use --check, do not overwrite a frozen sample"
        result = {"schema_version": 1, "experiment": "E11-vtt-extraction",
                  "frozen_at": datetime.now(timezone.utc).isoformat(),
                  "real_source": str(original), "real_files": 1, "synthetic_files": 15,
                  "scope": "One real caption file plus fifteen explicitly synthetic varied-topic transcripts; no claim of real-corpus representativeness.",
                  "files": files}
        MANIFEST.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print(f"Frozen {len(files)} captions in {MANIFEST}.")


if __name__ == "__main__":
    main()
