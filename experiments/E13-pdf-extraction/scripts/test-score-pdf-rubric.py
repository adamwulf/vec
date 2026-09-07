#!/usr/bin/env python3
import importlib.util
import math
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("score-pdf-rubric.py")
SPEC = importlib.util.spec_from_file_location("score_pdf_rubric", SCRIPT)
SCORER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCORER)


class PDFRubricScorerTests(unittest.TestCase):
    def test_rank_is_derived_from_scores_not_array_order(self):
        groups = [
            {"file": "a.pdf", "best_score": 0.2, "rank": 1},
            {"file": "b.pdf", "best_score": 0.1, "rank": 2},
        ]
        self.assertEqual(SCORER.derive_rank(groups, "b.pdf"), 2)
        self.assertIsNone(SCORER.derive_rank(groups, "missing.pdf"))

    def test_validation_rejects_nonfinite_duplicate_and_bad_order(self):
        with self.assertRaises(SCORER.ScoreError):
            SCORER.validate_groups([{"file": "a.pdf", "best_score": math.nan, "rank": 1}])
        with self.assertRaises(SCORER.ScoreError):
            SCORER.validate_groups([
                {"file": "a.pdf", "best_score": 0.2, "rank": 1},
                {"file": "a.pdf", "best_score": 0.1, "rank": 2},
            ])
        with self.assertRaises(SCORER.ScoreError):
            SCORER.validate_groups([
                {"file": "a.pdf", "best_score": 0.1, "rank": 1},
                {"file": "b.pdf", "best_score": 0.2, "rank": 2},
            ])

    def test_bucket_counts_missing_rank_as_miss(self):
        self.assertEqual(SCORER.bucket([1, 2, None]),
                         {"n": 3, "rank1": 1, "top3": 2, "mrr": 0.5})


if __name__ == "__main__":
    unittest.main()
