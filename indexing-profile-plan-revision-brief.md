# IndexingProfile plan — revision brief (round 2)

Two plan reviewers returned CHANGES NEEDED on `indexing-profile-plan.md`.
Both agreed the core design is sound; the issues are fixable ambiguities.
All three UX decisions below have been locked by the user — bake them in,
do not re-open them.

## User decisions (NON-NEGOTIABLE)

1. **Partial chunk overrides → HARD-FAIL.** If the user passes only one
   of `--chunk-chars` / `--chunk-overlap` without the other, the command
   must fail with a specific error. No inheritance from alias-default.
   No inheritance from recorded profile. Either both flags are present
   or neither.

   This REPLACES the partial-override rule at plan lines 456–462 and
   the "chunk params" mention at line 596. Both must be rewritten.

2. **Missing-profile error → TWO distinct error variants.**
   - `profileNotRecorded` — fresh/reset DB (`profile == nil` AND
     `chunkCount == 0`). Remedy message: "run `vec update-index`".
   - `preProfileDatabase` — DB has chunks but no profile key
     (`profile == nil` AND `chunkCount > 0`). Remedy message: "run
     `vec reset` first, then `vec update-index`".

   Plan lines 591–593 currently conflate these under a single
   `profileNotRecorded` name. Split the enum; match on chunk count.

3. **Identity parsing → STRICT regex + round-trip check.**
   Grammar: `^[a-z0-9-]+@[1-9][0-9]*/[0-9]+$`. Reject leading zeros,
   whitespace, uppercase. After parsing, re-render the identity from
   the parsed components and assert string equality with the input.
   Mismatch → throw `malformedProfileIdentity`.

4. **No backward-compat nuance anywhere.** Any DB with the wrong
   format — missing `profile` key with chunks present, unknown alias,
   malformed identity, pre-refactor `embedder` shape — hard-fails and
   the user reindexes. No shims, no migrations, no "try to interpret."

## Reviewer blockers to resolve

### From Reviewer A (architecture)

- **Descriptor/materialize split** (plan §"The profile struct" around
  lines 88–150 and the factory section). Reviewer A argued for a
  `ProfileDescriptor` value type (alias + chunk size + overlap, no live
  embedder instance) that materializes into a full `IndexingProfile`
  on demand. OR justify keeping the merged struct. Pick one and write
  the rationale in the plan. A merged struct is fine if: (a) the live
  embedder is cheap to construct (it already is — the actor lookup is
  a shared instance) and (b) tests don't need to inspect identity
  without instantiating an embedder.

- **`ProfileMismatchTests` suite.** Add an explicit test suite name to
  the ship-criteria list (§10). Should cover: recorded nomic → request
  nl fails; recorded nomic@1200/240 → request nomic@500/100 fails;
  recorded nomic → request nomic with no override succeeds; pre-profile
  DB with chunks → `preProfileDatabase`; fresh DB → `profileNotRecorded`.

- **Phase 3 budget.** Currently 3–4h. Reviewer A flagged low. Bump to
  5–6h to account for: two new error variants, strict parser, partial-
  override rejection path, five-case mismatch test matrix. Update the
  phase header and any budget tables.

### From Reviewer B (correctness)

- **Self-contradiction on partial overrides.** RESOLVED by decision 1
  above. Update lines 456–462 and 596 to state the hard-fail rule.
  Grep the whole plan for any other partial-override language — there
  may be echoes in the Design/Ordering sections.

- **Error steer for pre-profile DBs with chunks.** RESOLVED by
  decision 2. Update plan §"Ordering of checks inside each command"
  (lines 582–614) and the error-enum section to split
  `profileNotRecorded` → `profileNotRecorded` + `preProfileDatabase`.

- **Lenient identity parsing breaks round-trip.** RESOLVED by
  decision 3. Update the parsing section to specify the strict regex
  and the round-trip check. Add `malformedProfileIdentity` to the
  error enum.

## Open questions (answer inline in the revised plan)

The reviewers flagged these as needing explicit answers:

1. How does `vec info` render a custom-profile identity vs. a built-in?
   (Suggest: "Profile: nomic@500/100 (custom, based on nomic)" vs.
   "Profile: nomic@1200/240 (768d)". Decide and document.)
2. `ProfileRecord` equality — is it identity-string equality, or
   structural equality across (alias, size, overlap)? Pick one; note
   that the strict-round-trip invariant from decision 3 means they're
   equivalent, so the simpler identity-string comparison is fine.
3. Config write ordering when the CLI produces a custom (non-alias-
   default) identity: write `ProfileRecord` BEFORE the pipeline touches
   the DB? (Plan §"Ordering of checks" step 6 says yes — make sure the
   ordering is explicit for both alias-default and custom-identity
   cases.)
4. `vec list` — does it print the profile identity per DB? (Probably
   yes; one-line addition to the command.)
5. `alias(forCanonicalName:)` post-refactor — who still calls it? If
   no callers, delete it. If only the factory itself calls it, inline
   it.
6. `isBuiltIn` — what checks this, and what does the answer affect?
   Likely needed for the `vec info` rendering above. Keep if used;
   delete if not.

## What NOT to change

- The overall phase structure (Phase 1 design/struct, Phase 2 factory,
  Phase 3 command wiring, Phase 4 review, Phase 5 bean-test).
- The ship-criteria list's existing items — only ADD the
  `ProfileMismatchTests` suite entry.
- The scope boundary: still no `--splitter` flag, still no migration,
  still hard-fail on pre-refactor DBs.
- The two bean-test targets (NL ≈6/60, nomic ≈35/60).

## How to deliver

Edit `indexing-profile-plan.md` in place. Do not fork a new file. When
done, `git commit` with message
`indexing-profile-plan: round-2 revisions` and signal completion with
a one-line summary via `ib send agent-c54ba5da "Plan revision complete"`.
