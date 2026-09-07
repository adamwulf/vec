# E14 — Opt-in readable HTML extraction

Status: implementation in progress. The Readability/fallback examples from the
user's `freezedry-helper` agent have been received and acknowledged. The user
explicitly decided on 2026-09-07 that vec must not raise its Swift tools floor
to 6.2, closing the native SwiftReadability dependency path. The local sample,
query labels, and final benchmark rubric remain deliberately unfrozen until
they are reviewed against the actual saved-page fixtures.

## Question

Can an opt-in, versioned `html-v1` extraction mode turn saved `.html` and
`.htm` files into useful readable content before chunking, while suppressing
scripts, styles, navigation, and common boilerplate without making
non-article pages disappear?

The extractor operates on local saved files only. It never fetches a linked
page or image and never executes scripts. Remote references remain inert.

## Fixed scope

- Raw extraction remains the default. HTML normalization is opt-in and must
  compose canonically with the existing Markdown, WebVTT, image-OCR, and PDF
  extraction components.
- Preserve useful visible structure: document/article title, headings,
  paragraphs, lists, and tables. Exact rendering syntax remains open until
  representative examples are reviewed.
- Prefer readable page/article content when it can be identified, with a
  conservative fallback for reference, documentation, index, and other
  non-article pages. Exact selection and fallback rules remain open.
- Suppress non-content elements such as scripts and styles without executing
  any page code. Navigation, banners, sidebars, footers, ads, comments, and
  repeated chrome are candidates for suppression, subject to the frozen
  examples and preservation rubric.
- Malformed HTML must produce a deterministic best-effort result rather than
  crash. Empty or purely structural pages produce no text chunks.
- HTML-derived chunks do not claim source line numbers. DOM selection and
  rendering transform and reorder source text, so raw-file line ranges would
  be misleading without a real source map.
- `html-v1` alone extracts HTML text. Inline-image OCR is enabled only when the
  mode also includes `image-ocr-v1`; it reuses the injected E12 recognizer and
  cache, performs no nested parallel work, and never embeds image bytes.
- Preserve selected inline-image positions so OCR text stays near its
  surrounding prose. Referenced asset changes must invalidate the owning HTML
  result even when the HTML mtime is unchanged. Local-path/data-image policy,
  dependency persistence, work limits, and per-image error semantics must be
  frozen and tested before implementation.
- No new embedding model, reranking, summaries, keyword retrieval, linked-page
  crawling, JavaScript execution, or network access.

## Proposed HTML-specific API

The HTML-owned source should expose one narrow, synchronous boundary to the
shared `TextExtractor`:

```swift
public struct HTMLReadableContent: Sendable, Equatable {
    public let strategyIdentifier: String
    public let extractorVersion: Int
    public let title: String?
    public let segments: [HTMLContentSegment]
    public let assetManifest: HTMLAssetManifest?
}

public enum HTMLReadableContentExtractor {
    public static func extract(
        _ html: String,
        sourceURL: URL,
        options: HTMLExtractionOptions
    ) throws -> HTMLReadableContent

    public static func discoverDependencies(
        _ html: String,
        sourceURL: URL,
        options: HTMLExtractionOptions
    ) throws -> HTMLAssetManifest?
}
```

`HTMLContentSegment` is ordered and contains either rendered text or an inline
image reference. `HTMLAssetManifest` is nil for plain `html-v1`; in that mode
image alt text remains visible but no source is resolved, read, hashed, or
decoded. When OCR assets are explicitly enabled, the manifest carries a stable
digest over eligible local references and their present/missing/content state;
it contains no image data. `HTMLExtractionOptions` always supplies a pre-parse
input-byte limit and parser element limit, while an optional
`HTMLOCRAssetOptions` supplies the allowed snapshot root and image bounds. Both
the shared file reader and the HTML entry point enforce the input limit before
constructing a DOM; an element limit checked after parsing is not a memory
bound. The final extractor boundary remains subject to shared wiring review
because scanner/database code must persist and compare the dependency digest.
Dependency discovery may reparse bounded input rather than retaining DOMs
across a corpus and growing resident state.

The implemented asset-policy schema is version 1. It prefers static `src`,
then common lazy-source attributes, then the first static `srcset` candidate.
It accepts only raster data URIs supported by E12 or local raster paths whose
canonical target remains below the explicit snapshot root. HTTP(S) and other
schemes are inert. Present files are SHA-256 hashed in 64 KiB reads; missing
and oversized paths are explicit manifest states, while genuine metadata/read
errors throw so a transient failure cannot be recorded as a successful index.
The manifest is linear in selected eligible references and retains only small
metadata. Inline data is decoded only in the OCR composition, deduplicated by
digest, and bounded both per distinct image and in aggregate; temporary OCR
files are materialized one at a time and removed across success and throws.
The image-work cap suppresses only OCR eligibility—surrounding prose and every
visible alt string remain in DOM order.

The shared `TextExtractor` remains responsible for mode dispatch, raw source
line count, in-order OCR composition through its injected recognizer/cache,
whole-document and split chunk construction, and failure semantics. Strategy
identifiers are stable diagnostics for tests and run archives; the persisted
mode remains `html-v1` rather than a third-party package name.

## Received Readability/fallback evidence

The user's `freezedry-helper` implementation vendors Mozilla Readability
0.6.0, Turndown 7.2.4, and turndown-plugin-gfm 1.0.2. It first applies a
Mozilla-style readerability heuristic, accepts Readability output only when
trimmed article text is at least 500 characters, and otherwise converts a
cleaned visible full-page clone. That fallback is important for app, list,
dashboard, reference, and short-content pages. It removes scripts, styles,
frames, embeds, hidden content, navigation roles, and form/button chrome while
keeping ordinary links, lists, tables, and footer text. It renders the chosen
container once to Markdown, so selection and output do not diverge.

E14 will preserve that two-path principle, not blindly copy its constants.
The readerability gate and 500-character acceptance threshold must be checked
against the frozen local examples, especially short articles and reference
pages. Browser-only computed visibility and `currentSrc` do not exist in a
static Swift parser; E14 must document the narrower static-HTML semantics
rather than implying browser-rendered visibility.

Exact `SwiftReadability` 0.3.3 was investigated but rejected because every
native SwiftReadability release from 0.1.0 through 0.3.3 requires Swift 6.2 and
the user chose not to raise vec's Swift 6.0 floor. E14 therefore pins exact
SwiftSoup 2.13.6 and labels its selector honestly as structural, not Mozilla
Readability. Version 1 honors a unique semantic `<main>`, case-insensitive
`role=main`, or (when neither main form exists) unique `<article>`. Otherwise
it uses cleaned visible-page extraction. If that cleanup would erase all
content, it retries with an always-dangerous-element-only cleanup so a
navigation-only directory or app page cannot silently disappear. It uses no
opaque text-length gate; this intentionally preserves short pages but cannot
match Readability's class weighting, link-density analysis, and article
scoring. A WebKit wrapper remains unsuitable for this synchronous concurrent
CLI path, and vendoring Mozilla JavaScript would require a separately pinned
DOM runtime.

## Pre-freeze deterministic test matrix

- Article page: keep title, headings, prose, and meaningful lists; suppress
  page chrome, scripts, styles, ads, related links, and comments.
- Non-article reference page: preserve its main headings, grouped links or
  descriptions, lists, and tables rather than returning an empty result.
- Navigation-heavy page: reject global navigation noise when meaningful main
  content exists, but exercise the fallback that avoids dropping a legitimate
  index/directory page.
- Structural rendering: ordered/unordered/nested lists, table headers/cells,
  entities, Unicode, links (visible labels retained), line breaks, and title
  behavior.
- Malformed HTML: unclosed/misnested tags and malformed entities recover
  deterministically.
- Empty content: empty documents and script/style-only documents yield no
  chunks.
- Isolation: raw mode and non-HTML files remain unchanged. `.html` / `.htm`
  and uppercase variants are already discovered under raw extraction; only
  their normalization is opt-in.
- Provenance: normalized chunks carry no line/page claims.
- No-network guard: remote page, stylesheet, script, frame, and image
  references remain inert and cannot trigger resource loading.
- Inline-image OCR with an injected fake recognizer: selected-DOM order,
  exact alt/OCR duplicate handling without dropping distinct text, duplicate
  assets, changed/missing assets, unsupported and remote references, local
  path containment/symlink escape, data-image limits when enabled, image-count
  cap, blank recognition, and the frozen per-image failure behavior.

These categories were fixed before implementation. The committed sample now
freezes seven synthetic HTML bodies (six targets and one executable-only
distractor) and the rubric freezes six answered and two no-answer queries.
They were constructed from the supplied behavioral examples before any
retrieval ranking was observed. They are deliberately labeled synthetic and
are not evidence of representative-web accuracy.

## Controlled comparison (inputs frozen; run pending shared wiring)

Follow E10–E12 methodology once representative examples are available:

1. Commit a byte-hashed HTML sample manifest and fixed query manifest before
   observing rankings. Record real versus synthetic provenance and selection
   bias; do not commit private source bodies without explicit permission.
2. Compare `raw`, `html-v1`, and (when the frozen sample contains meaningful
   local inline-image text) `html-v1+image-ocr-v1` using the same pinned
   embedder, chunk geometry, concurrency, model revision, source snapshot, and
   result limits. Keep text-selection effects separate from OCR effects.
3. Archive every per-query result plus corpus/query/model/build hashes, resolved
   settings, chunk counts, extraction timing, selection strategy counts, and
   readable-content diagnostics.
4. Use an independent scorer that derives file ranks from archived score-sorted
   groups, rejects missing, duplicate, corrupt, or inconsistent results, and
   reports file rank separately from advisory passage-content checks.
5. Report content preservation and boilerplate suppression separately. A
   smaller output is not automatically better, and no-answer similarities are
   not confidence probabilities.

## Success criteria

- [x] Receive and acknowledge the user's Readability/fallback examples from
  `freezedry-helper`; retain the actual local fixture labels as pre-ranking
  decisions.
- [x] Adopt a reproducible dependency/version policy compatible with the
  package's macOS and Swift toolchain, or document and test a dependency-free
  implementation.
- [x] Extract readable article and non-article content deterministically with
  no script execution or network access.
- [x] Preserve useful title/heading/list/table/entity content while suppressing
  frozen boilerplate cases; cover malformed and empty HTML.
- [ ] Enforce a pre-DOM input-byte bound, bound parser/renderer and inline-image
  OCR work, test dependency invalidation, and ensure HTML does not multiply the
  existing OCR concurrency. HTML-owned bounds and invalidation tests pass; the
  final sequential OCR-loop assertion belongs to shared wiring.
- [ ] Keep mode behavior opt-in and composable; coordinate persistence, reset,
  scanner/CLI, and pipeline wiring with the manager.
- [ ] Freeze and run the E14 sample/rubric with independent scoring and full
  provenance, reporting neutral or negative results honestly.
- [ ] Pass focused and full relevant tests, self-review, and independent review.

An accuracy improvement is a hypothesis, not a completion requirement. No
default change follows from this experiment alone.
