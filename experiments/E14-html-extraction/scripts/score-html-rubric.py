#!/usr/bin/env python3
"""Strictly and independently score an archived E14 retrieval run.

Usage: python3 score-html-rubric.py <run-directory>
"""

import hashlib
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
QUERY_PATH = ROOT / "queries" / "rubric-queries.json"
SAMPLE_MANIFEST_PATH = ROOT / "sample" / "manifest.json"


class ScoreError(Exception):
    pass


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ScoreError(f"cannot read {path}: {error}") from error


def finite_number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def validate_groups(groups):
    if not isinstance(groups, list):
        raise ScoreError("groups must be an array")
    files = []
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise ScoreError(f"group {index} is not an object")
        file = group.get("file")
        score = group.get("best_score")
        if not isinstance(file, str) or not file:
            raise ScoreError(f"group {index} has invalid file")
        if not finite_number(score):
            raise ScoreError(f"group {file} has non-finite best_score")
        if group.get("rank") != index + 1:
            raise ScoreError(f"group {file} rank disagrees with archive order")
        if index and groups[index - 1]["best_score"] < score:
            raise ScoreError("groups are not sorted by descending best_score")
        for match in group.get("matches", []):
            for key in ("score", "distance"):
                if key in match and not finite_number(match[key]):
                    raise ScoreError(f"group {file} has non-finite match {key}")
        files.append(file)
    if len(files) != len(set(files)):
        raise ScoreError("archive contains duplicate file groups")


def derive_rank(groups, primary):
    order = sorted(range(len(groups)), key=lambda index: -groups[index]["best_score"])
    for rank, index in enumerate(order, start=1):
        if groups[index]["file"] == primary:
            return rank
    return None


def criterion_matches(text, criterion):
    value = criterion["value"]
    flags = 0 if criterion.get("case_sensitive", False) else re.IGNORECASE
    if criterion["type"] == "contains":
        return value in text if not flags else value.casefold() in text.casefold()
    if criterion["type"] == "regex":
        return re.search(value, text, flags) is not None
    raise ScoreError(f"unsupported passage criterion type {criterion['type']!r}")


def audit_text(query, result):
    text = result.get("primary_text")
    if not isinstance(text, str):
        raise ScoreError("answered result must archive primary_text for independent audit")
    preserved = all(criterion_matches(text, item)
                    for item in query.get("passage_criteria", []))
    folded = text.casefold()
    boilerplate_absent = all(item.casefold() not in folded
                             for item in query.get("excluded_boilerplate", []))
    return preserved, boilerplate_absent


def validate_provenance(run_dir):
    provenance = load_json(run_dir / "frozen-input-manifest.json")
    expected = {
        "query_manifest_sha256": sha256(QUERY_PATH),
        "sample_manifest_sha256": sha256(SAMPLE_MANIFEST_PATH),
    }
    for key, value in expected.items():
        if provenance.get(key) != value:
            raise ScoreError(f"provenance {key} does not match committed input")
    required = ["run_identity", "git_head", "git_dirty", "package_resolved_sha256",
                "settings", "model_files"]
    missing = [key for key in required if key not in provenance]
    if missing:
        raise ScoreError(f"provenance missing fields {missing}")
    return provenance


def score(run_dir):
    manifest = load_json(QUERY_PATH)
    arms = [item["key"] for item in manifest["arms"]]
    queries = manifest["queries"]
    ids = [item["id"] for item in queries]
    if len(arms) != len(set(arms)) or len(ids) != len(set(ids)):
        raise ScoreError("rubric contains duplicate arm or query identifiers")
    provenance = validate_provenance(run_dir)

    expected_files = {f"{query_id}.json" for query_id in ids}
    results = {}
    for arm in arms:
        arm_dir = run_dir / arm
        if not arm_dir.is_dir():
            raise ScoreError(f"arm directory missing: {arm}")
        present = {path.name for path in arm_dir.glob("*.json")
                   if path.name != "arm-summary.json"}
        if present != expected_files:
            raise ScoreError(
                f"arm {arm} result set mismatch; missing={sorted(expected_files - present)} "
                f"unexpected={sorted(present - expected_files)}"
            )
        results[arm] = {query_id: load_json(arm_dir / f"{query_id}.json")
                        for query_id in ids}

    rows = []
    no_answer = []
    for arm in arms:
        ranks = []
        preservation = 0
        boilerplate = 0
        for query in queries:
            result = results[arm][query["id"]]
            groups = result.get("groups")
            validate_groups(groups)
            primary = query.get("primary_file")
            if primary is None:
                top = groups[0] if groups else None
                no_answer.append((query["id"], arm, top))
                continue
            rank = derive_rank(groups, primary)
            if result.get("file_rank") != rank:
                raise ScoreError(
                    f"{arm}/{query['id']} stored rank {result.get('file_rank')!r} "
                    f"does not match derived rank {rank!r}"
                )
            ranks.append(rank)
            kept, removed = audit_text(query, result)
            preservation += int(kept)
            boilerplate += int(removed)
        n = len(ranks)
        rows.append({
            "arm": arm,
            "n": n,
            "rank1": sum(rank == 1 for rank in ranks),
            "top3": sum(rank is not None and rank <= 3 for rank in ranks),
            "top5": sum(rank is not None and rank <= 5 for rank in ranks),
            "mrr": sum(0 if rank is None else 1 / rank for rank in ranks) / n,
            "preserved": preservation,
            "boilerplate_absent": boilerplate,
        })
    return provenance, rows, no_answer


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    try:
        provenance, rows, no_answer = score(Path(sys.argv[1]))
    except ScoreError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"run_identity: {provenance['run_identity']}")
    print("arm             rank1  top3  top5     MRR  preserved  boilerplate-absent  n")
    for row in rows:
        print(f"{row['arm']:<15} {row['rank1']:>5} {row['top3']:>5} {row['top5']:>5} "
              f"{row['mrr']:>7.3f} {row['preserved']:>10} "
              f"{row['boilerplate_absent']:>19} {row['n']:>2}")
    print("\nNo-answer probes (top file/score only; no threshold or pass claim):")
    for query_id, arm, top in no_answer:
        label = "none" if top is None else f"{top['file']} / {top['best_score']:.6f}"
        print(f"  {query_id} {arm}: {label}")
    print("\nRanks are independently derived from archived finite scores. "
          "Preservation and boilerplate checks are independent advisory text audits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
