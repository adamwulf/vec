import XCTest
import NaturalLanguage
@testable import VecKit

/// Stress test for H1 (see optimization-plan.md): validates whether a single
/// shared `NLEmbedding.sentenceEmbedding(for: .english)` instance is safe to
/// call concurrently from many Swift tasks. The pool in `EmbedderPool`
/// assumes it is not — this test exists to re-measure that claim.
///
/// NOTE: this test is EXPECTED to crash the process with SIGSEGV on macOS
/// (it's the regression canary for the NLEmbedding thread-safety bug). Do
/// not run it under the normal test suite — a crash here aborts every
/// test that would run after it in the same xctest process. Skipped
/// unless `VEC_CRASH_TESTS=1` is set, e.g.
///
///     VEC_CRASH_TESTS=1 swift test --filter VecKitTests.NLEmbeddingThreadSafetyTests
final class NLEmbeddingThreadSafetyTests: XCTestCase {

    private static let expectedDimension = 512
    private static let taskCount = 10
    private static let totalCalls = 10_000

    func testSingleSharedInstanceUnderConcurrentLoad() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VEC_CRASH_TESTS"] != nil,
            "Crash-expected test — set VEC_CRASH_TESTS=1 to run (it will SIGSEGV)"
        )
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            XCTFail("NLEmbedding.sentenceEmbedding(for: .english) returned nil")
            return
        }

        XCTAssertEqual(embedding.dimension, Self.expectedDimension,
                       "Unexpected embedding dimension")

        let corpus = Self.buildCorpus()
        XCTAssertGreaterThanOrEqual(corpus.count, 200,
                                    "Corpus should have plenty of varied inputs")

        let callsPerTask = Self.totalCalls / Self.taskCount
        let totalExpected = callsPerTask * Self.taskCount

        let start = Date()

        let successCount: Int = await withTaskGroup(of: Int.self) { group in
            for taskIndex in 0..<Self.taskCount {
                group.addTask {
                    var localSuccess = 0
                    for i in 0..<callsPerTask {
                        // Stride so different tasks pull different texts each iteration.
                        let idx = (taskIndex &* 7919 &+ i &* 31) % corpus.count
                        let text = corpus[idx]
                        if let vector = embedding.vector(for: text) {
                            if vector.count == Self.expectedDimension {
                                localSuccess += 1
                            }
                        }
                    }
                    return localSuccess
                }
            }

            var total = 0
            for await count in group {
                total += count
            }
            return total
        }

        let elapsed = Date().timeIntervalSince(start)
        print("[NLEmbeddingThreadSafetyTests] \(totalExpected) calls across \(Self.taskCount) tasks in \(String(format: "%.2f", elapsed))s (\(Int(Double(totalExpected) / elapsed)) calls/sec)")

        // Every varied-corpus string is embeddable English — every call should
        // return a 512-dim vector. If the underlying runtime corrupts state
        // under concurrent access we'd expect either a crash, a nil return,
        // or a mis-sized vector here.
        XCTAssertEqual(successCount, totalExpected,
                       "Expected every vector(for:) call to return a \(Self.expectedDimension)-dim vector")
    }

    // MARK: - Corpus

    /// Builds a few hundred distinct, varied English strings by combining
    /// short phrases, medium sentences, and longer paragraphs. No external
    /// resources — the strings are generated deterministically at runtime.
    private static func buildCorpus() -> [String] {
        var out: [String] = []

        let shortPhrases = [
            "hello world", "the quick brown fox", "embedding vectors",
            "natural language processing", "swift concurrency",
            "thread safety matters", "apple silicon is fast",
            "coffee and code", "afternoon light", "open source software",
            "vector databases", "cosine similarity", "high dimensional space",
            "machine learning", "neural networks", "transformer models",
            "attention is all you need", "gradient descent", "loss function",
            "training loop", "mini batch", "regularization", "overfitting",
            "cross validation", "feature engineering", "dimensionality reduction",
            "principal component analysis", "stochastic process", "markov chain",
            "monte carlo", "bayesian inference", "prior distribution",
            "posterior probability", "likelihood function", "maximum entropy",
            "information theory", "kullback leibler", "shannon entropy",
            "data compression", "lossless encoding", "huffman tree",
            "binary search", "red black tree", "hash map", "skip list",
            "bloom filter", "consistent hashing", "distributed systems",
            "eventual consistency", "raft consensus"
        ]

        let sentenceTemplates = [
            "The project ships a CLI that indexes local files into a vector database for semantic search.",
            "On-device embeddings avoid sending private content to any cloud provider, which keeps the workflow offline and private.",
            "Benchmarking concurrency changes requires holding the corpus and flags constant across every run.",
            "A worker pool of ten instances duplicates the embedding model weights at a cost of roughly fifty megabytes each.",
            "If the underlying framework is already thread-safe, a single shared instance would save hundreds of megabytes.",
            "Tokenization and model setup dominate the cost of small embeddings, so larger chunks may amortize better.",
            "First-batch latency is fifteen seconds, partly because every pooled embedder loads its model lazily at first use.",
            "Thread sanitizer reports on data races that happen during the run, even if the program does not crash outright.",
            "Running the stress test five times in a row guards against intermittent failures that show up only under load.",
            "The sentence embedding model for English produces five-hundred-twelve-dimensional vectors at inference time.",
            "A chunk that exceeds ten thousand characters is truncated before being passed into the framework to avoid a bad alloc.",
            "The save queue stays near zero depth throughout indexing, so database writes are not the bottleneck today.",
            "Worker count defaults to max of active processor count and two, which can oversubscribe machines with few cores.",
            "The test corpus mixes short phrases, medium sentences, and long paragraphs to simulate real chunk variability.",
            "If H1 succeeds we collapse the pool to one shared embedder guarded by a semaphore sized to the core count.",
            "The verbose stats renderer prints average and rolling throughput numbers so regressions are easy to spot.",
            "Each hypothesis in the optimization plan has its own success criteria and isolated measurement methodology.",
            "Swift structured concurrency makes it straightforward to fan out work across tasks while keeping cleanup tidy.",
            "We prefer an empirical answer here because the original claim could have been true on an older OS and stale now.",
            "The embedder pool currently round-robins across ten instances to avoid contending on a single instance's lock."
        ]

        let paragraphBits = [
            "Vector search lets us retrieve content by meaning rather than by keyword. The query is encoded into the same space as the documents, and the nearest neighbors surface as results.",
            "On a warm cache the file system reads are negligible compared to the embed cost. On a cold cache, however, read latency can dominate and distort benchmarks taken immediately after reboot.",
            "A single NLEmbedding instance loads the model once. Ten instances load ten copies. If the framework already parallelizes its matmul internally we are paying for contention that hurts throughput.",
            "Thread sanitizer instruments every memory access at a significant runtime cost, so tests run under TSan take much longer. The payoff is that it flags races that intermittent tests would miss.",
            "Swift's task groups compose well with throwing APIs and provide automatic cancellation propagation. That makes them a natural fit for concurrent stress tests that need clean teardown on failure."
        ]

        // Short phrases (50)
        out.append(contentsOf: shortPhrases)

        // Medium sentences (20)
        out.append(contentsOf: sentenceTemplates)

        // Paragraph-sized strings (5)
        out.append(contentsOf: paragraphBits)

        // Generate additional distinct variants to get past 200 strings total.
        // Each variant is a unique concatenation with an index, so no dupes.
        for i in 0..<150 {
            let phrase = shortPhrases[i % shortPhrases.count]
            let sentence = sentenceTemplates[i % sentenceTemplates.count]
            out.append("Variant \(i): \(phrase). \(sentence)")
        }

        // A handful of longer paragraphs (5 more) built from the paragraph bits
        for i in 0..<5 {
            let base = paragraphBits[i % paragraphBits.count]
            let extra = sentenceTemplates[(i * 3) % sentenceTemplates.count]
            out.append("Paragraph \(i). \(base) \(extra)")
        }

        return out
    }
}
