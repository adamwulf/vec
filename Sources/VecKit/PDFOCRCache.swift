import CryptoKit
import Foundation

public struct PDFOCRCacheStatistics: Sendable, Equatable {
    public var hits: Int
    public var misses: Int
    public var ocrCalls: Int
    public var coalescedRequests: Int

    public init(hits: Int = 0,
                misses: Int = 0,
                ocrCalls: Int = 0,
                coalescedRequests: Int = 0) {
        self.hits = hits
        self.misses = misses
        self.ocrCalls = ocrCalls
        self.coalescedRequests = coalescedRequests
    }
}

/// Page-granular PDF OCR sidecar cache. Keys include PDF content, extraction
/// version, page number, and every render setting. Results use a bounded LRU
/// resident tier plus atomic JSON files under `pdf-ocr-cache`; failures are
/// never stored, while successful blank results are.
final class PDFOCRCache: @unchecked Sendable {
    private struct Sidecar: Codable {
        let key: String
        let version: Int
        let result: PDFPageOCRRecognition
    }

    private let cacheDirectory: URL
    private let version: Int
    private let maxResidentEntries: Int
    private let condition = NSCondition()
    private var resident: [String: PDFPageOCRRecognition] = [:]
    private var lruOrder: [String] = []
    private var inFlight: Set<String> = []
    private var stats = PDFOCRCacheStatistics()

    private static let subdirectoryName = "pdf-ocr-cache"

    init(directory: URL, version: Int, maxResidentEntries: Int = 256) {
        precondition(maxResidentEntries >= 1, "maxResidentEntries must be >= 1")
        self.cacheDirectory = directory.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
        self.version = version
        self.maxResidentEntries = maxResidentEntries
    }

    var statistics: PDFOCRCacheStatistics {
        condition.lock()
        defer { condition.unlock() }
        return stats
    }

    func value(documentHash: String,
               pageNumber: Int,
               settings: PDFOCRRenderSettings,
               compute: () throws -> PDFPageOCRRecognition) throws -> PDFPageOCRRecognition {
        let key = Self.key(documentHash: documentHash,
                           version: version,
                           pageNumber: pageNumber,
                           settings: settings)
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

        defer {
            condition.lock()
            inFlight.remove(key)
            condition.broadcast()
            condition.unlock()
        }

        if let result = readSidecar(key: key) {
            condition.lock()
            storeLocked(result, key: key)
            stats.hits += 1
            condition.unlock()
            return result
        }

        condition.lock()
        stats.misses += 1
        condition.unlock()
        let result = try compute()
        condition.lock()
        stats.ocrCalls += 1
        condition.unlock()

        writeSidecar(result, key: key)
        condition.lock()
        storeLocked(result, key: key)
        condition.unlock()
        return result
    }

    private func storeLocked(_ result: PDFPageOCRRecognition, key: String) {
        resident[key] = result
        touchLocked(key)
        while lruOrder.count > maxResidentEntries {
            let evicted = lruOrder.removeFirst()
            resident.removeValue(forKey: evicted)
        }
    }

    private func touchLocked(_ key: String) {
        if let index = lruOrder.firstIndex(of: key) { lruOrder.remove(at: index) }
        lruOrder.append(key)
    }

    private func sidecarURL(key: String) -> URL {
        let filename = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(filename).json")
    }

    private func readSidecar(key: String) -> PDFPageOCRRecognition? {
        guard let data = try? Data(contentsOf: sidecarURL(key: key)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.version == version,
              sidecar.key == key else { return nil }
        return sidecar.result
    }

    private func writeSidecar(_ result: PDFPageOCRRecognition, key: String) {
        guard let data = try? JSONEncoder().encode(Sidecar(key: key, version: version, result: result)) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: sidecarURL(key: key), options: .atomic)
        } catch {
            // Cache persistence is best-effort and never turns valid OCR into
            // an extraction failure. The bounded resident tier still serves
            // this process.
        }
    }

    private static func key(documentHash: String,
                            version: Int,
                            pageNumber: Int,
                            settings: PDFOCRRenderSettings) -> String {
        "pdf=\(documentHash);version=\(version);vision=\(ImageOCR.requestRevision);page=\(pageNumber);dpi=\(settings.dpi);max=\(settings.maxPixelDimension)"
    }
}
