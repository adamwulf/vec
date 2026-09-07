#!/usr/bin/env python3
"""Regression tests for score-image-rubric.py.

Builds minimal synthetic archives in a temp dir and asserts the scorer:
- computes derived target ranks correctly (incl. a primary NOT at rank 1);
- rejects a missing query file, an invalid group ordering, a stored-vs-derived
  rank disagreement, a corrupted fingerprint (sample-manifest or query
  manifest), and a FAKED non-empty raw baseline.

Run:  python3 test-score-image-rubric.py
"""
import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "score-image-rubric.py"
_spec = importlib.util.spec_from_file_location("score_image", SCRIPT)
scorer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scorer)

FILES = [("real/x.png", 10, "aa"), ("synthetic/y.png", 20, "bb")]
MANIFEST = {
    "corpus": {"scope": "test", "expected_image_files": 2},
    "arms": [{"key": "raw", "text_extraction": "raw"},
             {"key": "image-ocr-v1", "text_extraction": "image-ocr-v1"}],
    "queries": [
        {"id": "q01", "text": "real q", "categories": [], "primary_file": "real/x.png",
         "relevant_files": ["real/x.png"], "passage_criteria": []},
        {"id": "q02", "text": "synth q", "categories": [], "primary_file": "synthetic/y.png",
         "relevant_files": ["synthetic/y.png"], "passage_criteria": []},
    ],
}


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def _write(path, obj):
    path.write_text(json.dumps(obj))


def _grp(rank, file, score):
    return {"rank": rank, "file": file, "best_score": score, "match_count": 1,
            "matches": [{"score": score, "distance": 1 - score, "chunk_type": "image",
                         "line_start": None, "line_end": None, "chunk_ordinal": 1}]}


def _qresult(qid, text, arm, primary, groups, file_rank, passed):
    return {"arm": arm, "id": qid, "text": text, "categories": [], "is_no_answer": False,
            "primary_file": primary, "relevant_files": [primary], "file_rank": file_rank,
            "hit_at_1": file_rank == 1, "groups": groups,
            "primary_audit": ({"all_criteria_met": passed} if groups else None)}


def build(tmp: Path):
    """A valid archive. q01 (real) ranks 1; q02 (synthetic) ranks 2."""
    manifest_bytes = json.dumps(MANIFEST).encode()
    manifest_path = tmp / "rubric.json"
    manifest_path.write_bytes(manifest_bytes)

    run = tmp / "run"
    run.mkdir()
    sample = {"files": [{"path": p, "bytes": b, "sha256": s} for (p, b, s) in FILES],
              "real_files": 1, "synthetic_files": 1}
    sample_bytes = json.dumps(sample).encode()
    (run / "sample-manifest.json").write_bytes(sample_bytes)
    frozen = {"run_identity": "test", "query_manifest_sha256": _sha(manifest_bytes),
              "query_count": 2, "file_count": 2,
              "files": [{"path": p, "bytes": b, "sha256": s} for (p, b, s) in FILES],
              "sample_manifest_sha256": _sha(sample_bytes), "settings": {}}
    _write(run / "frozen-input-manifest.json", frozen)

    ocr = run / "image-ocr-v1"
    ocr.mkdir()
    _write(ocr / "arm-summary.json", {
        "arm": "image-ocr-v1", "text_extraction": "image-ocr-v1", "file_count": 2,
        "indexed_count": 2, "blank_count": 0, "total_chunks": 2,
        "per_file_chunks": [{"path": "real/x.png", "chunks": 1, "ocr_chars": 10, "is_blank": False},
                            {"path": "synthetic/y.png", "chunks": 1, "ocr_chars": 10, "is_blank": False}]})
    _write(ocr / "q01.json", _qresult("q01", "real q", "image-ocr-v1", "real/x.png",
           [_grp(1, "real/x.png", 0.9), _grp(2, "synthetic/y.png", 0.5)], 1, True))
    _write(ocr / "q02.json", _qresult("q02", "synth q", "image-ocr-v1", "synthetic/y.png",
           [_grp(1, "real/x.png", 0.8), _grp(2, "synthetic/y.png", 0.4)], 2, True))

    raw = run / "raw"
    raw.mkdir()
    _write(raw / "arm-summary.json", {"arm": "raw", "text_extraction": "raw", "file_count": 0,
           "indexed_count": 0, "blank_count": 0, "total_chunks": 0, "per_file_chunks": []})
    _write(raw / "q01.json", _qresult("q01", "real q", "raw", "real/x.png", [], None, False))
    _write(raw / "q02.json", _qresult("q02", "synth q", "raw", "synthetic/y.png", [], None, False))
    return run, manifest_path


class ScoreImageRubricTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="e12-scorer-"))
        self.run, self.manifest = build(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_valid_scores_and_target_rank(self):
        out = scorer.score(self.run, self.manifest)
        ocr = out["arms"]["image-ocr-v1"]
        # q01 rank1, q02 rank2 -> one rank1, MRR (1 + 0.5)/2 = 0.75.
        self.assertEqual(ocr["all"]["rank1"], 1)
        self.assertAlmostEqual(ocr["all"]["mrr"], 0.75, places=6)
        # Subsets: real target ranks 1, synthetic target ranks 2.
        self.assertEqual(ocr["real"]["rank1"], 1)
        self.assertAlmostEqual(ocr["real"]["mrr"], 1.0, places=6)
        self.assertEqual(ocr["synthetic"]["rank1"], 0)
        self.assertAlmostEqual(ocr["synthetic"]["mrr"], 0.5, places=6)
        # The raw baseline is empty -> everything misses.
        self.assertEqual(out["arms"]["raw"]["all"]["rank1"], 0)
        self.assertAlmostEqual(out["arms"]["raw"]["all"]["mrr"], 0.0, places=6)
        # Per-query derived rank for the synthetic target is 2.
        q02 = next(q for q in out["per_query"] if q["id"] == "q02")
        self.assertEqual(q02["ranks"]["image-ocr-v1"], 2)

    def test_missing_query_file(self):
        (self.run / "image-ocr-v1" / "q02.json").unlink()
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_invalid_group_ordering(self):
        # Break the sequential rank fields (rank 5 at array position 0).
        bad = _qresult("q01", "real q", "image-ocr-v1", "real/x.png",
                       [_grp(5, "real/x.png", 0.9), _grp(2, "synthetic/y.png", 0.5)], 1, True)
        _write(self.run / "image-ocr-v1" / "q01.json", bad)
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_scores_not_descending(self):
        # best_score ascending across the archived array is rejected.
        bad = _qresult("q01", "real q", "image-ocr-v1", "real/x.png",
                       [_grp(1, "real/x.png", 0.3), _grp(2, "synthetic/y.png", 0.9)], 2, True)
        _write(self.run / "image-ocr-v1" / "q01.json", bad)
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_stored_rank_mismatch(self):
        # Groups put real/x.png at rank 1, but file_rank claims 2.
        bad = _qresult("q01", "real q", "image-ocr-v1", "real/x.png",
                       [_grp(1, "real/x.png", 0.9), _grp(2, "synthetic/y.png", 0.5)], 2, True)
        _write(self.run / "image-ocr-v1" / "q01.json", bad)
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_sample_manifest_fingerprint_mismatch(self):
        # Corrupt the archived sample-manifest so its sha256 no longer matches.
        (self.run / "sample-manifest.json").write_text(
            (self.run / "sample-manifest.json").read_text() + " ")
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_query_manifest_fingerprint_mismatch(self):
        # Change the manifest bytes after freezing -> frozen hash disagrees.
        self.manifest.write_text(self.manifest.read_text() + " ")
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)

    def test_faked_nonempty_raw_baseline(self):
        _write(self.run / "raw" / "arm-summary.json", {
            "arm": "raw", "text_extraction": "raw", "file_count": 2, "indexed_count": 2,
            "blank_count": 0, "total_chunks": 2,
            "per_file_chunks": [{"path": "real/x.png", "chunks": 1, "ocr_chars": 10, "is_blank": False},
                                {"path": "synthetic/y.png", "chunks": 1, "ocr_chars": 10, "is_blank": False}]})
        with self.assertRaises(scorer.ScoreError):
            scorer.score(self.run, self.manifest)


if __name__ == "__main__":
    unittest.main()
