import Foundation

/// Codable mirror of `scripts/rubric-queries.json`. Field names match the
/// JSON shape byte-for-byte (including `snake_case`) so a round-trip
/// decode preserves the manifest without a `CodingKeys` mapping. The
/// Python scorer (`scripts/score-rubric.py`) is the other consumer —
/// changing fields here must keep both readers in sync.
struct RubricManifest: Codable, Sendable {

    struct TargetFile: Codable, Sendable {
        let key: String
        let path: String
        let label: String
    }

    struct RankBracket: Codable, Sendable {
        let min: Int
        let max: Int
        let points: Int
    }

    struct Scoring: Codable, Sendable {
        let rank_brackets: [RankBracket]
        let absent_points: Int
        let max_per_query: Int
        let max_total: Int
        let top10_threshold: Int
    }

    struct Query: Codable, Sendable {
        let n: Int
        let text: String
    }

    let description: String
    let corpus: String
    let target_files: [TargetFile]
    let scoring: Scoring
    let queries: [Query]
}
