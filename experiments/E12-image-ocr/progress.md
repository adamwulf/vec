# E12 handoff — 2026-09-07

Manager: `image-ocr`, branch `agent/image-ocr`. Work only in this worktree. Use single-command tool calls and `ib`; never access main/other worktree paths. Rebase onto main if main advances; never merge main or squash. Coordinator's latest instruction: **do not merge anything**. Final line when idle: `WAITING`; when the whole goal is done: `I HAVE COMPLETED THE GOAL`.

## Latest measured milestones

Runner commits: `69dec5c` frozen18 throughput; `9db38f7` real153 throughput; `79716ce` TH1 fault injection. Real153 cold jobs 1/4/8: 6.8535/10.3401/11.2697 images/s; 325k extrapolation 13.17/8.73/8.01 hours. Cold peak RSS 251871232/280248320/287948800 bytes (240.20/267.27/274.61 MiB). Frozen18 cold 0.68/0.80/0.69 images/s implies roughly 133/112/131 hours. All actual passes had zero failures; warm passes hit every sidecar without OCR. TH1 injected one invalid PNG and verified partial failure JSON written before expected exit1, with no valid full throughput archive. Original lost-run failure was not reproduced; no causal claim.

Runner is rebasing/running full suite then writing report.md and E12 plan. Manager requested force-adding actual execution logs (global log ignore may omit them), exact hardware model/RAM, and correcting generated memory labels from MB to MiB without altering raw byte/timing data. Both reviewers have been sent regenerated retrieval and throughput SHAs; final artifacts/report approval pending. Real153 is a modest stride sample, so 8-13h is conditional, not an established full-corpus prediction. Warm timing lasts only milliseconds and RSS has 1-2 samples; do not sell warm extrapolation as reliable.

## Current state

- Main last checked at `664b3e8`; manager implementation/frozen-harness tip before this note is `105cbab`. Engine: `172764f`, `f1652ba`, integrated at `1bf450d`; shared image classification `77b328e`; pinned Vision request revision 3 `4ed96d8`; bounded OCR pipeline `638a1db`; review fixes `a78cf0b`.
- Frozen sample/harness recovered linearly: `4a6fd90` → `61780f5` → `ce870d9`. This tree is identical to former integration commit `4c88e08`. `105cbab` labels lost-run figures provisional in root plan.
- Implemented eight canonical extraction modes; opt-in scanner and direct-extractor image gating; insert/update persistence/cache routing; ImageIO first-frame/orientation/4096 cap; accurate Vision with language correction and auto detection; content hash/version sidecars, bounded LRU, single-flight/coalescing diagnostics; bounded image concurrency (default 1) alongside serial text extraction. No metadata schema change. SVG/HEIF skipped; AVIF advertised on this Mac.
- Native focused suite passed 131 tests at `638a1db`. New `a78cf0b` tests add LRU eviction and guaranteed concurrent cache wait coverage plus latch timeout. Final full suite must include these and the E12 harness.
- README describes behavior, formats, cache, per-job memory and downscale/retry caveats. Root plan has an in-progress E12 entry. Both must be finalized with actual results; experiment `report.md` is still missing on manager branch.

## Single active runner

`agent-f8aa66db`, branch `agent/agent-f8aa66db`, owns `Tests/VecKitTests/ImageOCRBenchmarkTests.swift` and `experiments/E12-image-ocr/`. Correct native worktree/tools confirmed. It must write `report.md` from its measured archives; manager reviews, not rewrites from guesses.

- `f8850a4`: fixes Swift warnings; persists per-pass failures before throwing (TH1). Failed passes are invalid for 325k extrapolation.
- `49b2ae8`: checked-in `scripts/run-benchmark.swift` uses Foundation Process environment + `xcrun swift test`, because env-prefixed shell commands are denied. Invocation begins with `swift`; 1800-second timeout, log/exit status captured. No permission setting changes or downloads.
- **Regenerated retrieval archive committed `9d39893`**, path `experiments/E12-image-ocr/runs/20260907-retrieval`. Measured at clean `49b2ae8`, local E5 revision `f52bf8ec8c7124536f0efb74aca902b2995e5bcd`, e5-base@1200/0, macOS 26.6.2 (25G83), Swift 6.2.4, 10 cores. Independent scorer agrees: raw empty, 0/15; OCR hit@1 14/15, hit@5 15/15, MRR .9667; real 3/4 (MRR .875), synthetic 11/11. Exactly 18 completion records = 17 nonblank + 1 blank, 19 chunks, cache hits 0/misses 18/OCR calls 18. q04 real Minecraft thumbnail ranks 2; labels unchanged.
- Runner is now measuring 1/4/8 OCR jobs on frozen18, then deterministic stride-selected **153 real images** (every seventh sorted file from 1071, fixed hashes/provenance). It must commit each archive immediately, then rebase onto manager before full suite and write report/experiment plan. No simultaneous benchmarks/tests that distort timing.

## Reviewers

Read-only reviewers `agent-7f25b85a` (correctness) and `agent-b48d8418` (concurrency/memory/tests) approved implementation + integrated frozen harness after fixes. All round-1 findings resolved: LRU coverage, concurrency memory guidance, stale comment, latch timeout, deterministic single-flight test, honest DB-error test scope. TH1 diagnostic retention is being reviewed in runner's `f8850a4`.

Both have just been sent `9d39893` and are independently rescoring the new archive (Python only while throughput runs). Final approval still needs actual throughput archives, report links/claims, final assembled build/test evidence. Send them final runner SHA/report when ready; fix findings, commit, repeat until **both approve without unresolved issues**. Retire all reviewers/workers after preserving all results; verify with `ib list` before completing.

## Remaining checklist

1. Obtain committed throughput rates for 1/4/8, 325k time estimates, memory scope/behavior, cache counts, actual failure diagnostics if any. Do not infer the old throughput failure cause.
2. Runner runs final native full suite on current implementation and commits logs, `report.md`, updated E12 plan. Report synthetic/selection/empty-baseline/order/RSS caveats plainly.
3. Review and preserve runner commits without violating coordinator's no-merge instruction. Finalize README/root plan with measured results and completed status.
4. Both reviewers independently verify regenerated archive (scorer + self-tests), throughput arithmetic/provenance, report and final changes. Record approvals, fix every finding, repeat as needed.
5. Check main advancement, rebase if required, preserve individual commits. Finish all agent lifecycle cleanup. Send `ib send @system` milestone with SHA/numbers. Final user summary: hit@1/hit@5/MRR/chunks, rates at 1/4/8, 325k estimates, tests/review, synthetic caveat; final line `I HAVE COMPLETED THE GOAL`.

## Recovery caution

Old worker `agent-271da479` was deleted by coordinator after a failed respawn. Its **uncommitted first retrieval archive and warning edits were lost**; never cite that missing archive as verified. Frozen committed inputs were recovered and new `9d39893` is the authoritative measured evidence. Fresh runner is the only runner. Do not restart sessions casually; commit outputs first. If tool access fails, report via `ib send @system` or visible final; do not spend an hour silently waiting.
