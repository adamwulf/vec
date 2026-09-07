import Foundation

/// Version 1 caption preprocessing, independent of the embedding/chunk profile.
/// Parses cue blocks rather than treating every non-timestamp line as speech.
/// Invalid blocks are skipped; valid cues can be recovered without a header.
public enum VTTTextNormalizer {
    public static func normalize(_ source: String) -> String {
        document(source).text
    }

    struct Passage {
        var text: String
        let lineStart: Int
        var lineEnd: Int
        let start: Double
        let speaker: String?
    }

    struct Document {
        let passages: [Passage]
        let lineCount: Int
        var text: String { passages.map(\.text).joined(separator: "\n\n") }

        // Each passage occupies one normalized line, separated by a blank.
        // Locations deliberately cover the whole source passage, including
        // its first timing line, even when the splitter subdivides the prose.
        func sourceLines(start: Int?, end: Int?) -> (Int?, Int?) {
            guard let start, let end, !passages.isEmpty,
                  start >= 1, end >= start, end <= passages.count * 2 - 1 else { return (nil, nil) }
            return (passages[(start - 1) / 2].lineStart, passages[(end - 1) / 2].lineEnd)
        }
    }

    private struct Cue {
        let start: Double
        let end: Double
        let lineStart: Int
        let lineEnd: Int
        let turns: [Turn]
    }

    private struct Turn {
        let speaker: String?
        let text: String
    }

    // Fixed, programmer-authored expressions. No input is compiled as regex.
    private static let timing = try! NSRegularExpression(
        pattern: #"^((?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})[ \t]+-->[ \t]+((?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})(?:[ \t].*)?$"#)
    private static let tag = try! NSRegularExpression(pattern: #"<([^<>\r\n]*)>"#)
    private static let entity = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)

    static func document(_ source: String) -> Document {
        var normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lineCount = normalized.isEmpty ? 0 : normalized.components(separatedBy: "\n").count - (normalized.hasSuffix("\n") ? 1 : 0)
        if normalized.first == "\u{FEFF}" { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        var cues: [Cue] = []
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            let start = index
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
            let block = Array(lines[start..<index])
            let first = block[0].trimmingCharacters(in: .whitespaces)
            if isBlock(first, named: "WEBVTT") || isBlock(first, named: "NOTE") || first == "STYLE" || first == "REGION" { continue }
            // A cue has either a timing line or one identifier then timing.
            var offset = times(block[0]) != nil ? 0 : 1
            while offset < block.count {
                guard let (begin, end) = times(block[offset]), end > begin else { break }
                // Exporters sometimes omit a blank separator. A timing line
                // must start a new cue, never leak into the preceding prose.
                let next = ((offset + 1)..<block.count).first { times(block[$0]) != nil } ?? block.count
                let payload = block[(offset + 1)..<next].joined(separator: "\n")
                let turns = cueText(payload)
                if !turns.isEmpty {
                    cues.append(Cue(start: begin, end: end, lineStart: start + offset + 1,
                                    lineEnd: start + next, turns: turns))
                }
                offset = next
            }
        }

        var passages: [Passage] = []
        var previous: Cue?
        for cue in cues {
            for (turnIndex, turn) in cue.turns.enumerated() {
                var words = turn.text.split(whereSeparator: \.isWhitespace).map(String.init)
                // Only the immediately preceding, single-speaker cue can
                // establish rolling overlap. Never dedup across speakers,
                // backwards time, silence, or multi-speaker cues.
                if turnIndex == 0, cue.turns.count == 1, let previous,
                   previous.turns.count == 1, previous.turns[0].speaker == turn.speaker,
                   cue.start >= previous.start, cue.start <= previous.end + 0.1 {
                    let priorWords = previous.turns[0].text.split(whereSeparator: \.isWhitespace).map(String.init)
                    let overlap = overlapCount(priorWords, words)
                    // Exact repeated cues require actual time overlap; partial
                    // rolling suffixes need two words, or one during overlap.
                    let isDuplicate = overlap == words.count
                    if (isDuplicate && cue.start < previous.end) ||
                        (!isDuplicate && (overlap >= 2 || (overlap == 1 && cue.start < previous.end))) {
                        words.removeFirst(overlap)
                    }
                }
                let text = words.joined(separator: " ")
                guard !text.isEmpty else {
                    if !passages.isEmpty { passages[passages.count - 1].lineEnd = cue.lineEnd }
                    continue
                }
                let last = passages.last
                // Paragraphs end on a speaker change, >=5s silence, a clock
                // reset, or after 30s at a cue boundary. The active splitter
                // still owns final chunk size and overlap.
                let newPassage = last == nil || last?.speaker != turn.speaker ||
                    turnIndex > 0 || (previous.map { cue.start - $0.end >= 5 || cue.start < $0.start } ?? false) ||
                    (last.map { cue.start - $0.start >= 30 } ?? false)
                if newPassage {
                    let label = turn.speaker.map { $0 + ": " } ?? ""
                    passages.append(Passage(text: label + text, lineStart: cue.lineStart,
                                            lineEnd: cue.lineEnd, start: cue.start, speaker: turn.speaker))
                } else {
                    passages[passages.count - 1].text += " " + text
                    passages[passages.count - 1].lineEnd = cue.lineEnd
                }
            }
            previous = cue
        }
        return Document(passages: passages, lineCount: lineCount)
    }

    private static func isBlock(_ line: String, named name: String) -> Bool {
        line == name || line.hasPrefix(name + " ") || line.hasPrefix(name + "\t")
    }

    private static func times(_ line: String) -> (Double, Double)? {
        guard let match = timing.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line),
              let start = seconds(String(line[first])), let end = seconds(String(line[second])) else { return nil }
        return (start, end)
    }

    private static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let minutes = Double(parts[parts.count - 2]), minutes < 60,
              let seconds = Double(parts[parts.count - 1]), seconds < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func cueText(_ payload: String) -> [Turn] {
        var turns: [Turn] = []
        var speaker: String?
        var buffer = ""
        var cursor = payload.startIndex
        func flush() {
            let text = decode(buffer).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { turns.append(Turn(speaker: speaker, text: text)) }
            buffer = ""
        }
        for match in tag.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)) {
            guard let range = Range(match.range, in: payload),
                  let inner = Range(match.range(at: 1), in: payload) else { continue }
            buffer += payload[cursor..<range.lowerBound]
            let value = String(payload[inner])
            let name = value.prefix { !$0.isWhitespace && $0 != "." }
            if name == "v" {
                flush()
                // Classes belong to the tag, annotation after whitespace is
                // the visible voice name. Decode only after parsing markup.
                let annotation = value.drop { !$0.isWhitespace }
                let label = decode(String(annotation)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                speaker = label.isEmpty ? nil : label
            } else if value == "/v" {
                flush()
                speaker = nil
            } else if name == "br" || value == "br/" {
                buffer += " "
            }
            // Styling, language, ruby wrappers, and inline timestamps have
            // no embedding content. Their inner text survives unchanged.
            cursor = range.upperBound
        }
        buffer += payload[cursor...]
        flush()
        // Adjacent markup spans belonging to one voice are one turn.
        var merged: [Turn] = []
        for turn in turns {
            if let last = merged.last, last.speaker == turn.speaker {
                merged[merged.count - 1] = Turn(speaker: turn.speaker, text: last.text + " " + turn.text)
            } else { merged.append(turn) }
        }
        return merged
    }

    private static func decode(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "nbsp": " ", "lrm": "\u{200E}",
                     "rlm": "\u{200F}", "quot": "\"", "apos": "'"]
        var result = ""
        var cursor = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let key = String(text[inner])
            if let replacement = named[key] { result += replacement }
            else if key.hasPrefix("#") {
                let hex = key.hasPrefix("#x")
                if let value = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   value != 0, let scalar = UnicodeScalar(value) { result.unicodeScalars.append(scalar) }
                else { result += text[range] }
            } else { result += text[range] }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// KMP prefix matching keeps repeated/long rolling cues linear in size.
    private static func overlapCount(_ previous: [String], _ current: [String]) -> Int {
        guard !current.isEmpty else { return 0 }
        var prefix = Array(repeating: 0, count: current.count)
        var length = 0
        for index in current.indices.dropFirst() {
            while length > 0 && current[index] != current[length] { length = prefix[length - 1] }
            if current[index] == current[length] { length += 1 }
            prefix[index] = length
        }
        length = 0
        for word in previous {
            while length > 0 && (length == current.count || word != current[length]) { length = prefix[length - 1] }
            if word == current[length] { length += 1 }
        }
        return length
    }
}
