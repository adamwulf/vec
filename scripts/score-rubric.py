#!/usr/bin/env python3
"""Score a directory of `vec search` JSON dumps against the canonical rubric.

Expects:
  <benchmarks-dir>/q01.json ... q10.json
  scripts/rubric-queries.json (same repo)

Each q<NN>.json is the raw output of:
  swift run vec search --db <name> --format json --limit 20 "<query>"

Prints a rank table matching the format already in use in
data/retrieval-<alias>.md, followed by the canonical TOTAL line. The
output is the single source of truth for a sweep's rubric score —
copy-paste the per-query table into the results file verbatim, and
cite this script's invocation from the results-log entry so the
score is reproducible.

Usage:
  python3 scripts/score-rubric.py <benchmarks-dir>

Exit codes:
  0 — scored successfully
  2 — missing/malformed input (bad dir, missing q<NN>.json, bad JSON)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RUBRIC_PATH = REPO_ROOT / "scripts" / "rubric-queries.json"


def die(msg: str) -> None:
    print(f"score-rubric: {msg}", file=sys.stderr)
    sys.exit(2)


def load_rubric() -> dict:
    if not RUBRIC_PATH.exists():
        die(f"rubric manifest not found at {RUBRIC_PATH}")
    with RUBRIC_PATH.open() as f:
        return json.load(f)


def rank_of(results: list, target_path: str) -> int | None:
    """1-based rank of target_path in the results array. None if absent."""
    for idx, entry in enumerate(results):
        if entry.get("file") == target_path:
            return idx + 1
    return None


def points_for_rank(rank: int | None, brackets: list) -> int:
    if rank is None:
        return 0
    for bracket in brackets:
        if bracket["min"] <= rank <= bracket["max"]:
            return bracket["points"]
    return 0


def fmt_rank(rank: int | None) -> str:
    return "absent" if rank is None else str(rank)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        die("usage: score-rubric.py <benchmarks-dir>")

    bench_dir = Path(argv[1]).resolve()
    if not bench_dir.is_dir():
        die(f"benchmarks dir not found: {bench_dir}")

    rubric = load_rubric()
    targets = rubric["target_files"]
    if len(targets) != 2:
        die("rubric-queries.json currently assumes exactly 2 target files")
    t_target, s_target = targets[0], targets[1]
    brackets = rubric["scoring"]["rank_brackets"]
    queries = rubric["queries"]

    rows = []
    total = 0
    top10_either = 0
    top10_both = 0

    for q in queries:
        n = q["n"]
        path = bench_dir / f"q{n:02d}.json"
        if not path.exists():
            die(f"missing {path.name} in {bench_dir}")
        try:
            with path.open() as f:
                results = json.load(f)
        except json.JSONDecodeError as exc:
            die(f"{path.name} is not valid JSON: {exc}")
        if not isinstance(results, list):
            die(f"{path.name} must be a JSON array (got {type(results).__name__})")

        t_rank = rank_of(results, t_target["path"])
        s_rank = rank_of(results, s_target["path"])
        t_pts = points_for_rank(t_rank, brackets)
        s_pts = points_for_rank(s_rank, brackets)
        subtotal = t_pts + s_pts
        total += subtotal

        t_in_top10 = t_rank is not None and t_rank <= 10
        s_in_top10 = s_rank is not None and s_rank <= 10
        if t_in_top10 or s_in_top10:
            top10_either += 1
        if t_in_top10 and s_in_top10:
            top10_both += 1

        rows.append((n, q["text"], t_rank, s_rank, t_pts, s_pts, subtotal))

    print("| # | query | T rank | S rank | T score | S score | subtotal |")
    print("|---|-------|--------|--------|---------|---------|----------|")
    for n, text, t_rank, s_rank, t_pts, s_pts, subtotal in rows:
        print(
            f"| {n} | {text} | {fmt_rank(t_rank)} | {fmt_rank(s_rank)} | "
            f"{t_pts} | {s_pts} | {subtotal} |"
        )
    print()
    max_total = rubric["scoring"]["max_total"]
    print(
        f"TOTAL: {total}/{max_total}, "
        f"TOP10_EITHER: {top10_either}/{len(queries)}, "
        f"TOP10_BOTH: {top10_both}/{len(queries)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
