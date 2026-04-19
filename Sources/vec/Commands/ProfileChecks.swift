import Foundation
import VecKit

/// Shared check-order helpers for commands that read the recorded
/// profile and cannot bootstrap one themselves (`search`, `insert`).
///
/// The missing-profile split is:
/// - `profile == nil && chunkCount  > 0` → `preProfileDatabase`
///   (a pre-refactor DB with content but no recorded profile — the
///   user must `vec reset` before re-indexing).
/// - `profile == nil && chunkCount == 0` → `profileNotRecorded`
///   (freshly `vec init`ed / `vec reset`-ed — no profile yet, run
///   `vec update-index` first).
enum ProfileChecks {
    /// Returns the recorded `ProfileRecord` or throws the appropriate
    /// missing-profile `VecError`. Call from commands that require a
    /// recorded profile to proceed.
    static func requireRecordedProfile(
        config: DatabaseConfig,
        chunkCount: Int
    ) throws -> DatabaseConfig.ProfileRecord {
        if let recorded = config.profile {
            return recorded
        }
        if chunkCount > 0 {
            throw VecError.preProfileDatabase
        } else {
            throw VecError.profileNotRecorded
        }
    }
}
