# Repository layout

`vec` is a Swift CLI for local vector databases. Source lives under
`Sources/` and `Tests/`; everything else at the root or under the
top-level doc folders is documentation about the project.

## Where docs live

- **[`README.md`](./README.md)** — user-facing docs for the CLI.
- **[`plan.md`](./plan.md)** — the rolling project plan. Covers what
  has shipped, what's in progress, and what's next. Start here when
  picking up work.
- **[`indexing-profile.md`](./indexing-profile.md)** — reference for
  the `<alias>@<size>/<overlap>` profile grammar and how it's stamped
  onto a DB.
- **[`retrieval-rubric.md`](./retrieval-rubric.md)** — the canonical
  10-query scoring rule used to evaluate retrieval quality. Don't
  modify; new experiments score against it.

- **[`data/`](./data/)** — raw experiment outputs (per-embedder
  retrieval sweeps, wallclock comparisons). One file per experiment
  or sweep. Named `retrieval-<alias>.md` for rubric sweeps and
  `<metric>-<experiment>-*.md` for other measurements.

- **[`research/`](./research/)** — external material collected from
  the web, fully cited. Surveys and background research, not project
  decisions.

- **[`experiments/`](./experiments/)** — one directory per experiment,
  named `E<n>-<slug>` or `Phase<X>-<slug>`. Each contains:
  - `plan.md` — the plan as written before/during execution.
  - `report.md` (when present) — lessons learned and what happened.
  - `commits.md` (when present) — commit SHAs and sweep-result tables.

- **[`archived/`](./archived/)** — superseded snapshots in dated
  folders (`YYYY-MM/`). Frozen; do not edit. New archives get a new
  dated folder.

## Writing new docs

- **New experiment**: create `experiments/E<n>-<slug>/plan.md`. Add a
  "Done" entry in `plan.md` when it ships, with links to the plan /
  report / commits.
- **New sweep data**: add a file under `data/`. Reference it from the
  owning experiment's `plan.md`.
- **New external research**: add a cited file under `research/`.
  Reference it from whichever experiment consumed it.
- **Plan changes**: edit `plan.md` directly — it's the single
  source of truth for past, present, and future.
- **Superseded doc**: move to `archived/YYYY-MM/` (current month).
  Don't edit once archived.

## Running the CLI against a named DB

`vec` databases live under `~/.vec/<name>/` and each one has a
`config.json` stamped with the absolute path of its source directory.
Because of this split, only ONE command cares about your current
working directory — the rest resolve everything from `--db <name>`.

- **`vec init <name>`** — the ONLY command that uses
  `FileManager.default.currentDirectoryPath`. It records cwd as the
  DB's source directory. Run this once from inside the corpus you
  want to index; after that, cwd no longer matters for that DB.

- **Every other command** (`update-index`, `search`, `insert`,
  `remove`, `info`, `reset`, `deinit`, `list`, `chunk`) — pass
  `--db <name>` and the command resolves both the DB directory and
  the source directory from the recorded config. Run from anywhere
  — your own worktree, `/tmp`, the project root, whatever.

### Running rubric sweeps

The existing `markdown-memory` DB is already initialized against
Adam's corpus at
`/Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`.
For a fresh per-embedder sweep you need a throwaway DB name (so you
don't clobber the working index) — that one `init` call must cd into
the corpus, but every subsequent `update-index` / `search` stays in
whatever cwd you're already in. Within an ittybitty worktree where
the path-isolation hook blocks `cd` into external paths, delegate
the one-shot `init` to a worker sub-agent; the manager can run the
rest from its own worktree via `--db`.
