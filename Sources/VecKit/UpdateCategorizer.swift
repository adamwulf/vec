import Foundation

/// Result of categorizing a freshly-scanned file list against the
/// `indexed_files` table. Used by `update-index` to decide which files
/// need re-extracting.
public struct UpdateCategorization: Sendable {
    /// Files that need to flow through the indexing pipeline. The
    /// `label` is "Added" when the file has no DB row yet, "Updated"
    /// when its mtime is newer than the stored one.
    public let workItems: [(file: FileInfo, label: String)]

    /// Count of files that match the DB record exactly — neither new
    /// nor newer-than-indexed.
    public let unchanged: Int
}

/// Tolerance applied to the "scanned mtime is newer than indexed mtime"
/// comparison. Storing a `Date` as a `timeIntervalSince1970` REAL and
/// reading it back via `Date(timeIntervalSince1970:)` is not bit-exact
/// across the 1970↔2001 epoch offset arithmetic — the result can drift
/// by one ULP at the relevant binade (~1.19e-7 s today). A strict `>`
/// would treat that drift as "newer" and re-extract files that have
/// not actually changed.
///
/// 1 ms is ~8000× the observed ULP and well below any filesystem's
/// coarsest mtime granularity (1 s on FAT/HFS+) or any meaningful
/// editor-save cadence on APFS. The justification is purely "ULP
/// headroom + below FS granularity"; this is not a product-level
/// "we suppress sub-1 ms edits" claim.
public let mtimeRoundtripTolerance: TimeInterval = 0.001

/// Categorize scanned files against the existing `indexed_files`
/// records. Pulled out of `UpdateIndexCommand` so the boundary cases
/// (1-ULP drift, exact-match, just-past-tolerance) are unit-testable
/// without spinning up a full pipeline.
///
/// - Parameters:
///   - scanned: result of `FileScanner.scan()` for the source dir.
///   - indexed: result of `VectorDatabase.allIndexedFiles()`.
/// - Returns: an `UpdateCategorization` partitioning `scanned` into
///   work items (`Added` / `Updated`) and the count of unchanged files.
public func categorizeForUpdate(
    scanned: [FileInfo],
    indexed: [String: Date]
) -> UpdateCategorization {
    var workItems: [(file: FileInfo, label: String)] = []
    var unchanged = 0

    for file in scanned {
        if let existingModDate = indexed[file.relativePath] {
            // Tolerance comparison sidesteps the
            // `Date → timeIntervalSince1970 → REAL → Date` round-trip
            // ULP drift documented in `mtimeRoundtripTolerance`.
            if file.modificationDate.timeIntervalSince(existingModDate) > mtimeRoundtripTolerance {
                workItems.append((file: file, label: "Updated"))
            } else {
                unchanged += 1
            }
        } else {
            workItems.append((file: file, label: "Added"))
        }
    }

    return UpdateCategorization(workItems: workItems, unchanged: unchanged)
}
