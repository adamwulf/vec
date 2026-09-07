#!/usr/bin/env python3
"""Independently validate and score an E13 PDF retrieval run."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).resolve().parents[1] / "queries" / "rubric-queries.json"


class ScoreError(Exception):
    pass


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_groups(groups):
    files = []
    for position, group in enumerate(groups, 1):
        if group.get("rank") != position:
            raise ScoreError(f"group rank {group.get('rank')!r} != position {position}")
        if not finite_number(group.get("best_score")):
            raise ScoreError(f"non-finite best_score for {group.get('file')!r}")
        files.append(group.get("file"))
    if len(files) != len(set(files)):
        raise ScoreError("duplicate file group")
    if any(groups[i]["best_score"] < groups[i + 1]["best_score"] for i in range(len(groups) - 1)):
        raise ScoreError("groups are not score-descending")


def derive_rank(groups, primary_file):
    order = sorted(range(len(groups)), key=lambda index: -groups[index]["best_score"])
    for rank, index in enumerate(order, 1):
        if groups[index].get("file") == primary_file:
            return rank
    return None


def bucket(ranks):
    count = len(ranks)
    return {
        "n": count,
        "rank1": sum(rank == 1 for rank in ranks),
        "top3": sum(rank is not None and rank <= 3 for rank in ranks),
        "mrr": (sum(1.0 / rank if rank else 0.0 for rank in ranks) / count) if count else 0.0,
    }


def correct_page_hit(matches, primary_page):
    for match in matches:
        if match.get("chunk_type") == "pdf_page" and not isinstance(match.get("page_number"), int):
            raise ScoreError("PDF page match lacks page provenance")
    return primary_page in {match.get("page_number") for match in matches}


def score(run_directory, manifest_path=DEFAULT_MANIFEST):
    run = Path(run_directory)
    manifest_bytes = Path(manifest_path).read_bytes()
    manifest = json.loads(manifest_bytes)
    frozen = read_json(run / "frozen-input-manifest.json")
    if frozen.get("query_manifest_sha256") != hashlib.sha256(manifest_bytes).hexdigest():
        raise ScoreError("query manifest differs from frozen hash")
    files = frozen.get("files", [])
    fingerprints = {(item["path"], item["bytes"], item["sha256"].lower()) for item in files}
    if len(fingerprints) != manifest["corpus"]["expected_pdf_files"]:
        raise ScoreError("frozen PDF count/fingerprints do not match the rubric")
    allowed_files = {item[0] for item in fingerprints}
    query_ids = [query["id"] for query in manifest["queries"]]
    if len(query_ids) != len(set(query_ids)):
        raise ScoreError("duplicate query id")

    output = {"run_identity": frozen.get("run_identity"), "arms": {}, "per_query": []}
    per_query = {query_id: {} for query_id in query_ids}
    per_query_page_hits = {query_id: {} for query_id in query_ids}
    expected_json = {f"{query_id}.json" for query_id in query_ids}
    for arm in manifest["arms"]:
        key = arm["key"]
        arm_dir = run / key
        present = {name for name in os.listdir(arm_dir)
                   if name.endswith(".json") and name != "arm-summary.json"}
        if present != expected_json:
            raise ScoreError(f"arm {key}: partial or unexpected query archive")
        summary = read_json(arm_dir / "arm-summary.json")
        if summary.get("arm") != key or summary.get("text_extraction") != arm["text_extraction"]:
            raise ScoreError(f"arm {key}: summary identity mismatch")
        if summary.get("processed_count") != len(files) or summary.get("failed_count") != 0:
            raise ScoreError(f"arm {key}: incomplete PDF processing")
        per_file = summary.get("per_file_chunks", [])
        if {entry.get("path") for entry in per_file} != allowed_files or len(per_file) != len(files):
            raise ScoreError(f"arm {key}: per-file accounting differs from frozen corpus")
        if sum(entry.get("chunks", 0) for entry in per_file) != summary.get("total_chunks"):
            raise ScoreError(f"arm {key}: per-file chunk total mismatch")
        cache = summary.get("pdf_ocr_cache", {})
        if key == "raw" and any(cache.get(field, 0) for field in ("hits", "misses", "ocr_calls")):
            raise ScoreError("raw arm invoked PDF OCR")

        ranks = []
        passage_passes = 0
        page_hits = 0
        for query in manifest["queries"]:
            result = read_json(arm_dir / f"{query['id']}.json")
            if result.get("id") != query["id"] or result.get("text") != query["text"]:
                raise ScoreError(f"arm {key} query identity mismatch: {query['id']}")
            groups = result.get("groups", [])
            validate_groups(groups)
            if any(group.get("file") not in allowed_files for group in groups):
                raise ScoreError(f"arm {key} {query['id']}: result outside frozen corpus")
            rank = derive_rank(groups, query["primary_file"])
            if rank != result.get("file_rank"):
                raise ScoreError(f"arm {key} {query['id']}: stored rank differs from derived rank")
            primary_matches = next((group.get("matches", []) for group in groups
                                    if group.get("file") == query["primary_file"]), [])
            try:
                page_hit = rank is not None and correct_page_hit(primary_matches, query["primary_page"])
            except ScoreError as error:
                raise ScoreError(f"arm {key} {query['id']}: {error}") from error
            if page_hit:
                page_hits += 1
            ranks.append(rank)
            if result.get("passage_criteria_met") is True:
                passage_passes += 1
            per_query[query["id"]][key] = rank
            per_query_page_hits[query["id"]][key] = page_hit
        output["arms"][key] = {"metrics": bucket(ranks), "passage_passes": passage_passes,
                               "correct_page_hits": page_hits,
                               "total_chunks": summary.get("total_chunks"), "cache": cache}

    output["per_query"] = [{"id": query["id"], "primary_file": query["primary_file"],
                             "primary_page": query["primary_page"], "ranks": per_query[query["id"]],
                             "page_hits": per_query_page_hits[query["id"]]}
                            for query in manifest["queries"]]
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()
    try:
        result = score(arguments.run_directory)
    except (ScoreError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"error: {error}\n")
    if arguments.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    for key, arm in result["arms"].items():
        metrics = arm["metrics"]
        print(f"TOTAL {key}: rank1 {metrics['rank1']}/{metrics['n']} "
              f"top3 {metrics['top3']}/{metrics['n']} MRR {metrics['mrr']:.3f} "
              f"correct-page {arm['correct_page_hits']}/{metrics['n']} "
              f"passage {arm['passage_passes']}/{metrics['n']}")


if __name__ == "__main__":
    main()
