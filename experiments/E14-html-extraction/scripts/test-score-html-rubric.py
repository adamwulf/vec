#!/usr/bin/env python3
"""Regression tests for the strict E14 archive scorer."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCORER = ROOT / "scripts" / "score-html-rubric.py"
QUERY_PATH = ROOT / "queries" / "rubric-queries.json"
SAMPLE_PATH = ROOT / "sample" / "manifest.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HTMLRubricScorerTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="e14-scorer-"))
        self.manifest = json.loads(QUERY_PATH.read_text())
        provenance = {
            "run_identity": "unit-test-run",
            "git_head": "0123456789abcdef",
            "git_dirty": False,
            "package_resolved_sha256": "package-hash",
            "query_manifest_sha256": digest(QUERY_PATH),
            "sample_manifest_sha256": digest(SAMPLE_PATH),
            "settings": {"profile_identity": "fixture"},
            "model_files": [{"path": "fixture.bin", "sha256": "model-hash"}],
        }
        (self.directory / "frozen-input-manifest.json").write_text(
            json.dumps(provenance)
        )
        files = [item["path"] for item in json.loads(SAMPLE_PATH.read_text())["files"]]
        for arm in self.manifest["arms"]:
            arm_dir = self.directory / arm["key"]
            arm_dir.mkdir()
            for query in self.manifest["queries"]:
                primary = query.get("primary_file")
                ordered = ([primary] + [path for path in files if path != primary]
                           if primary else files)
                groups = [
                    {
                        "rank": index + 1,
                        "file": path,
                        "best_score": 1.0 - index * 0.05,
                        "matches": [{"score": 1.0 - index * 0.05,
                                     "distance": index * 0.05}],
                    }
                    for index, path in enumerate(ordered)
                ]
                primary_text = " ".join(
                    item["value"] for item in query.get("passage_criteria", [])
                )
                result = {
                    "groups": groups,
                    "file_rank": 1 if primary else None,
                    "primary_text": primary_text,
                }
                (arm_dir / f"{query['id']}.json").write_text(json.dumps(result))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def run_scorer(self):
        return subprocess.run(
            ["python3", str(SCORER), str(self.directory)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_complete_archiveScores(self):
        result = self.run_scorer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("raw", result.stdout)
        self.assertIn("html-v1", result.stdout)
        self.assertIn("No-answer probes", result.stdout)

    def test_missingResultIsRejected(self):
        (self.directory / "raw" / "q01.json").unlink()
        result = self.run_scorer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("result set mismatch", result.stderr)

    def testStoredRankDisagreementIsRejected(self):
        path = self.directory / "html-v1" / "q02.json"
        payload = json.loads(path.read_text())
        payload["file_rank"] = 2
        path.write_text(json.dumps(payload))
        result = self.run_scorer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match derived rank", result.stderr)

    def testProvenanceDriftIsRejected(self):
        path = self.directory / "frozen-input-manifest.json"
        payload = json.loads(path.read_text())
        payload["sample_manifest_sha256"] = "stale"
        path.write_text(json.dumps(payload))
        result = self.run_scorer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match committed input", result.stderr)

    def testNonFiniteScoreIsRejected(self):
        path = self.directory / "raw" / "q03.json"
        payload = json.loads(path.read_text())
        payload["groups"][0]["best_score"] = float("nan")
        path.write_text(json.dumps(payload))
        result = self.run_scorer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("non-finite best_score", result.stderr)


if __name__ == "__main__":
    unittest.main()
