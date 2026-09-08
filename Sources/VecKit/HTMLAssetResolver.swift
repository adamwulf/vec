import CryptoKit
import Foundation

struct HTMLAssetResolution: Sendable, Equatable {
    let segments: [HTMLContentSegment]
    let manifest: HTMLAssetManifest?
    let diagnostics: [HTMLExtractionDiagnostic]
}

/// Resolves static image references for the optional HTML+OCR composition.
///
/// This type never opens a remote URL. A nil asset policy performs no URL
/// resolution, filesystem access, hashing, or data-URI decoding; it only maps
/// structural image positions and alt text into the public result model.
enum HTMLAssetResolver {
    private static let readBufferBytes = 64 * 1_024

    private enum LocalAssetState {
        case present(url: URL, digest: String, byteCount: Int64)
        case missing
        case tooLarge(byteCount: Int64)
    }

    static func resolve(
        _ structuralSegments: [HTMLStructuralSegment],
        htmlFileURL: URL,
        options: HTMLOCRAssetOptions?
    ) throws -> HTMLAssetResolution {
        guard let options else {
            return HTMLAssetResolution(
                segments: structuralSegments.map { segment in
                    switch segment {
                    case .text(let text):
                        .text(text)
                    case .image(let image):
                        .image(HTMLImageReference(
                            ordinal: image.ordinal,
                            altText: image.altText,
                            source: nil,
                            contentDigest: nil
                        ))
                    }
                },
                manifest: nil,
                diagnostics: []
            )
        }

        let allowedRoot = options.allowedAssetRoot.resolvingSymlinksInPath().standardizedFileURL
        var output: [HTMLContentSegment] = []
        var manifestEntries: [HTMLAssetManifest.Entry] = []
        var diagnostics: [HTMLExtractionDiagnostic] = []
        var eligibleImageCount = 0
        var retainedInlineBytes = 0
        var inlineByDigest: [String: (format: HTMLInlineRasterFormat, data: Data)] = [:]
        var localByCanonicalPath: [String: LocalAssetState] = [:]

        output.reserveCapacity(structuralSegments.count)
        for segment in structuralSegments {
            guard case .image(let image) = segment else {
                if case .text(let text) = segment { output.append(.text(text)) }
                continue
            }

            let candidate = preferredSource(in: image.sourceAttributes)
            guard let candidate else {
                output.append(.image(unresolvedImage(image)))
                continue
            }

            let classification = classify(candidate, relativeTo: htmlFileURL)
            switch classification {
            case .remote:
                diagnostics.append(.init(kind: .remoteImageIgnored, detail: candidate))
                output.append(.image(unresolvedImage(image)))

            case .unsupported:
                diagnostics.append(.init(kind: .unsupportedImageIgnored, detail: candidate))
                output.append(.image(unresolvedImage(image)))

            case .inline(let format, let encoded):
                guard ImageOCR.supportedExtensions.contains(format.fileExtension) else {
                    diagnostics.append(.init(kind: .unsupportedImageIgnored, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                guard eligibleImageCount < options.maximumImages else {
                    diagnostics.append(.init(kind: .imageLimitReached, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                eligibleImageCount += 1

                guard encoded.utf8.count <= maximumBase64Characters(for: options.maximumInlineImageBytes) else {
                    diagnostics.append(.init(kind: .inlineImageTooLarge, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                guard let decoded = Data(base64Encoded: encoded) else {
                    diagnostics.append(.init(kind: .inlineImageMalformed, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                guard decoded.count <= options.maximumInlineImageBytes else {
                    diagnostics.append(.init(kind: .inlineImageTooLarge, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }

                let digest = sha256(decoded)
                let retained: (format: HTMLInlineRasterFormat, data: Data)
                if let existing = inlineByDigest[digest] {
                    retained = existing
                } else {
                    guard decoded.count <= options.maximumTotalInlineImageBytes - retainedInlineBytes else {
                        diagnostics.append(.init(kind: .inlineImageTooLarge, detail: "aggregate inline-image limit at ordinal \(image.ordinal)"))
                        output.append(.image(unresolvedImage(image)))
                        continue
                    }
                    retainedInlineBytes += decoded.count
                    retained = (format, decoded)
                    inlineByDigest[digest] = retained
                }
                output.append(.image(HTMLImageReference(
                    ordinal: image.ordinal,
                    altText: image.altText,
                    source: .inlineData(format: retained.format, data: retained.data),
                    contentDigest: digest
                )))

            case .malformedInline:
                diagnostics.append(.init(kind: .inlineImageMalformed, detail: "image ordinal \(image.ordinal)"))
                output.append(.image(unresolvedImage(image)))

            case .local(let unresolvedURL):
                guard ImageOCR.supportedExtensions.contains(
                    unresolvedURL.pathExtension.lowercased()
                ) else {
                    diagnostics.append(.init(kind: .unsupportedImageIgnored, detail: unresolvedURL.lastPathComponent))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                guard eligibleImageCount < options.maximumImages else {
                    diagnostics.append(.init(kind: .imageLimitReached, detail: "image ordinal \(image.ordinal)"))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }
                eligibleImageCount += 1

                let resolvedURL = unresolvedURL.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(resolvedURL, in: allowedRoot),
                      let relativePath = relativePath(of: resolvedURL, in: allowedRoot) else {
                    diagnostics.append(.init(kind: .imageOutsideAllowedRoot, detail: unresolvedURL.path))
                    output.append(.image(unresolvedImage(image)))
                    continue
                }

                let state: LocalAssetState
                if let cached = localByCanonicalPath[relativePath] {
                    state = cached
                } else {
                    state = try inspectLocalAsset(
                        at: resolvedURL,
                        maximumBytes: options.maximumLocalImageBytes
                    )
                    localByCanonicalPath[relativePath] = state
                }

                switch state {
                case .missing:
                    manifestEntries.append(.init(
                        ordinal: image.ordinal,
                        relativePath: relativePath,
                        state: .missing
                    ))
                    diagnostics.append(.init(kind: .localImageMissing, detail: relativePath))
                    output.append(.image(unresolvedImage(image)))

                case .tooLarge(let byteCount):
                    manifestEntries.append(.init(
                        ordinal: image.ordinal,
                        relativePath: relativePath,
                        state: .tooLarge,
                        byteCount: byteCount
                    ))
                    diagnostics.append(.init(kind: .localImageTooLarge, detail: relativePath))
                    output.append(.image(unresolvedImage(image)))

                case .present(let url, let digest, let byteCount):
                    manifestEntries.append(.init(
                        ordinal: image.ordinal,
                        relativePath: relativePath,
                        state: .present,
                        byteCount: byteCount,
                        sha256: digest
                    ))
                    output.append(.image(HTMLImageReference(
                        ordinal: image.ordinal,
                        altText: image.altText,
                        source: .localFile(url),
                        contentDigest: digest
                    )))
                }
            }
        }

        return HTMLAssetResolution(
            segments: output,
            manifest: try HTMLAssetManifest(
                policyVersion: options.policyVersion,
                entries: manifestEntries
            ),
            diagnostics: diagnostics
        )
    }

    // MARK: - Source selection and classification

    private enum ClassifiedSource {
        case local(URL)
        case inline(HTMLInlineRasterFormat, String)
        case malformedInline
        case remote
        case unsupported
    }

    /// Versioned policy v1 prefers the ordinary static source, then common
    /// lazy-loading attributes, then the first srcset candidate. It never
    /// attempts to reproduce browser layout or execute lazy-loading scripts.
    private static func preferredSource(in attributes: [String: String]) -> String? {
        for name in ["src", "data-src", "data-original", "data-lazy-src"] {
            if let value = attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        for name in ["srcset", "data-srcset"] {
            guard let value = attributes[name] else { continue }
            if let first = value.split(separator: ",", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first {
                return String(first)
            }
        }
        return nil
    }

    private static func classify(_ raw: String, relativeTo htmlFileURL: URL) -> ClassifiedSource {
        let lowercased = raw.lowercased()
        if lowercased.hasPrefix("data:") {
            guard let comma = raw.firstIndex(of: ",") else { return .malformedInline }
            let metadata = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma])
            let pieces = metadata.split(separator: ";", omittingEmptySubsequences: false)
            guard let mime = pieces.first,
                  pieces.dropFirst().contains(where: { $0.lowercased() == "base64" }) else {
                return .malformedInline
            }
            guard let format = HTMLInlineRasterFormat(mimeType: String(mime)) else {
                return .unsupported
            }
            return .inline(format, String(raw[raw.index(after: comma)...]))
        }

        guard let url = URL(string: raw, relativeTo: htmlFileURL)?.absoluteURL else {
            return .unsupported
        }
        switch url.scheme?.lowercased() {
        case "file": return .local(url)
        case "http", "https": return .remote
        default: return .unsupported
        }
    }

    // MARK: - Bounds and hashing

    private static func maximumBase64Characters(for decodedByteLimit: Int) -> Int {
        guard decodedByteLimit <= (Int.max - 2) / 3 else { return Int.max }
        let groups = decodedByteLimit / 3 + (decodedByteLimit % 3 == 0 ? 0 : 1)
        guard groups <= Int.max / 4 else { return Int.max }
        return groups * 4
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func inspectLocalAsset(
        at url: URL,
        maximumBytes: Int64
    ) throws -> LocalAssetState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .missing
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return .missing }
        let advertisedByteCount = Int64(values.fileSize ?? 0)
        guard advertisedByteCount <= maximumBytes else {
            return .tooLarge(byteCount: advertisedByteCount)
        }
        let hashed = try sha256(fileAt: url, maximumBytes: maximumBytes)
        return .present(url: url, digest: hashed.digest, byteCount: hashed.byteCount)
    }

    private static func sha256(
        fileAt url: URL,
        maximumBytes: Int64
    ) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var consumed: Int64 = 0
        while let data = try handle.read(upToCount: readBufferBytes), !data.isEmpty {
            consumed += Int64(data.count)
            guard consumed <= maximumBytes else {
                throw HTMLExtractionError.localAssetTooLarge(
                    path: url.path,
                    actualBytes: consumed,
                    maximumBytes: maximumBytes
                )
            }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, consumed)
    }

    private static func unresolvedImage(_ image: HTMLStructuralImage) -> HTMLImageReference {
        HTMLImageReference(
            ordinal: image.ordinal,
            altText: image.altText,
            source: nil,
            contentDigest: nil
        )
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func relativePath(of candidate: URL, in root: URL) -> String? {
        guard isContained(candidate, in: root) else { return nil }
        let suffix = candidate.pathComponents.dropFirst(root.pathComponents.count)
        return suffix.joined(separator: "/")
    }
}
