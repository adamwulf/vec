#!/usr/bin/env python3
"""Re-score E11 using E10's score-derived ranking validation.

Usage: python3 score-vtt-rubric.py RUN_DIRECTORY [--json]

Ranks and retrieval metrics are recomputed from query groups. Noise counts
come from the Swift extractor audit; this script verifies their arithmetic,
per-file totals, denominators, and agreement with indexed chunk counts.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path

EXPERIMENT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "e10_score", EXPERIMENT.parent / "E10-markdown-extraction/scripts/score-markdown-rubric.py")
e10 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e10)


def require(condition, message):
    if not condition:
        raise e10.ScoreError(message)


def read_json(path):
    return json.loads(path.read_text())


def validate_noise(stats):
    for scope in ("all_chunks", "passage_chunks"):
        value = stats[scope]
        for key in ("chunk_count", "timestamp_chunks", "inline_tag_chunks", "noisy_chunks"):
            require(type(value[key]) is int and value[key] >= 0, f"Invalid {scope}.{key}")
        total, timestamps, tags, union = (value[k] for k in (
            "chunk_count", "timestamp_chunks", "inline_tag_chunks", "noisy_chunks"))
        require(max(timestamps, tags) <= union <= min(total, timestamps + tags),
                f"Impossible noise union for {scope}")
        ratio = union / total if total else 0
        require(type(value["noisy_share"]) in (int, float)
                and math.isfinite(value["noisy_share"])
                and math.isclose(value["noisy_share"], ratio, abs_tol=1e-12),
                f"Wrong noise denominator for {scope}")
    for key in ("chunk_count", "timestamp_chunks", "inline_tag_chunks", "noisy_chunks"):
        require(stats["passage_chunks"][key] <= stats["all_chunks"][key],
                f"Passage {key} exceeds all-chunk {key}")


def score(run):
    manifest_bytes = (EXPERIMENT / "queries/rubric-queries.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    frozen = read_json(run / "frozen-input-manifest.json")
    require(frozen["query_manifest_sha256"] == hashlib.sha256(manifest_bytes).hexdigest(),
            "Frozen query hash differs from the committed rubric")
    queries = manifest["queries"]
    ids = [q["id"] for q in queries]
    require(len(ids) == len(set(ids)) == frozen["query_count"], "Duplicate/mismatched queries")
    arms = manifest["arms"]
    require(len(arms) == len({a["key"] for a in arms}) == 2, "Expected two unique arms")
    files = {f["path"] for f in frozen["files"]}
    require(len(files) == len(frozen["files"]) == frozen["file_count"], "Invalid frozen file set")
    output = {"run_identity": frozen["run_identity"], "query_manifest_sha256": frozen["query_manifest_sha256"],
              "settings": frozen["settings"], "arms": {}, "per_query": []}
    by_query = {q["id"]: {"id": q["id"], "text": q["text"], "primary_file": q["primary_file"], "arms": {}}
                for q in queries}
    for arm in arms:
        key = arm["key"]
        directory = run / key
        require(e10.result_json_files(directory) == {f"{qid}.json" for qid in ids},
                f"{key}: missing or unexpected query files")
        summary = read_json(directory / "arm-summary.json")
        require(summary["arm"] == key and summary["text_extraction"] == arm["text_extraction"],
                f"{key}: wrong summary identity")
        require(summary["file_count"] == summary["indexed_count"] == len(files),
                f"{key}: partial index")
        per_file = summary["per_file_chunks"]
        require({f["path"] for f in per_file} == files and len(per_file) == len(files),
                f"{key}: wrong per-file set")
        require(sum(f["chunks"] for f in per_file) == summary["total_chunks"], f"{key}: chunk total mismatch")
        validate_noise(summary["noise_stats"])
        require(summary["noise_stats"]["all_chunks"]["chunk_count"] == summary["total_chunks"],
                f"{key}: noise audit differs from indexed chunks")
        for f in per_file:
            validate_noise(f["noise_stats"])
            require(f["chunks"] == f["noise_stats"]["all_chunks"]["chunk_count"],
                    f"{key}/{f['path']}: noise audit differs from chunks")
        for scope in ("all_chunks", "passage_chunks"):
            for counter in ("chunk_count", "timestamp_chunks", "inline_tag_chunks", "noisy_chunks"):
                require(sum(f["noise_stats"][scope][counter] for f in per_file) == summary["noise_stats"][scope][counter],
                        f"{key}: per-file noise {scope}.{counter} does not sum")
        ranks, passage_passes = [], 0
        for query in queries:
            result = read_json(directory / f"{query['id']}.json")
            require(result["id"] == query["id"] and result["text"] == query["text"]
                    and result["arm"] == key and result.get("primary_file") == query["primary_file"],
                    f"{key}/{query['id']}: query identity mismatch")
            groups = result["groups"]
            require(all(g["file"] in files for g in groups), f"{key}: result outside frozen corpus")
            primary = query["primary_file"]
            if primary is None:
                e10.evaluate_no_answer(groups)
                rank = None
            else:
                rank = e10.evaluate_answered(groups, result.get("file_rank"), primary)
                ranks.append(rank)
                passage_passes += (result.get("primary_audit") or {}).get("all_criteria_met") is True
            by_query[query["id"]]["arms"][key] = {"rank": rank,
                "top_file": groups[0]["file"] if groups else None,
                "passage_all_met": (result.get("primary_audit") or {}).get("all_criteria_met")}
        n = len(ranks)
        require(n > 0, "No answered queries")
        output["arms"][key] = {"answered_queries": n,
            "hit_at_1_count": sum(r == 1 for r in ranks), "hit_at_1": sum(r == 1 for r in ranks) / n,
            "hit_at_5_count": sum(r is not None and r <= 5 for r in ranks),
            "hit_at_5": sum(r is not None and r <= 5 for r in ranks) / n,
            "mrr": sum(1 / r if r else 0 for r in ranks) / n,
            "advisory_passage_passes": passage_passes, "total_chunks": summary["total_chunks"],
            "noise_stats": summary["noise_stats"]}
    output["per_query"] = [by_query[qid] for qid in ids]
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = score(args.run_directory)
    except (e10.ScoreError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"error: {error}\n")
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    print("arm          hit@1   hit@5   MRR     chunks  noisy/all       noisy/passages")
    for key, arm in result["arms"].items():
        all_noise = arm["noise_stats"]["all_chunks"]
        passages = arm["noise_stats"]["passage_chunks"]
        print(f"{key:<12} {arm['hit_at_1']:.3f}   {arm['hit_at_5']:.3f}   {arm['mrr']:.3f}   "
              f"{arm['total_chunks']:>6}  {all_noise['noisy_chunks']}/{all_noise['chunk_count']} "
              f"({all_noise['noisy_share']:.1%})  {passages['noisy_chunks']}/{passages['chunk_count']} "
              f"({passages['noisy_share']:.1%})")
    print("\nquery         " + "  ".join(result["arms"]))
    for query in result["per_query"]:
        print(f"{query['id']:<12}  " + "  ".join(str(query["arms"][key]["rank"]) for key in result["arms"]))
    print("\nPassage criteria are advisory pre-tokenizer checks, not token-level evidence.")


if __name__ == "__main__":
    main()
