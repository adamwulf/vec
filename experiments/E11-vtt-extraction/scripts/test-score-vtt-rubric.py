import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("score_vtt", Path(__file__).with_name("score-vtt-rubric.py"))
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


class ScorerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        original = scorer.EXPERIMENT
        scorer.EXPERIMENT = self.root
        self.addCleanup(setattr, scorer, "EXPERIMENT", original)
        self.run = self.root / "run"
        manifest = {"arms": [{"key": a, "text_extraction": a} for a in ["raw", "vtt-v1"]],
                    "queries": [{"id": "q01", "text": "Find the spoken claim", "primary_file": "a.vtt"}]}
        self.write(self.root / "queries/rubric-queries.json", manifest)
        digest = hashlib.sha256((self.root / "queries/rubric-queries.json").read_bytes()).hexdigest()
        self.write(self.run / "frozen-input-manifest.json", {"query_manifest_sha256": digest,
            "query_count": 1, "files": [{"path": p} for p in ["a.vtt", "b.vtt"]],
            "file_count": 2, "run_identity": "test-run", "settings": {}})
        for arm in ["raw", "vtt-v1"]:
            noisy = int(arm == "raw")
            per_file = [{"path": p, "chunks": 2, "noise_stats": self.noise(2, 1, noisy)}
                        for p in ["a.vtt", "b.vtt"]]
            self.write(self.run / arm / "arm-summary.json", {"arm": arm, "text_extraction": arm,
                "file_count": 2, "indexed_count": 2, "total_chunks": 4,
                "per_file_chunks": per_file, "noise_stats": self.noise(4, 2, noisy * 2)})
            ordered = ["b.vtt", "a.vtt"] if arm == "raw" else ["a.vtt", "b.vtt"]
            self.write(self.run / arm / "q01.json", {"id": "q01", "text": "Find the spoken claim",
                "arm": arm, "primary_file": "a.vtt", "file_rank": ordered.index("a.vtt") + 1,
                "groups": [{"file": p, "rank": i + 1, "best_score": 0.9 - i * 0.1, "matches": []}
                           for i, p in enumerate(ordered)]})

    @staticmethod
    def noise(all_count, passage_count, count):
        return {scope: {"chunk_count": total, "timestamp_chunks": count,
                        "inline_tag_chunks": count, "noisy_chunks": count, "noisy_share": count / total}
                for scope, total in [("all_chunks", all_count), ("passage_chunks", passage_count)]}

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def mutate(self, relative, edit):
        path = self.run / relative
        value = json.loads(path.read_text())
        edit(value)
        self.write(path, value)

    def testDerivesRanksAndSeparatesNoiseDenominators(self):
        result = scorer.score(self.run)
        self.assertEqual(result["arms"]["raw"]["mrr"], 0.5)
        self.assertEqual(result["arms"]["vtt-v1"]["hit_at_1"], 1)
        self.assertEqual(result["arms"]["raw"]["noise_stats"]["all_chunks"]["noisy_share"], 0.5)
        self.assertEqual(result["arms"]["raw"]["noise_stats"]["passage_chunks"]["noisy_share"], 1)

    def testRejectsIncompleteArchive(self):
        (self.run / "vtt-v1/q01.json").unlink()
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsWrongQueryContent(self):
        self.mutate("raw/q01.json", lambda x: x.update(text="A different question"))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsFabricatedStoredRank(self):
        self.mutate("raw/q01.json", lambda x: x.update(file_rank=1))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsChangedFrozenQueryHash(self):
        self.mutate("frozen-input-manifest.json", lambda x: x.update(query_manifest_sha256="changed"))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsNoiseUnionDoubleCounting(self):
        self.mutate("raw/arm-summary.json", lambda x: x["noise_stats"]["all_chunks"].update(noisy_chunks=5))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsWrongNoiseDenominator(self):
        self.mutate("raw/arm-summary.json", lambda x: x["noise_stats"]["all_chunks"].update(noisy_share=1))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)

    def testRejectsPartialIndex(self):
        self.mutate("raw/arm-summary.json", lambda x: x.update(indexed_count=1))
        with self.assertRaises(scorer.e10.ScoreError):
            scorer.score(self.run)


if __name__ == "__main__":
    unittest.main()
