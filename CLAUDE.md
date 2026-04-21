# Repository layout

`vec` is a Swift CLI for local vector databases. Source lives under
`Sources/` and `Tests/`; everything else at the root or under the
top-level doc folders is documentation about the project.

## READ FIRST: Running `vec` commands — DO NOT `cd`

**You almost never need to change directories to run `vec`. Pass
`--db <name>` and stay where you are.** Every `vec` DB lives at
`~/.vec/<name>/` with its source directory recorded in `config.json`.
The CLI resolves both from `--db` alone.

This trips up new agents repeatedly. The rule is simple:

- `vec init <name>` — the ONLY subcommand that reads the current
  working directory (it records cwd as the new DB's source dir). If a
  DB you want to use is already initialized, you do NOT need to run
  `init` again, and you do NOT need to `cd` anywhere.

- **Every other subcommand** — `update-index`, `search`, `insert`,
  `remove`, `info`, `reset`, `deinit`, `list`, `chunk` — works from
  any working directory. Just pass `--db <name>`.

### Concrete examples

From your worktree root, `/tmp`, or anywhere else:

```bash
# Reindex the existing markdown-memory corpus with a new embedder:
swift run vec reset --db markdown-memory --force
swift run vec update-index --db markdown-memory --embedder bge-small

# Score a rubric query:
swift run vec search --db markdown-memory --format json --limit 20 "trademark price negotiation"

# Inspect an existing DB:
swift run vec info --db markdown-memory
swift run vec list
```

No `cd` involved in any of the above. The `markdown-memory` DB is
already initialized against Adam's corpus at
`/Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`
— `reset` preserves that source path, so a reset+reindex against an
existing DB is the canonical way to run a fresh rubric sweep with a
different embedder.

### When you really do need a brand-new DB

If you need a new throwaway DB name (not a clone/reset of an existing
one), `vec init <name>` is the only step that needs cwd. In an
ittybitty worktree where the path-isolation hook blocks external `cd`,
delegate that one step to a worker sub-agent — but prefer `reset` on
an existing DB whenever possible. Resets are cheaper than inits for
the typical "try a new embedder against the same corpus" workflow.

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

