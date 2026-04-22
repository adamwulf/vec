# benchmarks/

Archived raw JSON dumps from `vec search` rubric sweeps. One
sub-directory per sweep, named `<alias>-<chunkChars>-<overlap>/`
(e.g. `bge-base-1200-240/`). Each sub-directory contains
`q01.json` … `q10.json` — one per canonical rubric query — plus
an optional `notes.md` if the run had anything unusual worth
recording alongside the data.

## Why these are checked in

Historical rubric scores need to be *rescoreable*. `data/retrieval-*.md`
tables are the narrative record of a sweep, but the JSON dumps under
this directory are the evidence — if a future change to the scoring
rule or a counter-bug reappears, we can re-run `scripts/score-rubric.py`
against the archived JSON and get the same answer the original sweep
reported (or discover it was wrong, like happened to bge-base's original
39/60 manual count on 2026-04-19).

## Producing a new archive

```bash
# 1. Reset + reindex the test DB (never cd — see CLAUDE.md):
swift run vec reset --db markdown-memory --force
swift run vec update-index --db markdown-memory --embedder <alias> \
  --chunk-chars <N> --chunk-overlap <M> --verbose

# 2. Capture all 10 rubric queries to benchmarks/<alias>-<N>-<M>/:
mkdir -p benchmarks/<alias>-<N>-<M>
for n in 01 02 03 04 05 06 07 08 09 10; do
  # Query texts come from scripts/rubric-queries.json (the canonical list).
  swift run vec search --db markdown-memory --format json --limit 20 \
    "$(jq -r ".queries[$((10#${n}-1))].text" scripts/rubric-queries.json)" \
    > "benchmarks/<alias>-<N>-<M>/q${n}.json"
done

# 3. Score:
python3 scripts/score-rubric.py benchmarks/<alias>-<N>-<M>/

# 4. Paste the script's output verbatim into data/retrieval-<alias>.md,
#    commit the benchmarks/ subdir with the results-log entry.
```

`scripts/score-rubric.py` reads the rubric from
`scripts/rubric-queries.json` and is the single source of truth for
the scoring algorithm. If the script's output ever disagrees with a
human count, the script is right — that's the whole point of
checking it in.
