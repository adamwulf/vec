#!/usr/bin/env python3
"""Re-score an E10 Markdown-extraction benchmark archive — strictly.

Reads a run directory produced by MarkdownRetrievalExperimentTests and
recomputes retrieval metrics INDEPENDENTLY of the numbers the Swift
harness wrote:

  * The set of arms and query IDs it expects comes from the committed
    manifest (queries/rubric-queries.json), NOT from whatever files happen
    to be present. A missing, duplicate/unexpected, or corrupt result file
    is a hard error (exit 1) — the scorer never silently scores a partial
    archive.
  * File rank is recomputed from each query's archived ORDERED groups (the
    1-based position of primary_file), not read from the stored file_rank.
    A disagreement with the stored value is reported.

Metrics (over ANSWERED queries only; 9 files, so top10 recall is NOT
reported): rank1, top3, top5, MRR, and an advisory passage 'pass' rate
(all criteria matched in the embedded chunk text).

Usage:
    python3 score-markdown-rubric.py <run-dir>
"""
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(SCRIPT_DIR, "..", "queries", "rubric-queries.json")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_manifest():
    with open(MANIFEST) as fh:
        m = json.load(fh)
    arms = [a["key"] for a in m["arms"]]
    queries = [(q["id"], q.get("primary_file")) for q in m["queries"]]
    if len(set(arms)) != len(arms):
        die("manifest has duplicate arm keys")
    ids = [q[0] for q in queries]
    if len(set(ids)) != len(ids):
        die("manifest has duplicate query ids")
    return arms, queries


def recompute_rank(primary, groups):
    """1-based position of primary_file among the archived ordered groups."""
    ordered = sorted(groups, key=lambda g: g.get("rank", 1 << 30))
    for g in ordered:
        if g.get("file") == primary:
            return g.get("rank")
    return None


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    run_dir = sys.argv[1]
    if not os.path.isdir(run_dir):
        die(f"{run_dir} is not a directory")

    arms, queries = load_manifest()
    expected_ids = [qid for qid, _ in queries]
    expected_files = {f"{qid}.json" for qid in expected_ids}
    primary_by_id = dict(queries)

    frozen = os.path.join(run_dir, "frozen-input-manifest.json")
    if os.path.exists(frozen):
        with open(frozen) as fh:
            fm = json.load(fh)
        print(f"run_identity: {fm.get('run_identity', '?')}")
        s = fm.get("settings", {})
        print(f"settings:     {s.get('profile_identity','?')} chunk "
              f"{s.get('chunk_chars','?')}/{s.get('chunk_overlap','?')} "
              f"concurrency {s.get('concurrency','?')} "
              f"fetch {s.get('raw_fetch_limit','?')}/coalesce {s.get('coalesce_limit','?')}")
        print(f"model files hashed: {len(fm.get('model_files', []))}")
        print()

    errors = []
    per_arm = {}
    for arm in arms:
        armdir = os.path.join(run_dir, arm)
        if not os.path.isdir(armdir):
            errors.append(f"arm '{arm}': directory missing")
            continue
        present = {f for f in os.listdir(armdir)
                   if f.startswith("q") and f.endswith(".json")}
        missing = expected_files - present
        unexpected = present - expected_files
        if missing:
            errors.append(f"arm '{arm}': missing results {sorted(missing)}")
        if unexpected:
            errors.append(f"arm '{arm}': unexpected results {sorted(unexpected)}")

        results = {}
        for qid in expected_ids:
            path = os.path.join(armdir, f"{qid}.json")
            if not os.path.exists(path):
                continue
            try:
                with open(path) as fh:
                    results[qid] = json.load(fh)
            except (json.JSONDecodeError, OSError) as exc:
                errors.append(f"arm '{arm}' {qid}: corrupt ({exc})")
        per_arm[arm] = results

    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        die("archive is incomplete or corrupt; refusing to score")

    # Recompute ranks and metrics.
    print("== Aggregate (answered queries only; rank recomputed from archived groups) ==")
    header = f"{'arm':<14} {'rank1':>6} {'top3':>6} {'top5':>6} {'MRR':>7} {'pass':>6}  n"
    print(header)
    print("-" * len(header))
    per_query_ranks = {}
    no_answer = {}
    mismatches = []
    for arm in arms:
        results = per_arm[arm]
        answered = 0
        r1 = r3 = r5 = passed = 0
        mrr = 0.0
        for qid in expected_ids:
            r = results[qid]
            primary = primary_by_id[qid]
            if primary is None:
                top = (sorted(r.get("groups", []), key=lambda g: g.get("rank", 1 << 30)) or [{}])
                top = top[0] if top else {}
                no_answer.setdefault(qid, {})[arm] = (
                    os.path.basename(top.get("file", "-") or "-"), top.get("best_score"))
                continue
            answered += 1
            rank = recompute_rank(primary, r.get("groups", []))
            stored = r.get("file_rank")
            if rank != stored:
                mismatches.append(f"{arm} {qid}: recomputed rank {rank} != stored {stored}")
            per_query_ranks.setdefault(qid, {})[arm] = rank
            if rank is not None:
                mrr += 1.0 / rank
                if rank == 1:
                    r1 += 1
                if rank <= 3:
                    r3 += 1
                if rank <= 5:
                    r5 += 1
            if (r.get("primary_audit") or {}).get("all_criteria_met") is True:
                passed += 1
        n = answered or 1
        print(f"{arm:<14} {r1:>6} {r3:>6} {r5:>6} {mrr / n:>7.3f} {passed:>6}  {answered}")
    print()

    print("== Per-query file rank (answered) ==")
    hdr = f"{'query':<8}" + "".join(f"{a:>16}" for a in arms)
    print(hdr)
    print("-" * len(hdr))
    for qid in expected_ids:
        if qid not in per_query_ranks:
            continue
        row = f"{qid:<8}"
        for arm in arms:
            rk = per_query_ranks[qid].get(arm)
            row += f"{(rk if rk is not None else '—'):>16}"
        print(row)
    print()

    if no_answer:
        print("== No-answer probes (top file / score; no cutoff) ==")
        for qid in expected_ids:
            if qid not in no_answer:
                continue
            print(f"{qid}:")
            for arm in arms:
                cell = no_answer[qid].get(arm)
                if cell:
                    fname, score = cell
                    score_s = f"{score:.3f}" if isinstance(score, (int, float)) else "-"
                    print(f"    {arm:<14} {fname}  ({score_s})")
        print()

    if mismatches:
        print("WARNING: recomputed rank disagrees with stored file_rank:", file=sys.stderr)
        for m in mismatches:
            print(f"  {m}", file=sys.stderr)

    print("File rank is authoritative (recomputed from archived groups). "
          "'pass' is an advisory embedded-text passage check and does not gate rank.")


if __name__ == "__main__":
    main()
