#!/usr/bin/env python3
"""Score vec search results against the bean-counter rubric.

Reads 10 JSON result arrays (one per query) from <results_dir>/q{1..10}.json,
scores each, and prints a markdown summary table.

Handles build-noise prefix lines before the JSON array (swift run vec with
2>&1 merged).
"""
import json
import sys
from pathlib import Path

TRANSCRIPT = "granola/2026-02-26-22-30-164bf8dc/transcript.txt"
SUMMARY = "granola/2026-02-26-22-30-164bf8dc/summary.md"

QUERIES = [
    "trademark price negotiation",
    "where did I negotiate the price for the trademark",
    "muse trademark pricing discussion",
    "counter offer for trademark assets",
    "how much did we ask for the trademark",
    "trademark assignment agreement meeting",
    "right of first refusal trademark",
    "bean counter mode trademark",
    "1.5 million trademark deal",
    "trademark deal move quickly quick execution",
]

def score_rank(rank):
    if rank is None:
        return 0
    if rank <= 3:
        return 3
    if rank <= 10:
        return 2
    if rank <= 20:
        return 1
    return 0

def find_rank(results, target):
    for i, r in enumerate(results):
        if r.get("file") == target:
            return i + 1
    return None

def load_json_from_mixed(path):
    """Strip lines before the first '[' then parse JSON."""
    text = path.read_text()
    idx = text.find('[')
    if idx < 0:
        raise ValueError("no '[' in file")
    return json.loads(text[idx:])

def main():
    results_dir = Path(sys.argv[1])
    total = 0
    queries_hit_top10_either = 0
    queries_hit_top10_both = 0
    rows = []
    for i, q in enumerate(QUERIES, 1):
        path = results_dir / f"q{i}.json"
        try:
            data = load_json_from_mixed(path)
        except Exception as e:
            rows.append(f"| {i} | {q[:50]} | ERROR: {e} | - | - | - | - |")
            continue
        t_rank = find_rank(data, TRANSCRIPT)
        s_rank = find_rank(data, SUMMARY)
        t_score = score_rank(t_rank)
        s_score = score_rank(s_rank)
        subtotal = t_score + s_score
        total += subtotal
        if (t_rank and t_rank <= 10) or (s_rank and s_rank <= 10):
            queries_hit_top10_either += 1
        if (t_rank and t_rank <= 10) and (s_rank and s_rank <= 10):
            queries_hit_top10_both += 1
        t_rank_str = str(t_rank) if t_rank else "-"
        s_rank_str = str(s_rank) if s_rank else "-"
        rows.append(f"| {i} | {q[:50]} | {t_rank_str} | {s_rank_str} | {t_score} | {s_score} | {subtotal} |")

    print("| # | query | T rank | S rank | T score | S score | subtotal |")
    print("|---|-------|--------|--------|---------|---------|----------|")
    for r in rows:
        print(r)
    print(f"\nTOTAL: {total}/60, TOP10_EITHER: {queries_hit_top10_either}/10, TOP10_BOTH: {queries_hit_top10_both}/10")

if __name__ == "__main__":
    main()
