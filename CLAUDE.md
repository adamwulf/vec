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
