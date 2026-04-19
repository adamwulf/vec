# IndexingProfile plan — round-3 revision brief

Round-2 review flagged two issues. Both reviewers (C and D) caught the
same root contradiction independently; C also caught a bug in the
`isBuiltIn` computation.

## User decision (LOCKED)

**Bare `vec update-index` with NO flags uses alias-defaults for the
current best embedder (nomic@1200/240), NOT the recorded profile's
chunk params.** On a recorded custom-chunk DB (e.g. `nomic@500/100`),
bare `update-index` resolves to `nomic@1200/240` → mismatches →
hard-fails. User must retype `--chunk-chars 500 --chunk-overlap 100`
or run `vec reset`. Strict no-inheritance rule holds everywhere.

Rationale (user's direct words): "we should use our current best
default embedder and parameters, which i believe currently is nomic".
So bare `update-index` always reaches for the current best default.
If that drifts (say the default alias changes from `nomic` to
`nomic-v2`), older DBs on the old default also hard-fail — by design.

## Fix 1 — bare-update-index inheritance language (both reviewers)

Current plan has three sections that disagree:

- §CLI surface (around lines 542–545): example claims bare
  `vec update-index` "proceeds to index new/changed files under the
  same profile" on a recorded DB.
- §Ordering of checks, update-index step 4 (around lines 732–742):
  chunks "default to the alias-default chunk params (NOT the recorded
  chunk params)".
- §Alias resolution when --embedder is omitted (around lines 588–594):
  ambiguous — says chunk half "follows the hard-fail rule (both or
  neither)" but doesn't specify what "neither" means.

Make all three agree on path B:

- §CLI surface: update the `vec update-index` example to show that on a
  recorded custom-chunk DB, bare `update-index` hard-fails with
  `profileMismatch`. Add a short line saying "To re-index under the
  recorded profile, retype the same flags. Or `vec reset` first if you
  want to switch."
- §Ordering step 4: keep the "default to alias-default chunk params"
  wording. Make it explicit: "This means bare `vec update-index` on a
  recorded custom-chunk DB will hard-fail. Design choice: we always
  reach for the current best default, not the recorded one."
- §Alias resolution: clarify that "neither chunk flag" → alias-default
  chunk params, which is the strict rule. Only the alias itself falls
  back to recorded when `--embedder` is omitted.

Ship criterion #4: add a clarifying sentence that "neither chunk flag
present" uses alias-defaults, and that this can mismatch a recorded
custom-chunk profile.

## Fix 2 — `isBuiltIn` computation (reviewer C)

Current factory:

```swift
// Wrong: isBuiltIn = false whenever the caller passed non-nil chunks.
let isBuiltIn = (chunkSize == nil && chunkOverlap == nil)
```

Problem: `resolve(identity: "nomic@1200/240")` calls `make(alias:
"nomic", chunkSize: 1200, chunkOverlap: 240)` → `isBuiltIn == false`.
So a persisted alias-default profile renders as
`(custom, based on nomic)` in `vec info`, contradicting Open Q1's
answer. The round-2 test at line 869 that asserts
`resolve("nomic@1200/240") == make(alias: "nomic")` would also fail
on the `isBuiltIn` field.

Correct computation:

```swift
let effectiveSize = chunkSize ?? entry.defaultChunkSize
let effectiveOverlap = chunkOverlap ?? entry.defaultChunkOverlap
let isBuiltIn = (effectiveSize == entry.defaultChunkSize
              && effectiveOverlap == entry.defaultChunkOverlap)
```

Update the factory pseudo-code in the plan, and update the test
expectation at line 869 if it needs restating.

## What NOT to change

- The three locked decisions from round 2 (hard-fail partial chunk
  overrides, two distinct missing-profile errors, strict regex +
  round-trip identity parse).
- The phase structure.
- Bean-test gates.
- Ship-criteria items other than §4 clarification.
- Any text not related to the two fixes above.

## Deliverable

Edit `indexing-profile-plan.md` in place. Commit with message
`indexing-profile-plan: round-3 revisions`. Signal via
`ib send agent-c54ba5da "Plan revision r3 complete"`.

## Success

After your edits, these three statements must all hold simultaneously:

1. `vec update-index` (no flags) on recorded `nomic@500/100`
   hard-fails with `profileMismatch` (recorded `nomic@500/100`,
   requested `nomic@1200/240`).
2. `vec update-index` (no flags) on recorded `nomic@1200/240` succeeds
   (both are alias-default → match).
3. `vec info` on recorded `nomic@1200/240` renders `Profile:
   nomic@1200/240 (768d)` (no "custom" suffix, because `isBuiltIn` is
   true when effective chunk params equal alias-defaults).

Grep your revised plan for `inherit`, `fall back`, `falls back`, `same
profile`, `same flags` — read each hit and confirm it's consistent with
strict no-inheritance and the three statements above.
