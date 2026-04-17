# Nomic Embedder Migration — Implementation Plan

> **Audience:** a fresh implementation worker who has read `bean-test.md`,
> `bean-test-results.md`, `embedder-research.md` (esp. §3.4, §3.13, §4),
> and this file. The worker should follow the steps in order and tick the
> final checklist as they go.
>
> **Goal:** rip out `NLEmbedding` and replace with `nomic-embed-text-v1.5`
> via [`swift-embeddings`](https://github.com/jkrukowski/swift-embeddings)
> (jkrukowski, MIT, SPM). Then run a parameter sweep against the
> bean-test corpus to find the chunk config that scores highest on the
> 10-query rubric.
>
> **Pre-approved constraints** (do NOT re-debate, even if they look
> wasteful):
> - macOS deployment target must be bumped from `.macOS(.v13)` to
>   `.macOS(.v15)`. swift-embeddings' package manifest declares
>   `.macOS(.v14)`, but the specific APIs we use (`ModelBundle`,
>   `encode`, `loadModelBundle`) are all gated `@available(macOS 15.0,
>   *)` — so our consumer package must target `.v15` to call them
>   without `if #available` guards.
> - Back-compat is OFF. No `--embedder` flag. No protocol with two
>   impls. No DB metadata guard. No `NLEmbedding` fallback path.
> - 768 dims always. No Matryoshka truncation. Update
>   `VectorDatabase`'s default and every test that hardcodes 512.
> - Existing DBs are wiped and reindexed.
> - Integration substrate: `swift-embeddings` only. Not llama.cpp. Not
>   manual CoreML.
> - All CLI invocations use `swift run vec <cmd>`. Never
>   `.build/debug/vec`.
> - Scoring command: `swift run vec search --db markdown-memory
>   --format json --limit 20 "<query>"`.

---

## 0. Quick orientation

Touch points (pre-existing, will be modified):

- `Package.swift` — bump platform, add dep.
- `Sources/VecKit/EmbeddingService.swift` — full rewrite.
- `Sources/VecKit/IndexingPipeline.swift` — `EmbedderPool.init` (line
  ~645), `EmbedderPool.warmAll()` (line ~671), embed call site (line
  ~360). Pool size + sync-to-async propagation.
- `Sources/vec/Commands/SearchCommand.swift` — query-side embed call
  (line ~60). Sync→async + `embedQuery(...)` rename.
- `Sources/VecKit/VectorDatabase.swift` — `dimension: Int = 512`
  default at line 59. Change to 768.
- `Sources/VecKit/TextExtractor.swift` — uses
  `EmbeddingService.maxEmbeddingTextLength` at lines 69 and 116. Either
  drop the gate or rename to a nomic-specific constant.
- `Tests/VecKitTests/VecKitTests.swift` — lines 36–71 (`EmbeddingServiceTests`)
  and lines 239, 319, 371 (which reference `maxEmbeddingTextLength`).
- `Tests/VecKitTests/NLEmbeddingThreadSafetyTests.swift` — rewrite as
  a mandatory `NomicEmbedder` concurrency canary (see §3.8, §4.0).
- `Tests/VecKitTests/IntegrationTests.swift` and
  `Tests/VecKitTests/VectorDatabaseTests.swift` — also build
  `EmbeddingService()` (lines ~25). Will need async-ification.

---

## 1. Pre-flight checks

Run these commands in order. **Halt and signal manager** if any of the
stop conditions fire.

### 1.1 curl works

```sh
curl --version
```

Expect: `curl 7.x` or `8.x` printed and exit code 0.

### 1.2 Hugging Face is reachable

```sh
curl -sI https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/main/config.json
```

Expect: an HTTP response — either `HTTP/2 200` directly, or a `HTTP/2
302` redirect to a CDN URL. Both are fine. A network error
("Could not resolve host", connection timeout, etc.) is the failure
signal.

### 1.3 Report exact file sizes that swift-embeddings will pull

`swift-embeddings`'s `NomicBert.loadModelBundle(from: "nomic-ai/nomic-embed-text-v1.5")`
downloads files via `swift-transformers`' `Hub.snapshot`. The
implementer must report the byte sizes of the following files BEFORE
the experiment starts (paste the raw `Content-Length` headers into the
results log).

```sh
for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json vocab.txt model.safetensors modules.json sentence_bert_config.json 1_Pooling/config.json; do
  echo "=== $f ==="
  curl -sIL "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/main/$f" | grep -i '^content-length\|^HTTP/'
done
```

(Each command runs as a separate Bash tool call — no piping/chaining
across calls. `for ... do ... done` is one shell command, which is
allowed.)

If a file 404s, that is OK — it just means swift-embeddings doesn't
need it. Record the sizes that exist.

Cross-check totals against the HF siblings API:

```sh
curl -s https://huggingface.co/api/models/nomic-ai/nomic-embed-text-v1.5/tree/main
```

This returns a JSON list; sum the `size` fields for `.json`, `.txt`,
and `model.safetensors`.

**Expected dominant file:** `model.safetensors` ≈ ~525 MiB (137M params
× 4 bytes for fp32) — but the actual size is what
`Content-Length` returns; record that, do not assume.

### 1.4 Hugging Face cache path

`swift-transformers`' `HubApi` defaults `downloadBase` to the user's
Documents directory:

```
~/Documents/huggingface/models/nomic-ai/nomic-embed-text-v1.5/
```

Verify after first run by listing that directory. The implementer
should record this path in `nomic-experiment-results.md` so the
weights can be located, copied, or wiped manually.

### 1.5 STOP CONDITIONS for this section

Halt and `ib send agent-e7013d1a "[STUCK] pre-flight: <reason>"` if:

- `curl` is missing or non-functional.
- `huggingface.co` is unreachable from this machine.
- The total of all files swift-embeddings will pull (per §1.3) **exceeds
  1 GB**.

Otherwise: record the per-file sizes + total + cache path in
`nomic-experiment-results.md` and proceed to §2.

---

## 2. Package.swift changes

### 2.1 Read the upstream Package.swift first

`swift-embeddings`'s own `Package.swift` (verified at the time of this
plan) declares:

- `// swift-tools-version: 6.0`
- `platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)]`

So our package must:
1. Bump `platforms` to `.macOS(.v15)`. Note: swift-embeddings' package
   manifest declares `.macOS(.v14)` at the PACKAGE level, but the
   specific APIs we use (`NomicBert.ModelBundle`, `encode`,
   `loadModelBundle`) are all gated `@available(macOS 15.0, *)`
   (verified in NomicBertModel.swift and NomicBertUtils.swift). A
   consumer package set to `.v14` would only be able to call these
   APIs behind `if #available(macOS 15, *)` guards. Targeting `.v15`
   directly avoids that churn.
2. Stay at `swift-tools-version` `5.9` or higher (we're already at
   `5.9`; that's fine — only `swift-embeddings` itself needs `6.0`).

### 2.2 Pick the version tag

The latest released tag at the time of this plan is **`0.0.26`** (Feb
2026). Use `from: "0.0.26"` to allow patch/minor updates within the
0.0.x series. If `swift package resolve` fails because that tag has
been retracted, fall back to `from: "0.0.20"` and document.

### 2.3 Diff for `Package.swift`

```diff
 // swift-tools-version: 5.9
 import PackageDescription

 let package = Package(
     name: "vec",
     platforms: [
-        .macOS(.v13)
+        .macOS(.v15)
     ],
     products: [
         .library(name: "VecKit", targets: ["VecKit"]),
         .executable(name: "vec", targets: ["vec"])
     ],
     dependencies: [
-        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
+        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
+        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.0.26")
     ],
     targets: [
         .systemLibrary(
             name: "CSQLiteVec",
             pkgConfig: "sqlite3",
             providers: [
                 .brew(["sqlite"])
             ]
         ),
         .target(
             name: "VecKit",
             dependencies: [
-                "CSQLiteVec"
+                "CSQLiteVec",
+                .product(name: "Embeddings", package: "swift-embeddings")
             ]
         ),
```

Library product name from `swift-embeddings` is **`Embeddings`** (its
`MLTensorUtils` is a separate optional product we don't need).

### 2.4 Sanity check

```sh
swift package resolve
```

```sh
swift build
```

Both should complete without errors. If `swift build` errors with
something like "no such module 'Embeddings'", confirm the product name
in the upstream Package.swift hasn't drifted — then HALT and signal
manager.

If `swift package resolve` complains about `argument-parser` or
`swift-numerics` version conflicts, accept the higher minimum that
swift-embeddings requires. If that bumps argument-parser past 1.3, just
update our `from:` to match.

---

## 3. Code changes — file by file

For each file: path, line range, before/after sketch, rationale.

### 3.1 `Sources/VecKit/EmbeddingService.swift` — full rewrite

**Lines:** entire file (47 lines).

**Rationale:** NLEmbedding is gone. Replace with a concurrency-safe
async wrapper around `NomicBert.ModelBundle` that exposes
`embedDocument` and `embedQuery` with the required nomic prefixes.

**Sketch (NOT a complete impl — just the shape):**

```swift
import Foundation
import Embeddings  // from swift-embeddings

/// Wraps swift-embeddings' NomicBert model for nomic-embed-text-v1.5.
///
/// The model is loaded lazily on first use (network download on first
/// run, cached at ~/Documents/huggingface/models/nomic-ai/...
/// thereafter). All embeddings are 768-dim Float32.
///
/// Nomic was trained with mandatory prefixes:
///   - "search_document: "  for indexed text
///   - "search_query: "     for queries
/// Forgetting them measurably degrades retrieval — both methods add
/// the prefix internally so callers must use the right method, not
/// the right string.
public actor EmbeddingService {

    public static let dimension = 768

    /// Maximum input length in characters before we truncate. Nomic's
    /// tokenizer max is 8192 tokens (~32 KB chars in English). Pick a
    /// generous char cap that stays safely under that — pre-tokenization
    /// truncation just keeps the encoder from blowing up on unbounded
    /// text. Tunable.
    public static let maxInputCharacters = 30_000

    private var bundle: NomicBert.ModelBundle?

    public init() {}

    /// Embed a document chunk for indexing.
    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_document: ", text: text)
    }

    /// Embed a query at search time.
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_query: ", text: text)
    }

    private func embed(prefix: String, text: String) async throws -> [Float] {
        let bundle = try await loadBundleIfNeeded()
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }   // caller treats empty as failure
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }
        let input = prefix + trimmed
        // `postProcess` defaults to `nil`, which returns the raw
        // per-token tensor with shape [1, seqLen, 768]. That is NOT
        // what we want. nomic-embed-text-v1.5 is trained with
        // mean-pool + L2 normalize per its HF sentence-transformers
        // config, so we must pass `.meanPoolAndNormalize` explicitly
        // to get a 768-dim sentence vector.
        let tensor = try bundle.encode(input, postProcess: .meanPoolAndNormalize)  // sync, throws -> MLTensor
        // Convert MLTensor → [Float]. Per swift-embeddings README:
        //   await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        // With `.meanPoolAndNormalize` the returned tensor has shape
        // [1, 768] and `scalars.count` must be 768. Still worth a
        // shape-sanity-check on the first warmup call and HALT if
        // surprising.
        return scalars
    }

    private func loadBundleIfNeeded() async throws -> NomicBert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await NomicBert.loadModelBundle(
            from: "nomic-ai/nomic-embed-text-v1.5"
        )
        self.bundle = loaded
        return loaded
    }
}
```

**Important shape facts** (verified against
swift-embeddings 0.0.26 source):

- `NomicBert.loadModelBundle(from:)` is **async throws**, returns
  `NomicBert.ModelBundle`.
- `ModelBundle.encode(_:maxLength:postProcess:computePolicy:)` is
  **sync throws -> MLTensor**.
- `MLTensor → [Float]` conversion is async (`await tensor.cast(...).shapedArray(...)`).
- Pooling is **not** done internally by default. `encode()` calls
  `processResult(result, with: postProcess)`, and with `postProcess ==
  nil` (the default) that method returns the raw per-token tensor
  UNCHANGED (shape `[1, seqLen, 768]`) — there is no CLS-pooling case
  in the upstream source. The only post-process options are `nil`
  (pass-through), `.meanPool`, and `.meanPoolAndNormalize`. Nomic's
  recommended pooling is `.meanPoolAndNormalize` (mean-pool + L2
  normalize), so that is what we MUST pass. **Verify shape on the
  first warmup call**: with `.meanPoolAndNormalize` the tensor is
  `[1, 768]` and `scalars.count` must equal 768. If it does not, HALT
  — do not silently work around it.

**Why an `actor` and not `final class`?** With NLEmbedding we needed N
copies because the underlying C++ runtime crashed under concurrent
calls. swift-embeddings' MLTensor backend is documented as not
thread-safe for shared encode calls (no documented guarantees in the
README), so a single instance must serialize calls. An `actor`
provides that for free, and lets us collapse the pool to one
shared instance — saving ~9× the model weight memory at typical
worker counts.

### 3.2 `Sources/VecKit/IndexingPipeline.swift` — pool + async propagation

**(a) `EmbedderPool` (lines 638–676)** — collapse to a single shared instance.

Current shape: actor with `available: [EmbeddingService]`,
`acquire()`/`release()`, `warmAll()`. Rationale was to work around
NLEmbedding's thread unsafety with N copies.

**New shape:** still an actor (interface preserved so callers don't
need restructuring), but holds **one** `EmbeddingService` actor.
`acquire()` returns the same instance every time; `release()` is a
no-op. The `EmbeddingService` actor itself serializes embed calls.

**Sketch:**

```swift
actor EmbedderPool {
    private let embedder: EmbeddingService

    init(count: Int) {
        // count is ignored — kept on the signature so IndexingPipeline.init
        // doesn't need to change. swift-embeddings' MLTensor backend has
        // no documented thread-safety guarantee, so a single shared
        // instance with serialized access (the EmbeddingService actor)
        // is the safe default. If we observe segfaults / data races
        // under concurrent load, raise pool size to N here and document
        // why.
        //
        // CRITICAL: raising workerCount above 1 multiplies model-weight
        // RAM by N. nomic-embed-text-v1.5 is ~525 MiB per instance. At
        // workerCount=10 that is ~5.25 GiB of resident weights alone,
        // before any activation buffers. Before ever raising pool size,
        // verify process RSS in Activity Monitor / `ps -o rss=` at
        // whatever candidate N, and confirm total RAM headroom. Do not
        // raise blindly to match NLEmbedding's historical pool=10.
        _ = count
        self.embedder = EmbeddingService()
    }

    func acquire() async -> EmbeddingService { embedder }

    func release(_ embedder: EmbeddingService) { /* no-op */ }

    func warmAll() async {
        // Force-load the model + run one inference so the first real
        // chunk doesn't pay cold-start cost.
        do {
            _ = try await embedder.embedDocument("warmup")
        } catch {
            // swallow — warmup failure surfaces on the first real embed
        }
    }
}
```

**Pool size note:** start with effective pool=1. If profiling shows
serialized embed calls cap throughput far below expectations AND
thread-safety verification (run `embedder.embedDocument` from N tasks
concurrently in a quick canary test) shows no crashes, raise to N. But
do that as a follow-up — it's not required to score the experiment.

**(b) Embed task body (line 360)** — change the synchronous embed
call to await the async API.

Before:
```swift
let vector = embedder.embed(chunk.text)
```

After:
```swift
let vector: [Float]?
do {
    let v = try await embedder.embedDocument(chunk.text)
    vector = v.isEmpty ? nil : v
} catch {
    vector = nil
}
```

Rationale: pipeline already `await`s `pool.acquire()` from inside an
async task, so adding another `await` here is free. `embedDocument`
throws on model-load failure (unlike NLEmbedding's nil return), so
catch & treat as a per-chunk failure to preserve existing
"`.skippedEmbedFailure`" semantics.

**(c) `IndexingPipeline.init` (lines 174–179)** — no changes
required. Pool count parameter is harmless even though the pool
ignores it.

**(d) `EmbedderPool` doc comments (lines 636–640, 667–670)** —
update to reflect single-shared-instance design.

### 3.3 `Sources/vec/Commands/SearchCommand.swift` — query-side call

**Lines:** 60–64.

Before:
```swift
let embedder = EmbeddingService()
guard let queryEmbedding = embedder.embed(query) else {
    print("Error: Failed to generate embedding for query.")
    throw ExitCode.failure
}
```

After:
```swift
let embedder = EmbeddingService()
let queryEmbedding: [Float]
do {
    queryEmbedding = try await embedder.embedQuery(query)
} catch {
    print("Error: Failed to generate embedding for query: \(error)")
    throw ExitCode.failure
}
guard !queryEmbedding.isEmpty else {
    print("Error: Empty embedding for query.")
    throw ExitCode.failure
}
```

Rationale: `run()` is already `async`, so `await` is free. Use
`embedQuery` (not `embedDocument`) to apply the right nomic prefix.

### 3.4 `Sources/VecKit/VectorDatabase.swift` — dimension default

**Line 59.**

Before:
```swift
public init(databaseDirectory: URL, sourceDirectory: URL, dimension: Int = 512) {
```

After:
```swift
public init(databaseDirectory: URL, sourceDirectory: URL, dimension: Int = 768) {
```

Also update the doc comment on line 58:
```swift
///   - dimension: The embedding vector dimension (default 768).
```

**Grep verification:** `grep -n 512 Sources/VecKit/VectorDatabase.swift`
should return only lines 58 and 59 (the comment + the default
parameter). The schema stores embeddings as raw BLOBs with no
dimension constraint (verified at lines 583–595, the chunks-table
DDL), so no schema migration is needed — just wipe + reindex.

### 3.5 `Sources/VecKit/TextExtractor.swift` — drop the NL char cap

**Lines 69 and 116.**

Both reference `EmbeddingService.maxEmbeddingTextLength`. That
constant doesn't exist post-rewrite. Two options:

**Preferred:** rename the new constant on `EmbeddingService` (per the
sketch in §3.1, `EmbeddingService.maxInputCharacters`) and point
TextExtractor at it:

```diff
-        if trimmed.count <= EmbeddingService.maxEmbeddingTextLength {
+        if trimmed.count <= EmbeddingService.maxInputCharacters {
             chunks.append(TextChunk(text: trimmed, type: .whole))
         }
```

(Same diff at line 116 for the PDF path.)

Rationale: the gate is preserved (a "whole" chunk is suppressed for
documents larger than the embedder can handle). Nomic's real cap is
8192 tokens (~32 KB chars), so `maxInputCharacters = 30_000` raises
the gate ~3× from the old 10 KB. That's intentional — it lets more
documents get a `.whole` embedding, which the bean-test results show
matters for short summary files.

### 3.6 Tests — `Tests/VecKitTests/VecKitTests.swift`

**Lines 36–71** — `EmbeddingServiceTests` rewrite.

The current tests assume sync `embed(_:) -> [Float]?`, dimension 512,
`maxEmbeddingTextLength` = 10 000. Replace with async tests against
the new API:

```swift
final class EmbeddingServiceTests: XCTestCase {

    func testEmbedDocumentReturnsArrayOfDimension768() async throws {
        let service = EmbeddingService()
        let result = try await service.embedDocument("hello world")
        XCTAssertEqual(result.count, 768)
    }

    func testEmbedQueryReturnsArrayOfDimension768() async throws {
        let service = EmbeddingService()
        let result = try await service.embedQuery("hello world")
        XCTAssertEqual(result.count, 768)
    }

    func testEmbedEmptyStringReturnsEmpty() async throws {
        let service = EmbeddingService()
        let result = try await service.embedDocument("")
        XCTAssertEqual(result.count, 0)
    }

    func testEmbedWhitespaceOnlyReturnsEmpty() async throws {
        let service = EmbeddingService()
        XCTAssertEqual(try await service.embedDocument("   ").count, 0)
        XCTAssertEqual(try await service.embedDocument("\n\n").count, 0)
    }

    func testEmbedVeryLongTextDoesNotCrashAndReturns768() async throws {
        let service = EmbeddingService()
        let longText = String(repeating: "The quick brown fox. ", count: 5000)
        XCTAssertGreaterThan(longText.count, EmbeddingService.maxInputCharacters)
        let result = try await service.embedDocument(longText)
        XCTAssertEqual(result.count, 768)
    }

    func testDimensionIs768() {
        XCTAssertEqual(EmbeddingService.dimension, 768)
    }
}
```

Rename the test method `testEmbedHelloWorldReturnsNonNilArrayOfDimension512`
→ `testEmbedDocumentReturnsArrayOfDimension768`. Drop
`testDimensionIs512` and replace with `testDimensionIs768`. Note
`dimension` is now a `static let` (the actor instance cannot expose
sync stored properties without a hop — make it static so callers can
read it without await).

**Lines 239, 319, 371** — references to
`EmbeddingService.maxEmbeddingTextLength` from `TextExtractorTests`.
Rename to `EmbeddingService.maxInputCharacters`. Tests still pass
because the new cap is 30 000 (so the Moby Dick PDF fixture and
oversized-line tests still trigger the size gate).

### 3.7 Tests — `Tests/VecKitTests/IntegrationTests.swift` and `Tests/VecKitTests/VectorDatabaseTests.swift`

Both files build `EmbeddingService()` at line ~25 and then call
`embeddingService.embed(...)` in a helper. The implementer must:

- Convert helpers from sync to async, propagate `async throws`
  through any caller that uses them.
- Replace `embeddingService.embed(text)` with
  `try await embeddingService.embedDocument(text)` (these are
  building index entries, so document prefix is correct).
- Replace any "expect 512-dim" assertions with 768.

Run the affected tests after the changes to confirm.

### 3.8 Rewrite `Tests/VecKitTests/NLEmbeddingThreadSafetyTests.swift` into a nomic concurrency canary

**Decision: rewrite, do not just delete.** The §4.0 smoke-test step
requires a mandatory concurrency canary — this file is the natural
home. Rewrite it as `NomicEmbedderConcurrencyTests` that fires 20
concurrent `try await embedder.embedDocument("warmup test \(i)")`
calls against a single shared `EmbeddingService` actor and asserts
every call returns an array of length 768.

The original NLEmbedding canary existed for that engine's specific
C++ runtime bug. No analogous bug is documented for swift-embeddings
(its MLTensor backend has no documented thread-safety guarantee
either way), so a standing canary against the actor-serialized path
is the right defensive posture.

Rename the test type and drop the old NLEmbedding-specific asserts;
keep the file path so git treats this as a modification, not a
delete+add.

### 3.9 Remove leftover `import NaturalLanguage`

```sh
grep -rn "import NaturalLanguage" Sources/ Tests/
```

Expect: hits only in `IndexingPipeline.swift` (line 2 — used for
`NLLanguageRecognizer` to detect non-English content; KEEP that
import) and any file that's been deleted/rewritten (drop those).
EmbeddingService.swift loses its `import NaturalLanguage`.

### 3.10 Test gate — must be green before §4

Before proceeding to the smoke test in §4:

```sh
swift test
```

Must exit 0. Red tests block §4 entirely. If a test legitimately
depends on a first-run network download, guard it with `XCTSkipIf`
(skip when offline) rather than letting it fail — a silently failing
test teaches the project to ignore red. Do NOT commit any sweep
iteration while any test is red.

---

## 4. Smoke test before reindexing

Before kicking off the full sweep, prove the new pipeline doesn't
crash and produces 768-dim vectors. First run `swift test` — all
tests must pass (see §3.x / §8). Then run the concurrency canary
(§4.0), then the indexing smoke (§4.1).

### 4.0 MANDATORY concurrency canary

The 3-file smoke corpus in §4.1 will not exercise concurrent embed
calls against a single shared actor, but `IndexingPipeline` fans out
via `TaskGroup` and the real reindex WILL hit that path. Run this
canary BEFORE the indexing smoke and BEFORE the full reindex.

Add a small XCTest (or a one-shot script) that does:

```swift
let service = EmbeddingService()
try await withThrowingTaskGroup(of: [Float].self) { group in
    for i in 0..<20 {
        group.addTask { try await service.embedDocument("warmup test \(i)") }
    }
    var count = 0
    for try await vec in group {
        XCTAssertEqual(vec.count, 768)
        count += 1
    }
    XCTAssertEqual(count, 20)
}
```

**Pass condition:** all 20 tasks complete and return arrays of length
768.

**Fail action:** HALT. Do NOT attempt to raise pool size above 1 to
work around it — that is a false fix. Signal manager with the failure
mode (crash, hang, wrong length).

### 4.1 Indexing smoke

The implementer creates a small temp directory with three files,
indexes it into a throwaway DB, and inspects the JSON.

```sh
mkdir -p /tmp/vec-smoke
```

```sh
printf 'This is a test about cats.\n' > /tmp/vec-smoke/cats.md
```

```sh
printf 'Trademark negotiation discussion.\n' > /tmp/vec-smoke/trademark.md
```

```sh
printf 'Bean counter mode for quick execution.\n' > /tmp/vec-smoke/beans.md
```

```sh
swift run vec reset --db smoke-test --force
```

```sh
cd /tmp/vec-smoke && swift run --package-path /Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/agent-222ac098/repo vec update-index --db smoke-test
```

```sh
swift run vec search --db smoke-test --format json --limit 5 "trademark"
```

**Pass conditions:**

- `update-index` finishes without crash, reports 3 added.
- The JSON output of `search` is a non-empty array.
- The implementer manually inspects one chunk's embedding (via a quick
  `sqlite3 ~/.vec/smoke-test/index.db "SELECT length(embedding) FROM chunks LIMIT 1"`):
  expect `768 * 4 = 3072` bytes per row.
- **Memory guardrail:** after the first warmup embed, record the
  process RSS (e.g. `ps -o rss= -p <pid>` — RSS is printed in KiB).
  Expect < 1.5 GiB. If > 3 GiB, HALT and investigate (something is
  holding multiple model copies or leaking).

**Fail action:** halt and signal manager. Do NOT proceed to §5.

---

## 5. Parameter-sweep protocol

Once the smoke test passes, run the parameter sweep against the
bean-test corpus.

### 5.1 Configurations to test (in order)

Run them in this sequence so the implementer can early-stop on a clear
winner. Mix recursive char-based and line-based splitters.

| # | Splitter | chunk-chars / chunk-overlap | rationale |
|---|----------|-----------------------------|-----------|
| 1 | recursive | 2000 / 200 | baseline — direct A/B vs NLEmbedding 6/60 |
| 2 | recursive | 1200 / 240 | mid — Iter 7's NLEmbedding worst, may differ |
| 3 | recursive | 800 / 160 | small-medium |
| 4 | recursive | 500 / 100 | small |
| 5 | recursive | 2500 / 250 | larger-mid |
| 6 | recursive | 300 / 60 | very small |
| 7 | recursive | 400 / 80 | re-test of NLEmbedding's 3/60 corner |
| 8 | recursive | 1500 / 300 | mid-larger |
| 9 | recursive | 3000 / 300 | larger — pushes whole-doc gate |
| 10 | LineBased | 30 lines / 8 overlap | LineBasedSplitter default |
| 11 | LineBased | 50 lines / 10 overlap | LineBasedSplitter wider |

**Note on time:** nomic-embed-text-v1.5 at 768 dims is **substantially
slower** than NLEmbedding at 512 dims. NLEmbedding's bean-test reindex
ran in ~minutes; nomic may take 5–15× as long depending on hardware
and pool size (which is now 1).

### 5.2 Time-it-first protocol

**Always reindex configuration #1 (2000/200) first** and record
wall-clock from the verbose output. That's the baseline cost. Multiply
by ~1.5× as a rough upper bound for smaller chunk configs (more
chunks = more embed calls). If the projected total of all 11 configs
exceeds the 12-hour budget (§7), prioritize:

1. config #1 (#1 baseline)
2. config #4 or #6 (small chunks — most likely to lift transcript)
3. config #10 (LineBasedSplitter)
4. config #5 or #9 (large — most likely to lift summary)
5. … remaining configs in any order until budget exhausted.

**Hard abort gate — after iteration #1 completes:** compute
`projected_total = iter1_wall_clock × 11 × 1.2` (the 1.2 is a safety
factor for per-config variance). If `projected_total > 10 h` (leaving
at least 2 h reserve within the 12 h §7 budget for scoring, commits,
and any stuck-recovery), immediately drop to a minimum-viable sweep:
pick 4 configs spanning the axes (e.g. one small + one medium + one
large chunk config + one LineBased). Commit the decision — including
the exact triggering wall-clock number from iteration #1 and the
chosen 4 configs — to `nomic-experiment-results.md` before proceeding.
This gate is not optional.

### 5.3 Per-iteration recipe

For each config in §5.1:

```sh
swift run vec reset --db markdown-memory --force
```

For configs #1–#9 (recursive):
```sh
cd /Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory && swift run --package-path /Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/agent-222ac098/repo vec update-index --db markdown-memory --chunk-chars <N> --chunk-overlap <M> --verbose
```

For configs #10–#11 (LineBased): the implementer must add a
`--splitter line|recursive` flag to `UpdateIndexCommand.swift` (or
temporarily hardcode `LineBasedSplitter(chunkSize: 30, overlapSize:
8)` in `run()`). This is a separate small code change. Document it
inline in the iteration log.

**Per-iteration dim sanity check:** after each reindex, confirm every
stored embedding is the expected size:

```sh
sqlite3 ~/.vec/markdown-memory/index.db "SELECT DISTINCT length(embedding) FROM chunks;"
```

Expect a single row containing `3072` (= 768 × 4 bytes). Any other
value — multiple distinct lengths, or a different byte count — means
pooling or dimensionality drifted; HALT and signal manager before
scoring.

### 5.4 Scoring

Score each config against the same 10 queries from `bean-test.md`.
Run each query and parse the JSON for the two target files:

- `granola/2026-02-26-22-30-164bf8dc/transcript.txt` (T)
- `granola/2026-02-26-22-30-164bf8dc/summary.md` (S)

Per query: rank 1–3 → +3, rank 4–10 → +2, rank 11–20 → +1, absent → 0
(scored independently for T and S).

Use exactly:
```sh
swift run vec search --db markdown-memory --format json --limit 20 "<query>"
```

Either parse the JSON in the worker shell directly with `jq` filters,
or spawn a sub-agent for the scoring (recommended — keeps the
manager's context clean):

```
ib new-agent --worker "Run these 10 search queries... [paste full
prompt from bean-test.md §Iteration protocol]"
```

### 5.5 Logging — `nomic-experiment-results.md`

After each iteration, append a row to `nomic-experiment-results.md`
(create on first iteration). Same format as `bean-test-results.md`:

```
| # | timestamp | config | total | top10 | notes |
| 1 | 2026-04-17 | recursive 2000/200 | 12/60 | 1/10 | baseline nomic |
```

Plus the per-query block underneath:

```
### Iteration 1 — recursive 2000/200, nomic-embed-text-v1.5 768 dims
| # | query | T rank | S rank | T score | S score | subtotal |
| 1 | trademark price negotiation | 4 | 8 | 2 | 2 | 4 |
...
TOTAL: X/60, QUERIES_HIT_TOP10: N/10
```

### 5.6 Parallelism — be explicit

- **Reindexing in parallel: NOT SAFE.** Two `swift run vec
  update-index` instances against the same DB will both try to lock
  `index.db`. Even against different DBs they share the `swift run`
  build state and will serialize on the lock anyway. Run reindexes
  **strictly serially**.
- **Scoring in parallel: SAFE for read-only `vec search` against an
  already-built DB.** `vec search` opens SQLite read-only effectively
  (it only does SELECTs). Spawning N scoring workers against the same
  DB after a reindex is fine.
- The implementer can pipeline: reindex config #N, kick off scoring
  worker for config #N, simultaneously start reindex of config #N+1.
  Just don't reindex two configs at once.

### 5.7 Commit per iteration

After each iteration logs to `nomic-experiment-results.md`:

```sh
git add nomic-experiment-results.md
```

```sh
git commit -m "nomic-experiment iter N: <config>, <score>/60"
```

Rationale: 12-hour wall-clock budget is long enough that an OS reboot,
container restart, or accidental kill could lose work. Commit-per-
iteration is cheap.

---

## 6. Stop conditions for the whole experiment

These come straight from the pre-approved constraints. Wire them into
the iteration loop.

### 6.1 SHIP gate

**Trigger:** ANY single config scores ≥ 45/60 AND both target files
hit top 10 on ≥ 7/10 queries.

**Action:**
1. STOP further iterations immediately.
2. Make the winning config the new default in
   `Sources/vec/Commands/UpdateIndexCommand.swift` (update
   `RecursiveCharacterSplitter.defaultChunkSize` /
   `defaultChunkOverlap` if recursive wins, or change the `splitter:`
   construction if LineBasedSplitter wins).
3. Commit the change with a message citing the score.
4. Write the final summary section in `nomic-experiment-results.md`.
5. Signal manager: `ib send agent-e7013d1a "SHIP gate hit:
   <config> <score>/60 <top10>/10"`.

### 6.2 KILL gate

**Trigger:** ALL tested configs score < 15/60.

**Action:**
1. STOP.
2. Do NOT commit any code change to defaults.
3. Document in `nomic-experiment-results.md` that nomic-embed-text-v1.5
   is not the answer for this corpus and write the trajectory.
4. Signal manager: `ib send agent-e7013d1a "KILL gate hit: best
   <score>/60 — nomic ineffective on this corpus"`.

### 6.3 TIME budget

12 hours of wall-clock spent on the parameter sweep. Iterations within
that window are unlimited.

If 12 hours elapse without ship/kill: STOP, commit best-config
defaults if best score ≥ 30/60 ("interesting" — better than NLEmbedding
6/60 baseline), document either way, signal manager.

### 6.4 Trend-aware exploration

Iterations are **unlimited within the 12h budget**. If the first 3–4
configs reveal a clear trend (e.g., small chunks beating large ones),
explore densely around it — add intermediate configs not in §5.1's
fixed list. Document any added configs with rationale.

### 6.5 Unrecoverable blocker

Any of:

- HF unreachable mid-experiment (and weights aren't already cached).
- swift-embeddings crashes deterministically.
- macOS/Swift toolchain incompatibility surfaces.
- Out-of-memory or out-of-disk during reindex.

→ STOP, document in `nomic-experiment-results.md`, signal manager:
`ib send agent-e7013d1a "[STUCK] <reason>"`. Do NOT delete the
worktree or revert work.

**Per-category retry/don't-retry policy:**

- **HF unreachable:** first, verify weights aren't already cached —
  `ls ~/Documents/huggingface/models/nomic-ai/nomic-embed-text-v1.5/`.
  If the weights are present, a network failure is not a blocker; the
  HubApi loader uses the cache. If not cached: retry 3× with 30 s
  backoff between attempts, then STUCK.
- **swift-embeddings crash:** if deterministic (same config, same
  input, same error on clean rebuild), do NOT retry — STUCK
  immediately. If transient, retry **once** after `swift package
  clean && swift build`, then STUCK if it recurs.
- **macOS / Swift toolchain incompatibility:** do NOT auto-bump the
  toolchain or deployment target beyond §2's plan. STUCK immediately
  — this is a decision for the manager.
- **OOM or out-of-disk during reindex:** do NOT attempt automated
  freeing (no `rm -rf`, no forced cache purges). Report the numbers
  (free RAM, free disk, process RSS) in the STUCK message and wait.

---

## 7. Time budget summary

- Phase 5 parameter sweep: **12 hours wall-clock**, unlimited
  iterations within that.
- Per-iteration: ~1 reindex + 10 scoring queries. With pool=1 nomic,
  expect roughly 10–60 minutes per iteration depending on chunk size
  (more chunks → longer).
- Commit after every iteration (§5.7).

---

## 8. Final checklist (tick as you go)

### Pre-flight
- [ ] curl works (§1.1)
- [ ] HF reachable (§1.2)
- [ ] File sizes recorded in `nomic-experiment-results.md` (§1.3)
- [ ] Total download ≤ 1 GB (§1.5)
- [ ] HF cache path documented (§1.4)

### Package
- [ ] `Package.swift`: bumped to `.macOS(.v15)`, added
      `swift-embeddings` dep at `from: "0.0.26"`, `Embeddings`
      product wired into `VecKit` target (§2.3)
- [ ] `swift package resolve` clean (§2.4)
- [ ] `swift build` clean (§2.4)

### Code
- [ ] `EmbeddingService.swift` rewritten (actor, async,
      `embedDocument`/`embedQuery`, 768-dim constant) (§3.1)
- [ ] `IndexingPipeline.swift`: `EmbedderPool` collapsed to single
      shared instance; `warmAll` updated; embed call site awaits
      `embedDocument` (§3.2)
- [ ] `SearchCommand.swift`: awaits `embedQuery` (§3.3)
- [ ] `VectorDatabase.swift`: dimension default 768 (§3.4)
- [ ] `TextExtractor.swift`: char gates point at
      `EmbeddingService.maxInputCharacters` (§3.5)
- [ ] `VecKitTests.swift`: `EmbeddingServiceTests` rewritten,
      512→768, `maxEmbeddingTextLength`→`maxInputCharacters` (§3.6)
- [ ] `IntegrationTests.swift` + `VectorDatabaseTests.swift`
      embed-helpers async-ified (§3.7)
- [ ] `NLEmbeddingThreadSafetyTests.swift` rewritten as
      `NomicEmbedderConcurrencyTests` — 20 concurrent
      `embedDocument` calls against a single shared actor, each
      asserting length 768 (§3.8, mandatory per §4.0)
- [ ] `import NaturalLanguage` removed from non-pipeline files (§3.9)
- [ ] `swift test` exits 0. If a test genuinely needs a network fetch
      (first-run model download), guard it with `XCTSkipIf` or mark it
      `@available` — do NOT leave it failing silently. Do not commit
      any sweep iteration while tests are red.
- [ ] Commit all §2–§3 code changes as a single atomic commit
      (`nomic migration: rip out NLEmbedding`) BEFORE starting the
      §5 sweep. The sweep appends per-iteration commits on top; the
      migration itself should be one reviewable diff.

### Smoke test
- [ ] 3-file index built into `smoke-test` DB without crash (§4)
- [ ] Search returns non-empty JSON
- [ ] Inspected blob length = 3072 bytes (768 floats × 4 bytes)

### Sweep
- [ ] Iteration 1 (recursive 2000/200) wall-clock recorded
- [ ] Total projected sweep time within 12 h budget (§5.2)
- [ ] Each iteration: reset → reindex → score → log → commit
- [ ] Stop condition hit (ship / kill / time) (§6)

### Wrap-up
- [ ] `nomic-experiment-results.md` has trajectory + final summary
- [ ] If ship gate: default updated in `UpdateIndexCommand.swift`
- [ ] Manager signaled

---

## Appendix A — known facts about swift-embeddings 0.0.26

These come from inspecting the upstream source at the time of writing.
If the implementer finds drift, document and adapt.

- Package product: `Embeddings` (the library to depend on; a separate
  `MLTensorUtils` product exists but isn't needed).
- Min platform (package manifest): `.macOS(.v14)`, `.iOS(.v17)`,
  `.visionOS(.v1)`. **BUT** the specific symbols we call
  (`NomicBert.ModelBundle`, `loadModelBundle`, `encode`) are annotated
  `@available(macOS 15.0, *)` in NomicBertModel.swift and
  NomicBertUtils.swift. Our consumer package therefore must declare
  `.macOS(.v15)` — `.v14` would require `if #available` guards at
  every call site.
- `NomicBert.loadModelBundle(from hubRepoId: String, downloadBase:
  URL? = nil, useBackgroundSession: Bool = false, loadConfig:
  LoadConfig = LoadConfig()) async throws -> NomicBert.ModelBundle`.
- `NomicBert.ModelBundle.encode(_ text: String, maxLength: Int =
  2048, postProcess: PostProcess? = nil, computePolicy: MLComputePolicy
  = .cpuAndGPU) throws -> MLTensor`. **Sync.** No `await` needed on
  the encode call itself. **Default `postProcess` is `nil`, which
  performs no pooling and returns the raw per-token tensor (shape
  `[1, seqLen, 768]`). We MUST pass `.meanPoolAndNormalize` to get a
  768-dim sentence vector — see §3.1.**
- `MLTensor → [Float]`: `await tensor.cast(to: Float.self).shapedArray(of:
  Float.self).scalars`. Async (cast/shapedArray hop the MLTensor
  context).
- HF cache path (default `downloadBase`):
  `~/Documents/huggingface/models/<repo-id>/`. swift-transformers'
  `HubApi` sets this in its initializer.

## Appendix B — files NOT to touch

These exist and are tempting to "fix" but are out of scope for this
plan:

- Anything in `Sources/VecKit/RecursiveCharacterSplitter.swift` or
  `LineBasedSplitter.swift`. The splitters work as-is; chunk
  configuration is the variable, not the splitter implementation.
- `optimization-plan.md`, `chunking-research.md`,
  `pipeline-plan.md`, `plan.md`, `large-file-memory-issue.md` —
  historical record, not the current spec. Don't delete or rewrite.
- `bean-test.md` and `bean-test-results.md` — frozen reference. The
  10 queries and rubric must not change. Add the new results in a
  separate file (`nomic-experiment-results.md`).
