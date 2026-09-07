import CryptoKit
import Foundation

/// Snapshot of a cache's counters.
///
/// - `hits`: requests served from the resident map or a disk sidecar.
/// - `misses`: requests with no cached result, requiring recognition.
/// - `ocrCalls`: recognizer calls that returned a result. A transient
///   recognition failure counts as a miss but not an OCR call, so
///   `misses - ocrCalls` is the number of failed recognition attempts.
public struct ImageOCRCacheStatistics: Sendable, Equatable {
    public var hits: Int
    public var misses: Int
    public var ocrCalls: Int
    /// Requests that waited for another caller recognizing identical bytes.
    public var coalescedRequests: Int

    public init(hits: Int = 0, misses: Int = 0, ocrCalls: Int = 0, coalescedRequests: Int = 0) {
        self.hits = hits
        self.misses = misses
        self.ocrCalls = ocrCalls
        self.coalescedRequests = coalescedRequests
    }
}

/// Content-addressed OCR cache with a disk sidecar and a bounded in-memory
/// tier.
///
/// A request is keyed by the streaming SHA-256 of the image's bytes plus a
/// version tag, so identical bytes hit regardless of path and a version bump
/// invalidates every stale entry. Results live as one atomically-written JSON
/// sidecar per image under `<directory>/image-ocr-cache/`; a bounded LRU keeps
/// the hottest results resident so repeats within a run skip disk. Blank
/// results are cached (a text-less image is a hit next time); transient read
/// or recognition errors propagate and are not cached.
///
/// Thread-safe. Concurrent requests for the same content are single-flighted:
/// the first computes while the rest wait and then read the shared result, so
/// the underlying recognizer runs exactly once per unique content.
public final class ImageOCRCache: ImageTextRecognizer, @unchecked Sendable {

    private let recognizer: ImageTextRecognizer
    private let version: Int
    private let cacheDirectory: URL
    private let maxResidentEntries: Int

    /// Guards `resident`, `lruOrder`, `stats`, and `inFlight`, and provides
    /// the wait/broadcast used for single-flighting.
    private let condition = NSCondition()
    private var resident: [String: ImageOCRResult] = [:]
    /// Keys in least-to-most-recently-used order (front = coldest).
    private var lruOrder: [String] = []
    private var stats = ImageOCRCacheStatistics()
    /// Content keys currently being recognized by some caller.
    private var inFlight: Set<String> = []

    /// Bytes read per streaming-hash chunk.
    private static let hashChunkSize = 1 << 20 // 1 MiB
    /// Subdirectory (under the supplied directory) that holds the sidecars.
    private static let subdirectoryName = "image-ocr-cache"

    public init(directory: URL,
                recognizer: ImageTextRecognizer = ImageOCR(),
                version: Int = ImageOCR.version,
                maxResidentEntries: Int = 512) {
        precondition(maxResidentEntries >= 1, "maxResidentEntries must be >= 1")
        self.recognizer = recognizer
        self.version = version
        self.cacheDirectory = directory.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
        self.maxResidentEntries = maxResidentEntries
    }

    /// A thread-safe snapshot of the counters.
    public var statistics: ImageOCRCacheStatistics {
        condition.lock()
        defer { condition.unlock() }
        return stats
    }

    // MARK: - ImageTextRecognizer

    public func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        // Hash the bytes outside the lock (may throw on a read error, which
        // propagates as a transient failure — nothing is cached).
        let key = try Self.contentKey(for: imageURL)

        // Claim the right to compute this key, or wait for whoever holds it.
        var didCoalesce = false
        condition.lock()
        while true {
            if let cached = resident[key] {
                stats.hits += 1
                touchLocked(key)
                condition.unlock()
                return cached
            }
            if inFlight.contains(key) {
                // Count a request once even if another key wakes it up.
                if !didCoalesce {
                    stats.coalescedRequests += 1
                    didCoalesce = true
                }
                condition.wait()
                continue
            }
            inFlight.insert(key)
            break
        }
        condition.unlock()

        // We now own the computation for `key`. This defer releases the claim
        // and wakes waiters on EVERY exit path below — disk hit, recognizer
        // throw, content-changed skip, or a cached success — so a claim is
        // never leaked (which would hang every future request for this key).
        defer {
            condition.lock()
            if inFlight.remove(key) != nil {
                condition.broadcast()
            }
            condition.unlock()
        }

        // Warm disk sidecar?
        if let onDisk = readSidecar(forKey: key) {
            condition.lock()
            store(onDisk, forKey: key)
            stats.hits += 1
            condition.unlock()
            return onDisk
        }

        condition.lock()
        stats.misses += 1
        condition.unlock()

        // Recognize. A throw propagates with nothing cached; the defer releases
        // the claim so a waiter (or the next run) retries.
        let result = try recognizer.recognizeText(in: imageURL)

        condition.lock()
        stats.ocrCalls += 1
        condition.unlock()

        // Guard against a mid-OCR source replacement (TOCTOU). The recognizer
        // re-opened `imageURL` by path, so if a concurrent writer swapped the
        // file between our hash and the recognizer's read, `result` may
        // describe bytes other than `key`'s. Persist only when the content
        // still hashes to `key`; otherwise serve this caller but do not poison
        // the cache — caching under the wrong hash would return the wrong text
        // for that content forever. A re-hash failure (file now gone) is also
        // treated as "changed": serve, do not cache. (A pathological A→B→A
        // swap bracketed by our two hashes is undetectable here and is treated
        // as acceptable for the operator-triggered corpus; a true snapshot
        // would cost a full copy per image.)
        let verifyKey = try? Self.contentKey(for: imageURL)
        guard verifyKey == key else {
            return result
        }

        writeSidecar(result, forKey: key)
        condition.lock()
        store(result, forKey: key)
        condition.unlock()
        return result
    }

    // MARK: - Resident (LRU) tier — call sites hold `condition`.

    private func store(_ result: ImageOCRResult, forKey key: String) {
        resident[key] = result
        touchLocked(key)
        while lruOrder.count > maxResidentEntries {
            let evicted = lruOrder.removeFirst()
            if evicted != key {
                resident.removeValue(forKey: evicted)
            }
        }
    }

    private func touchLocked(_ key: String) {
        if let existing = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: existing)
        }
        lruOrder.append(key)
    }

    // MARK: - Disk sidecar tier

    /// Envelope persisted per image. The version travels with the payload so
    /// a stale sidecar (older algorithm) is detected on read and ignored.
    private struct Sidecar: Codable {
        let version: Int
        let result: ImageOCRResult
    }

    private func sidecarURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    /// Read a sidecar for `key`, or nil when absent, unreadable, corrupt, or
    /// written by a different version. A version/parse mismatch is a miss so
    /// the caller recomputes and overwrites.
    private func readSidecar(forKey key: String) -> ImageOCRResult? {
        let url = sidecarURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        guard envelope.version == version else { return nil }
        return envelope.result
    }

    /// Atomically persist `result` for `key`. Write failures are swallowed:
    /// a cache write is best-effort and must never fail extraction — the
    /// in-memory tier still serves this run.
    private func writeSidecar(_ result: ImageOCRResult, forKey key: String) {
        let envelope = Sidecar(version: version, result: result)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            // `.atomic` writes to a temp file and renames into place, so a
            // concurrent reader never sees a half-written sidecar.
            try data.write(to: sidecarURL(forKey: key), options: .atomic)
        } catch {
            // Best-effort; ignore.
        }
    }

    // MARK: - Content key

    /// The cache key for an image: streaming SHA-256 of its bytes, so identical
    /// bytes hit regardless of path. Reads the file incrementally so a large
    /// image never resides fully in memory. The version is not part of the key
    /// — it is recorded in each sidecar and validated on read (see `Sidecar`),
    /// so a version bump invalidates stale entries and overwrites them in place
    /// rather than orphaning per-version files.
    static func contentKey(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: hashChunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
