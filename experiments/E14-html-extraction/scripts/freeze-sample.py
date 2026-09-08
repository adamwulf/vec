#!/usr/bin/env python3
"""Freeze or verify E14's synthetic HTML corpus before observing rankings."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "sample"
MANIFEST = SAMPLE / "manifest.json"
TARGETS = {
    "article.html": "semantic article with page chrome",
    "reference.html": "non-article reference page with lists and table",
    "navigation-directory.html": "navigation-only directory preservation fallback",
    "navigation-heavy.html": "unique main content surrounded by navigation",
    "structural.html": "entities, nested lists, table, and preformatted text",
    "malformed.html": "malformed but recoverable document",
}
DISTRACTORS = {"executable-only.html": "script/style-only empty page"}


def inventory(path):
    data = path.read_bytes()
    return {
        "path": path.relative_to(SAMPLE).as_posix(),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "origin": "synthetic",
        "role": "target" if path.name in TARGETS else "distractor",
        "scenario": TARGETS.get(path.name, DISTRACTORS.get(path.name)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    paths = sorted(SAMPLE.glob("*.html"))
    files = [inventory(path) for path in paths]
    assert len(files) == 7, f"expected 7 HTML fixtures, found {len(files)}"
    assert {path.name for path in paths} == set(TARGETS) | set(DISTRACTORS)
    assert sum(item["role"] == "target" for item in files) == 6

    if args.check:
        assert MANIFEST.exists(), "manifest missing; freeze before running rankings"
        frozen = json.loads(MANIFEST.read_text())
        assert frozen["files"] == files, "frozen HTML sample changed"
        print("Verified 7 synthetic HTML fixture hashes (6 targets / 1 distractor).")
        return

    assert not MANIFEST.exists(), "manifest already exists; use --check"
    payload = {
        "schema_version": 1,
        "experiment": "E14-html-extraction",
        "frozen_at": datetime.now(timezone.utc).isoformat(),
        "scope": (
            "Seven deliberately synthetic local HTML files derived from the supplied "
            "freezedry-helper behavioral examples. They exercise selection and "
            "preservation failure modes; they are not a representative web sample "
            "and cannot establish general Readability parity or real-corpus accuracy."
        ),
        "files": files,
    }
    MANIFEST.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"Frozen {len(files)} HTML files in {MANIFEST}.")


if __name__ == "__main__":
    main()
