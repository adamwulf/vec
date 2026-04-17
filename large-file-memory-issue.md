# Large File Memory Issue

## Problem

`TextExtractor.extract` (Sources/VecKit/TextExtractor.swift:38) loads the entire file
contents into memory via `String(contentsOf:encoding:)`:

```swift
guard let content = try? String(contentsOf: file.url, encoding: .utf8) else {
    return []
}
```

For small source files this is fine, but the indexer is expected to handle log files
that are 100 MB or more. Loading the whole file into a Swift `String` means:

- Full file resident in RAM during extraction.
- `trimmingCharacters` creates another copy.
- `content.components(separatedBy: .newlines)` in `chunkText` allocates an array of
  line substrings spanning the whole file.
- For very large files this risks OOM on memory-constrained machines and is wasteful
  even when it fits.

## Related: oversized whole-document embedding

A separate but related correctness concern: `TextExtractor` always appends a
`.whole` chunk containing the full trimmed text (TextExtractor.swift:48). The
embedder then silently truncates any text longer than
`EmbeddingService.maxEmbeddingTextLength` (10,000 characters) to the first 10 KB
(EmbeddingService.swift:39-41). So the "whole-document" embedding for a 100 MB log
is really just the embedding of its first ~10 KB, which is misleading.

The same pattern exists in `extractFromPDF` (TextExtractor.swift:122-129), which
concatenates all page text into `allText` and embeds it as a `.whole` chunk.

**Fix:** skip the `.whole` chunk entirely when the trimmed text exceeds
`maxEmbeddingTextLength`. Line-range / per-page chunks still cover the content.

## Fix options for the memory issue

In rough order of implementation effort:

1. **Memory-map the file**: `Data(contentsOf: url, options: .mappedIfSafe)` lets
   the OS page contents in on demand. Requires decoding to `String` per-chunk
   rather than up front.
2. **Line-by-line streaming via `FileHandle`**: read a buffer, split on newlines,
   emit chunks as the sliding window accumulates. Most memory-efficient; changes
   the chunking loop substantially.
3. **`String(contentsOf:)` with a size guard**: skip or chunk-stream files above
   a threshold (e.g. 10 MB). Simplest but least thorough.

The chunker currently needs random line access to build overlapping windows
(TextExtractor.swift:70-99), so option 2 needs a small ring buffer of recent lines
rather than the full `lines` array.

## Acceptance criteria

- Indexing a 100 MB log file does not hold the whole file in memory at once.
- `.whole` chunks are not produced for files whose text exceeds
  `EmbeddingService.maxEmbeddingTextLength`.
- Existing line-range chunk output is unchanged for files under the threshold.
- No behavior change for small files (≤ `chunkSize` lines) — they still get a
  single `.whole` chunk covering the full content.

## Out of scope

- Backward compatibility with existing DB entries. Re-indexing deletes and
  re-inserts, so stale `.whole` rows clean themselves up.
- Changing the 10,000-character embedding limit — that is an NLEmbedding
  constraint, not something this issue tries to fix.
