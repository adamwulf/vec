#!/usr/bin/env python3
"""Independently re-score an E12 image-OCR retrieval archive — strictly.

Reads a run directory produced by ImageOCRRetrievalExperimentTests and
recomputes retrieval metrics INDEPENDENTLY of the numbers the Swift harness
wrote. It is deliberately self-contained (no cross-experiment import).

Integrity gates (any failure aborts with exit 1 — the scorer never scores a
partial, corrupt, inconsistent, or FAKED archive):

  * Fingerprints. frozen-input-manifest.query_manifest_sha256 must equal the
    sha256 of the committed rubric; sample-manifest.json's sha256 must equal
    frozen.sample_manifest_sha256; and the sample's {path,bytes,sha256}
    fingerprints must equal the frozen corpus's.
  * Arm shape. Each arm directory must contain EXACTLY the manifest's query
    files (a missing or unexpected file is fatal). The `raw` arm MUST be an
    EMPTY index (file_count == indexed_count == total_chunks == 0) — that is
    the true, un-faked baseline, and a non-empty raw arm is rejected. The
    image-OCR arm must scan every frozen image, its per-file chunk counts must
    sum to total_chunks, and it must produce at least one chunk.
  * Ranks. File rank is DERIVED from each query's archived groups by stable
    best_score-descending order; the scorer REJECTS the archive if the stored
    file_rank, the group order/rank fields, or the scores are inconsistent.

Metrics (over ANSWERED queries; 18 files, so top10 recall is uninformative):
rank1, top3, top5, MRR, plus REAL vs SYNTHETIC subsets and an advisory
passage-pass rate. Usage:  python3 score-image-rubric.py <run-dir> [--json]
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).resolve().parents[1] / "queries" / "rubric-queries.json"


class ScoreError(Exception):
    """An archive inconsistency that must abort scoring."""


def _finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def origin_of(primary):
    if primary is None:
        return "none"
    if primary.startswith("real/"):
        return "real"
    if primary.startswith("synthetic/"):
        return "synthetic"
    return "other"


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
    """Sequential `rank` fields + non-increasing best_score order."""
    for i, g in enumerate(groups):
        if g.get("rank") != i + 1:
            raise ScoreError(f"group rank {g.get('rank')!r} != array position {i + 1}")
    for i in range(len(groups) - 1):
        if groups[i]["best_score"] < groups[i + 1]["best_score"]:
            raise ScoreError(f"groups not score-descending at index {i}: "
                             f"{groups[i]['best_score']} < {groups[i + 1]['best_score']}")


def derive_rank(groups, primary):
    """1-based rank of `primary` by stable best_score-descending order; None if absent."""
    order = sorted(range(len(groups)), key=lambda i: -groups[i]["best_score"])
    for pos, i in enumerate(order):
        if groups[i].get("file") == primary:
            return pos + 1
    return None


def evaluate_answered(groups, stored_file_rank, primary):
    """Validate + derive rank; raise if the stored file_rank disagrees."""
    validate_groups(groups)
    validate_ranking(groups)
    rank = derive_rank(groups, primary)
    if rank != stored_file_rank:
        raise ScoreError(f"stored file_rank {stored_file_rank!r} != derived {rank!r} for {primary!r}")
    return rank


def result_json_files(armdir):
    return {f for f in os.listdir(armdir) if f.endswith(".json") and f != "arm-summary.json"}


def _read_json(path):
    with open(path) as fh:
        return json.load(fh)


def score(run, manifest_path=DEFAULT_MANIFEST):
    run = Path(run)
    if not run.is_dir():
        raise ScoreError(f"{run} is not a directory")

    manifest_bytes = Path(manifest_path).read_bytes()
    manifest = json.loads(manifest_bytes)
    arms = manifest["arms"]
    queries = manifest["queries"]
    arm_keys = [a["key"] for a in arms]
    if len(set(arm_keys)) != len(arm_keys):
        raise ScoreError("manifest has duplicate arm keys")
    ids = [q["id"] for q in queries]
    if len(set(ids)) != len(ids):
        raise ScoreError("manifest has duplicate query ids")
    primary_by_id = {q["id"]: q.get("primary_file") for q in queries}
    text_extraction_by_arm = {a["key"]: a["text_extraction"] for a in arms}

    frozen = _read_json(run / "frozen-input-manifest.json")
    if frozen.get("query_manifest_sha256") != hashlib.sha256(manifest_bytes).hexdigest():
        raise ScoreError("frozen query_manifest_sha256 differs from the committed rubric")
    if frozen.get("query_count") != len(ids):
        raise ScoreError("frozen query_count differs from the manifest")
    frozen_fp = {(f["path"], f["bytes"], f["sha256"].lower()) for f in frozen["files"]}
    if len(frozen_fp) != len(frozen["files"]) or len(frozen_fp) != frozen.get("file_count"):
        raise ScoreError("frozen file set is invalid or mismatched")

    sample_bytes = (run / "sample-manifest.json").read_bytes()
    if hashlib.sha256(sample_bytes).hexdigest() != frozen.get("sample_manifest_sha256"):
        raise ScoreError("archived sample-manifest hash != frozen.sample_manifest_sha256")
    sample = json.loads(sample_bytes)
    sample_fp = {(f["path"], f["bytes"], f["sha256"].lower()) for f in sample["files"]}
    if sample_fp != frozen_fp:
        raise ScoreError("archived sample differs from the frozen corpus fingerprints")

    expected_files = {f"{qid}.json" for qid in ids}
    out = {"run_identity": frozen.get("run_identity"), "settings": frozen.get("settings"),
           "arms": {}, "per_query": []}
    per_query_ranks = {}

    for key in arm_keys:
        armdir = run / key
        if not armdir.is_dir():
            raise ScoreError(f"arm '{key}': directory missing")
        present = result_json_files(armdir)
        if present != expected_files:
            missing = sorted(expected_files - present)
            extra = sorted(present - expected_files)
            raise ScoreError(f"arm '{key}': query file set mismatch (missing={missing}, unexpected={extra})")

        summary = _read_json(armdir / "arm-summary.json")
        if summary.get("arm") != key or summary.get("text_extraction") != text_extraction_by_arm[key]:
            raise ScoreError(f"arm '{key}': summary identity mismatch")
        per_file = summary.get("per_file_chunks", [])
        includes_ocr = "image-ocr-v1" in text_extraction_by_arm[key]
        if includes_ocr:
            if summary.get("file_count") != frozen["file_count"]:
                raise ScoreError(f"arm '{key}': scanned {summary.get('file_count')} != {frozen['file_count']} frozen images")
            if {f["path"] for f in per_file} != {f[0] for f in frozen_fp} or len(per_file) != frozen["file_count"]:
                raise ScoreError(f"arm '{key}': per-file set != frozen corpus")
            if sum(f["chunks"] for f in per_file) != summary.get("total_chunks"):
                raise ScoreError(f"arm '{key}': per-file chunk sum != total_chunks")
            if summary.get("total_chunks", 0) <= 0:
                raise ScoreError(f"arm '{key}': OCR arm produced zero chunks")
            indexed = sum(1 for f in per_file if f["chunks"] > 0)
            if summary.get("indexed_count") != indexed:
                raise ScoreError(f"arm '{key}': indexed_count {summary.get('indexed_count')} != files-with-chunks {indexed}")
            if summary.get("indexed_count", 0) + summary.get("blank_count", 0) != summary.get("file_count"):
                raise ScoreError(f"arm '{key}': indexed+blank != scanned")
        else:
            # The raw baseline MUST be empty — the production scanner excludes
            # images. A non-empty raw arm means the baseline was faked.
            if not (summary.get("file_count") == 0 and summary.get("indexed_count") == 0
                    and summary.get("total_chunks") == 0 and len(per_file) == 0):
                raise ScoreError(f"arm '{key}': raw baseline is not empty (file_count/indexed/total_chunks must be 0)")

        answered = {"real": [], "synthetic": [], "all": []}
        passage_passes = 0
        for q in queries:
            qid = q["id"]
            result = _read_json(armdir / f"{qid}.json")
            if (result.get("id") != qid or result.get("text") != q["text"]
                    or result.get("arm") != key or result.get("primary_file") != q.get("primary_file")):
                raise ScoreError(f"arm '{key}' {qid}: query identity mismatch")
            groups = result.get("groups", [])
            if not all(g.get("file") in {f[0] for f in frozen_fp} for g in groups):
                raise ScoreError(f"arm '{key}' {qid}: a result file is outside the frozen corpus")
            primary = primary_by_id[qid]
            if primary is None:
                validate_groups(groups); validate_ranking(groups)
                rank = None
            else:
                rank = evaluate_answered(groups, result.get("file_rank"), primary)
                o = origin_of(primary)
                answered["all"].append(rank)
                if o in answered:
                    answered[o].append(rank)
                if (result.get("primary_audit") or {}).get("all_criteria_met") is True:
                    passage_passes += 1
            per_query_ranks.setdefault(qid, {})[key] = rank

        def bucket(ranks):
            n = len(ranks)
            if n == 0:
                return {"n": 0, "rank1": 0, "top3": 0, "top5": 0, "mrr": 0.0}
            return {"n": n,
                    "rank1": sum(1 for r in ranks if r == 1),
                    "top3": sum(1 for r in ranks if r is not None and r <= 3),
                    "top5": sum(1 for r in ranks if r is not None and r <= 5),
                    "mrr": sum((1.0 / r) if r else 0 for r in ranks) / n}

        out["arms"][key] = {
            "text_extraction": text_extraction_by_arm[key],
            "total_chunks": summary.get("total_chunks"),
            "indexed_count": summary.get("indexed_count"),
            "blank_count": summary.get("blank_count", 0),
            "advisory_passage_passes": passage_passes,
            "all": bucket(answered["all"]),
            "real": bucket(answered["real"]),
            "synthetic": bucket(answered["synthetic"]),
        }

    out["per_query"] = [{"id": qid, "primary_file": primary_by_id[qid],
                         "origin": origin_of(primary_by_id[qid]),
                         "ranks": {k: per_query_ranks.get(qid, {}).get(k) for k in arm_keys}}
                        for qid in ids]
    return out


def _fmt_bucket(b):
    n = b["n"] or 1
    return f"rank1 {b['rank1']}/{b['n']}  top3 {b['top3']}/{b['n']}  top5 {b['top5']}/{b['n']}  MRR {b['mrr']:.3f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = score(args.run_directory)
    except (ScoreError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"error: {error}\n")

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return

    print(f"run_identity: {result['run_identity']}")
    s = result.get("settings") or {}
    print(f"settings:     {s.get('profile_identity','?')} chunk {s.get('chunk_chars','?')}/{s.get('chunk_overlap','?')} "
          f"concurrency {s.get('concurrency','?')} ocrConcurrency {s.get('ocr_concurrency','?')}")
    print()
    for key, arm in result["arms"].items():
        print(f"== {key}  ({arm['text_extraction']}; chunks={arm['total_chunks']}, indexed={arm['indexed_count']}, blank={arm['blank_count']}) ==")
        print(f"  ALL       {_fmt_bucket(arm['all'])}")
        print(f"  REAL      {_fmt_bucket(arm['real'])}")
        print(f"  SYNTHETIC {_fmt_bucket(arm['synthetic'])}")
        print(f"  TOTAL {key}: rank1 {arm['all']['rank1']}/{arm['all']['n']}  "
              f"MRR {arm['all']['mrr']:.3f}  (advisory passage passes {arm['advisory_passage_passes']})")
        print()
    print("== Per-query file rank (answered) ==")
    hdr = f"{'query':<8}{'origin':<11}" + "".join(f"{k:>16}" for k in result["arms"])
    print(hdr)
    print("-" * len(hdr))
    for q in result["per_query"]:
        if q["primary_file"] is None:
            continue
        row = f"{q['id']:<8}{q['origin']:<11}"
        for k in result["arms"]:
            rk = q["ranks"].get(k)
            row += f"{(rk if rk is not None else '—'):>16}"
        print(row)
    print("\nFile rank is derived from archived best_score (descending, stable). The raw arm is an "
          "empty index by design. Passage passes are advisory pre-tokenizer checks and do not gate rank.")


if __name__ == "__main__":
    main()
