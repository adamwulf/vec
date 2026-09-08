# E14 shared integration handoff

The HTML-owned implementation is synchronous, `Sendable`, Swift tools 6.0
compatible, and contains no resource loader. Shared wiring should call
`HTMLReadableContentExtractor.extract(_:sourceURL:options:)` only for an
explicit `html-v1` component on `.html` / `.htm` input; raw remains the default
and HTML remains discoverable in raw mode.

## API and mode composition

- Plain `html-v1` constructs `HTMLExtractionOptions` with `ocrAssets: nil`.
  Visible alt text is retained in DOM order, but no referenced URL is resolved,
  hashed, opened, or decoded and `assetManifest` is nil.
- `html-v1+image-ocr-v1` supplies `HTMLOCRAssetOptions`, using
  `currentPolicyVersion`. Iterate eligible image segments in order and invoke
  the existing injected `ImageTextRecognizer` through
  `HTMLImageReference.withMaterializedURL(in:_:)`. Do this sequentially inside
  each document; do not create an HTML-specific OCR task lane. Pass successful
  text to `renderedText(ocrTextByImageOrdinal:)`.
- A blank OCR result is successful. A recognizer/read throw remains transient:
  propagate the document extraction failure so update state retries it. Missing,
  unsupported, remote, outside-root, and policy-oversized sources are stable
  soft skips with diagnostics; alt and surrounding text remain indexable.
- The combined mode's allowed root should be the canonical scanner source
  directory, not the HTML file's asset subdirectory and never `/`. The temp
  directory should live under vec's per-database working/cache directory.
- Read HTML bytes through a capped file-read helper before constructing a
  `String`; the extractor independently checks the supplied string's UTF-8
  byte count before its first DOM allocation.
- Preserve the raw HTML line count only for existing completion accounting.
  Every transformed HTML chunk must have nil source start/end lines: no source
  map exists across selection, entity decoding, cleanup, or structural render.

Suggested initial explicit bounds for manager review are 16 MiB HTML input,
250,000 DOM elements, 64 OCR-eligible image positions, 32 MiB per local image,
8 MiB decoded per data image, and 32 MiB aggregate retained decoded data. These
are operational caps, not claims about representative page sizes; record the
resolved values in E14 run provenance.

## Dependency manifest and invalidation

Call `discoverDependencies` with the same combined-mode options before the
unchanged-file decision. It uses the same bounded DOM selection and asset
policy as extraction. Plain HTML returns nil and incurs no asset I/O.

`HTMLAssetManifest` is Codable and self-validating:

```text
schemaVersion: 1
policyVersion: 1
entries[] (DOM order):
  ordinal: Int
  relativePath: String       # relative to allowed root
  state: present | missing | tooLarge
  byteCount: Int64?
  sha256: String?
digest: SHA-256(canonical sorted-key JSON of fields above, excluding digest)
```

Persist one manifest per indexed HTML source in the database sidecar. Before
classifying unchanged HTML, compare schema, policy, ordered entries, and digest
against a fresh discovery. This detects asset content changes even with a
preserved mtime, plus deletion, creation, size-state changes, source-order
changes, and policy changes. Inline data is already covered by the owning HTML
bytes; remote/unsupported sources never affect indexed OCR text and are not
manifest dependencies.

Discovery cost is one bounded DOM parse/render plus 64 KiB streaming SHA-256
reads of eligible local files. It may boundedly decode data URIs because it
shares the exact extraction policy, but does not retain a parsed DOM across
documents. Missing and size states are returned normally. Metadata, permission,
or streaming-read errors propagate and must prevent an unchanged/success mark.

Reset/remove must delete the HTML manifest sidecar alongside other database
state. A mode change, parser/reader version change, or OCR asset-policy version
change must force re-extraction even if file and manifest bytes otherwise match.

## Reproducibility and known limits

- Parser: exact SwiftSoup 2.13.6, resolved revision
  `ead56133a693d0184d8c2db1a6d6394410cacfd6`.
- Reader: structural strategy version 1. This is not Mozilla Readability.
- Selector: unique `<main>`, case-insensitive unique `role=main`, or unique
  `<article>`; otherwise cleaned full page; if that becomes empty, preserve page
  navigation while still stripping executable/embedded elements.
- Static parsing has no computed CSS visibility or browser `currentSrc`.
  Policy v1 prefers `src`, common lazy-source attributes, then the first
  `srcset` candidate. It ignores `<base>` for asset access and resolves relative
  paths against the saved HTML file under the explicit root.
- Class-weighted ads, comments, and sidebars may survive when semantic markup is
  absent. Conversely, semantic `<nav>` is removed unless doing so would erase
  the whole page. These are deliberate preservation-biased limitations.
- Canonical path checks reject ordinary traversal and resolved symlink escape.
  As with most path-based APIs, a hostile concurrent symlink swap between the
  check and open is not prevented; the intended input is an operator-controlled
  local snapshot, not a mutually hostile writable directory.
