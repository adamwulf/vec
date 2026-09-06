#!/usr/bin/env python3
"""Re-score an E10 Markdown-extraction benchmark archive.

Reads a run directory produced by MarkdownRetrievalExperimentTests and
recomputes the retrieval metrics from the per-query JSON — independent of
the numbers the Swift harness wrote, so an archive can be re-scored later
if the scoring rule is questioned. The per-query `file_rank` is the
authoritative signal; passage criteria are advisory.

Usage:
    python3 score-markdown-rubric.py <run-dir>

Metrics (over ANSWERED queries only; the corpus has 9 files, so top10
recall is deliberately NOT reported):
    rank1  - primary file ranked #1
    top3   - primary file in the top 3 file groups
    top5   - primary file in the top 5 file groups
    MRR    - mean reciprocal rank of the primary file
    pass   - fraction whose advisory passage criteria all matched

No-answer probes are listed separately with their top file + score; no
cosine cutoff is applied.
"""
import json
import os
import sys


def load_arm(arm_dir):
    """Load every q*.json in an arm directory, sorted by query id."""
    results = []
    for name in sorted(os.listdir(arm_dir)):
        if not (name.startswith("q") and name.endswith(".json")):
            continue
        with open(os.path.join(arm_dir, name)) as fh:
            results.append(json.load(fh))
    return results


def score_arm(results):
    answered = [r for r in results if not r.get("is_no_answer")]
    n = len(answered) or 1
    rank1 = sum(1 for r in answered if r.get("file_rank") == 1)
    top3 = sum(1 for r in answered if (r.get("file_rank") or 99) <= 3)
    top5 = sum(1 for r in answered if (r.get("file_rank") or 99) <= 5)
    mrr = sum((1.0 / r["file_rank"]) if r.get("file_rank") else 0.0 for r in answered)
    passed = sum(
        1 for r in answered
        if (r.get("primary_audit") or {}).get("all_criteria_met") is True
    )
    return {
        "answered": len(answered),
        "rank1": rank1,
        "top3": top3,
        "top5": top5,
        "mrr": mrr / n,
        "pass": passed,
    }


def find_arm_dirs(run_dir):
    arms = []
    for name in sorted(os.listdir(run_dir)):
        path = os.path.join(run_dir, name)
        if not os.path.isdir(path):
            continue
        if any(f.startswith("q") and f.endswith(".json") for f in os.listdir(path)):
            arms.append((name, path))
    return arms


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    run_dir = sys.argv[1]
    if not os.path.isdir(run_dir):
        print(f"error: {run_dir} is not a directory")
        sys.exit(2)

    frozen_path = os.path.join(run_dir, "frozen-input-manifest.json")
    if os.path.exists(frozen_path):
        with open(frozen_path) as fh:
            frozen = json.load(fh)
        print(f"run_identity: {frozen.get('run_identity', '?')}")
        s = frozen.get("settings", {})
        print(f"settings:     {s.get('profile_identity','?')} "
              f"chunk {s.get('chunk_chars','?')}/{s.get('chunk_overlap','?')} "
              f"concurrency {s.get('concurrency','?')}")
        print(f"corpus:       {frozen.get('file_count','?')} markdown files")
        print()

    arms = find_arm_dirs(run_dir)
    if not arms:
        print(f"error: no arm directories with q*.json under {run_dir}")
        sys.exit(2)

    scored = {}
    per_query_ranks = {}
    no_answer = {}
    for arm, path in arms:
        results = load_arm(path)
        scored[arm] = score_arm(results)
        for r in results:
            if r.get("is_no_answer"):
                top = (r.get("top_groups") or [{}])[0]
                no_answer.setdefault(r["id"], {})[arm] = (
                    os.path.basename(top.get("file", "-") or "-"),
                    top.get("best_score"),
                )
            else:
                per_query_ranks.setdefault(r["id"], {})[arm] = r.get("file_rank")

    arm_names = [a for a, _ in arms]

    # Aggregate table.
    print("== Aggregate (answered queries only) ==")
    header = f"{'arm':<12} {'rank1':>6} {'top3':>6} {'top5':>6} {'MRR':>7} {'pass':>6}  n"
    print(header)
    print("-" * len(header))
    for arm in arm_names:
        m = scored[arm]
        print(f"{arm:<12} {m['rank1']:>6} {m['top3']:>6} {m['top5']:>6} "
              f"{m['mrr']:>7.3f} {m['pass']:>6}  {m['answered']}")
    print()

    # Per-query file rank.
    print("== Per-query file rank (answered) ==")
    hdr = f"{'query':<8}" + "".join(f"{a:>14}" for a in arm_names)
    print(hdr)
    print("-" * len(hdr))
    for qid in sorted(per_query_ranks):
        row = f"{qid:<8}"
        for arm in arm_names:
            rk = per_query_ranks[qid].get(arm)
            row += f"{(rk if rk is not None else '—'):>14}"
        print(row)
    print()

    # No-answer probes.
    if no_answer:
        print("== No-answer probes (top file / score; no cutoff) ==")
        for qid in sorted(no_answer):
            print(f"{qid}:")
            for arm in arm_names:
                cell = no_answer[qid].get(arm)
                if cell:
                    fname, score = cell
                    score_s = f"{score:.3f}" if isinstance(score, (int, float)) else "-"
                    print(f"    {arm:<12} {fname}  ({score_s})")
        print()

    print("File rank is authoritative. 'pass' is an advisory passage-criteria "
          "check and does not gate rank.")


if __name__ == "__main__":
    main()
