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
  * File rank is DERIVED from each query's archived groups by stable
    best_score-descending order (ties keep the archived array order, which
    is what SearchResultCoalescer preserves). The scorer does NOT trust the
    stored `rank` / `file_rank` fields; instead it REJECTS the archive if
    those fields, the group order, the scores (must be finite), or the file
    set (no duplicate file groups) are inconsistent.

Metrics (over ANSWERED queries only; 9 files, so top10 recall is NOT
reported): rank1, top3, top5, MRR, and an advisory passage 'pass' rate
(all criteria matched in the pre-tokenizer model input).

Usage:
    python3 score-markdown-rubric.py <run-dir>
"""
import json
import math
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(SCRIPT_DIR, "..", "queries", "rubric-queries.json")


class ScoreError(Exception):
    """An archive inconsistency that must abort scoring."""


def _finite(v):
    # bool is a subclass of int — exclude it explicitly.
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate_groups(groups):
    """Finite scores + no duplicate file groups. Raises ScoreError."""
    files = []
    for g in groups:
        bs = g.get("best_score")
        if not _finite(bs):
            raise ScoreError(f"non-finite best_score: {bs!r} (file {g.get('file')!r})")
        for m in g.get("matches", []):
            for k in ("score", "distance"):
                v = m.get(k)
                if v is not None and not _finite(v):
                    raise ScoreError(f"non-finite match {k}: {v!r} (file {g.get('file')!r})")
        files.append(g.get("file"))
    if len(set(files)) != len(files):
        raise ScoreError(f"duplicate file group(s) in {files}")


def validate_ranking(groups):
    """The archived array must carry sequential `rank` fields and be in
    non-increasing best_score order (score-descending, ties allowed).
    Raises ScoreError on any inconsistency."""
    for i, g in enumerate(groups):
        if g.get("rank") != i + 1:
            raise ScoreError(f"group rank {g.get('rank')!r} != array position {i + 1}")
    for i in range(len(groups) - 1):
        if groups[i]["best_score"] < groups[i + 1]["best_score"]:
            raise ScoreError(
                f"groups not score-descending at index {i}: "
                f"{groups[i]['best_score']} < {groups[i + 1]['best_score']}")


def derive_rank(groups, primary):
    """1-based rank of `primary` by stable best_score-descending order.

    The archived array is validated to already be in that order, so the
    rank is the 1-based array index; None if primary is absent."""
    order = sorted(range(len(groups)), key=lambda i: -groups[i]["best_score"])  # stable ties
    for pos, i in enumerate(order):
        if groups[i].get("file") == primary:
            return pos + 1
    return None


def evaluate_answered(groups, stored_file_rank, primary):
    """Validate + derive rank for an answered query. Raises ScoreError if
    the saved file_rank disagrees with the derived rank."""
    validate_groups(groups)
    validate_ranking(groups)
    rank = derive_rank(groups, primary)
    if rank != stored_file_rank:
        raise ScoreError(f"stored file_rank {stored_file_rank!r} != derived {rank!r} for {primary!r}")
    return rank


def evaluate_no_answer(groups):
    """Validate a no-answer query's groups; return the top group (by score)."""
    validate_groups(groups)
    validate_ranking(groups)
    return groups[0] if groups else None


def result_json_files(armdir):
    """Every per-query result file in an arm directory: all `.json` EXCEPT
    the arm summary. Does NOT assume query IDs start with 'q' — the manifest
    allows any filename-safe id (e.g. 'na01')."""
    return {f for f in os.listdir(armdir)
            if f.endswith(".json") and f != "arm-summary.json"}


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
        b = fm.get("build", {})
        print(f"build:        {b.get('configuration','?')} git {str(b.get('git_head'))[:12]} "
              f"dirty={b.get('git_dirty')} model_files={len(fm.get('model_files', []))}")
        print()

    # Load results, enforcing completeness/integrity.
    errors = []
    per_arm = {}
    for arm in arms:
        armdir = os.path.join(run_dir, arm)
        if not os.path.isdir(armdir):
            errors.append(f"arm '{arm}': directory missing")
            continue
        present = result_json_files(armdir)
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
            except (json.JSONDecodeError, OSError, ValueError) as exc:
                errors.append(f"arm '{arm}' {qid}: corrupt ({exc})")
        per_arm[arm] = results

    # Derive ranks + detect inconsistency BEFORE reporting anything.
    per_query_ranks = {}
    no_answer = {}
    for arm in arms:
        for qid in expected_ids:
            r = per_arm.get(arm, {}).get(qid)
            if r is None:
                continue
            primary = primary_by_id[qid]
            groups = r.get("groups", [])
            try:
                if primary is None:
                    top = evaluate_no_answer(groups) or {}
                    no_answer.setdefault(qid, {})[arm] = (
                        os.path.basename(top.get("file", "-") or "-"), top.get("best_score"))
                else:
                    rank = evaluate_answered(groups, r.get("file_rank"), primary)
                    per_query_ranks.setdefault(qid, {})[arm] = rank
            except ScoreError as exc:
                errors.append(f"arm '{arm}' {qid}: inconsistent ({exc})")

    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        die("archive is incomplete, corrupt, or inconsistent; refusing to score")

    # Aggregate.
    print("== Aggregate (answered queries only; rank derived from best_score desc) ==")
    header = f"{'arm':<14} {'rank1':>6} {'top3':>6} {'top5':>6} {'MRR':>7} {'pass':>6}  n"
    print(header)
    print("-" * len(header))
    for arm in arms:
        results = per_arm[arm]
        answered = r1 = r3 = r5 = passed = 0
        mrr = 0.0
        for qid in expected_ids:
            if primary_by_id[qid] is None:
                continue
            answered += 1
            rank = per_query_ranks[qid][arm]
            if rank is not None:
                mrr += 1.0 / rank
                r1 += 1 if rank == 1 else 0
                r3 += 1 if rank <= 3 else 0
                r5 += 1 if rank <= 5 else 0
            if (results[qid].get("primary_audit") or {}).get("all_criteria_met") is True:
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

    print("File rank is derived from archived best_score (descending, stable). "
          "'pass' is an advisory pre-tokenizer passage check and does not gate rank.")


if __name__ == "__main__":
    main()
