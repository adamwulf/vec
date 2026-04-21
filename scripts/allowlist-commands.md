# Commands to allowlist for rubric-sweep agents

Claude Code (and ittybitty worker agents) block anything not on the
Bash allowlist with a `Tool not in allow list` / `hook-check-path`
error. The commands below are the ones an agent needs to run a
rubric sweep end-to-end. Each one is listed in the exact form it
will appear in a Bash call so you can paste it verbatim into the
settings.

## Required

**The rubric scorer:**

```
python3 scripts/score-rubric.py:*
```

Invoked as `python3 scripts/score-rubric.py benchmarks/<alias>-<N>-<M>/`.
Pinning the allowlist entry to this exact command path (not just
`python3:*`) keeps Python in the loop for *this* specific,
reviewed, checked-in scorer and nothing else — agents can't pivot
to ad-hoc Python at runtime (which is how the bge-small worker
originally went off the rails, trying to hand-write DB bootstrap
code). Without this allowlist entry, the only fallback is reading
ranks out of JSON by eye, which has already produced one drifted
score (bge-base's original 39/60 was off by 3 points).

**`jq` for parsing the query manifest:**

```
jq:*
```

The query loop in `retrieval-rubric.md` §"Capture the 10-query JSON"
uses `jq` to extract each query's text from
`scripts/rubric-queries.json`. Allowing any `jq` invocation covers
both the manifest extraction and general JSON poking during
investigation.

## Already allowed (reference)

These are already on the allowlist for Bash — noted here so agents
know they don't need special permission:

- `swift run vec *` — the CLI itself
- `swift build`, `swift test` — package build/test
- `git *` — standard git operations
- `mkdir -p benchmarks/*` — creating archive subdirectories

## Why not `python3:*`?

Broad `python3:*` would allow any Python script including ones
written ad-hoc at runtime (which is exactly how the bge-small
worker went off the rails — it started considering writing Python
to manually bootstrap a DB). Pinning the allowlist entry to
`python3 scripts/score-rubric.py` keeps Python in the loop for
*this* specific, reviewed, checked-in scorer and nothing else. If
a future experiment needs a different committed script, add a
specific entry for it rather than opening the door to arbitrary
Python.

## Diagnosing allowlist blocks

Symptoms:
- `Tool not in allow list` on a command you expected to work
- `ib hook-check-path agent-XXXX` in the error output
- The command contained an absolute path, a subshell, or a Python/jq
  invocation

Fix:
- If the blocked command is one of the above, add the specific
  entry.
- If it was a `cd` into an external path, the command was wrong —
  see CLAUDE.md's "DO NOT cd" section. Every `vec` subcommand
  except `init` works from any cwd via `--db`.
