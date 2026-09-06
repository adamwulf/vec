#!/usr/bin/env python3
"""Cheap regression test for score-markdown-rubric.py.

Runs standalone (no benchmark, no model, no corpus):

    python3 test_score_markdown_rubric.py

Exercises the ranking/consistency logic that reviewer 1 flagged: rank must
be DERIVED from best_score (descending, stable), and archives with a
mismatched group order, a wrong file_rank, non-finite scores, or duplicate
file groups must be REJECTED. Equal-score ties must be accepted and ranked
in archived array order. Exits non-zero on any failure.
"""
import importlib.util
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scorer", os.path.join(HERE, "score-markdown-rubric.py"))
scorer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scorer)


def group(rank, file, score, matches=None):
    return {"rank": rank, "file": file, "best_score": score, "match_count": 1,
            "matches": matches if matches is not None else [{"score": score, "distance": 1 - score}]}


def expect_ok(desc, fn):
    try:
        fn()
        print(f"  OK   {desc}")
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL {desc}: unexpected {type(exc).__name__}: {exc}")
        raise SystemExit(1)


def expect_reject(desc, fn):
    try:
        fn()
    except scorer.ScoreError:
        print(f"  OK   {desc} (rejected)")
        return
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL {desc}: wrong error {type(exc).__name__}: {exc}")
        raise SystemExit(1)
    print(f"  FAIL {desc}: was NOT rejected")
    raise SystemExit(1)


def main():
    print("test_score_markdown_rubric:")

    # 1. Valid score-descending archive: derived rank matches, no error.
    g = [group(1, "A", 0.90), group(2, "B", 0.50), group(3, "C", 0.10)]
    expect_ok("valid score-desc, derive rank of B == 2",
              lambda: _assert_eq(scorer.evaluate_answered(g, 2, "B"), 2))
    expect_ok("valid score-desc, primary absent -> rank None",
              lambda: _assert_eq(scorer.evaluate_answered(g, None, "Z"), None))

    # 2. Equal-score ties are accepted; rank follows archived array order.
    tie = [group(1, "A", 0.70), group(2, "B", 0.70), group(3, "C", 0.70)]
    expect_ok("equal-score ties accepted, B is rank 2 by array order",
              lambda: _assert_eq(scorer.evaluate_answered(tie, 2, "B"), 2))

    # 3. Mismatched order (reviewer's bug): rank1 score .20 before rank2 .90.
    bad_order = [group(1, "A", 0.20), group(2, "B", 0.90)]
    expect_reject("mismatched order (low score ranked first)",
                  lambda: scorer.evaluate_answered(bad_order, 1, "A"))

    # 4. Non-finite score (NaN) is rejected.
    nan_groups = [group(1, "A", float("nan")), group(2, "B", 0.10)]
    expect_reject("NaN best_score",
                  lambda: scorer.evaluate_answered(nan_groups, 1, "A"))
    inf_match = [group(1, "A", 0.90, matches=[{"score": float("inf"), "distance": 0.1}])]
    expect_reject("non-finite match score",
                  lambda: scorer.evaluate_answered(inf_match, 1, "A"))

    # 5. Duplicate file group is rejected.
    dup = [group(1, "A", 0.90), group(2, "A", 0.50)]
    expect_reject("duplicate file group",
                  lambda: scorer.evaluate_answered(dup, 1, "A"))

    # 6. Non-sequential rank field is rejected.
    bad_rank = [group(1, "A", 0.90), group(5, "B", 0.50)]
    expect_reject("non-sequential rank field",
                  lambda: scorer.evaluate_answered(bad_rank, 1, "A"))

    # 7. Stored file_rank disagreeing with derived rank is rejected.
    expect_reject("wrong stored file_rank",
                  lambda: scorer.evaluate_answered(g, 1, "B"))  # B is really rank 2

    # 8. No-answer path validates too (NaN rejected).
    expect_reject("no-answer with NaN score",
                  lambda: scorer.evaluate_no_answer(nan_groups))
    expect_ok("no-answer valid -> top group is A",
              lambda: _assert_eq(scorer.evaluate_no_answer(g)["file"], "A"))

    # 9. File discovery must not assume query IDs start with 'q', and must
    #    exclude arm-summary.json.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        for name in ("na01.json", "q02.json", "arm-summary.json"):
            open(os.path.join(td, name), "w").close()
        expect_ok("result_json_files finds non-q id, excludes arm-summary",
                  lambda: _assert_eq(scorer.result_json_files(td), {"na01.json", "q02.json"}))

    print("all regression checks passed")


def _assert_eq(actual, expected):
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


if __name__ == "__main__":
    main()
