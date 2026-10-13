import Foundation
import SwiftSoup

/// The release's format-specific grouping rules are observable in playback seeking
/// and copy selection. Do not replace them with one generic five-second chunker.
public enum TranscriptParser {
    public static func parse(_ text: String, format: FeedTranscript.Format) throws -> EpisodeTranscript {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptParseError.invalidDocument }
        switch format {
        case .json: return try json(text)
        case .vtt: return try vtt(text)
        case .srt: return try srt(text)
        }
    }

    private static func trim(_ text: String) -> String { JavaString.trim(text) }
    private static func result(_ segments: [TranscriptSegment], _ speakers: Set<String>) throws -> EpisodeTranscript {
        try EpisodeTranscript(segments: segments, speakers: speakers)
    }

    private static func json(_ text: String) throws -> EpisodeTranscript {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let values = root["segments"] as? [[String: Any]] else { throw TranscriptParseError.invalidDocument }
        func number(_ value: Any?) -> Int64? {
            let seconds: Double?
            if let value = value as? String { seconds = Double(value) }
            else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { seconds = value.doubleValue }
            else { seconds = nil }
            guard let seconds, seconds.isFinite, seconds >= 0, seconds * 1000 < Double(Int64.max) else { return nil }
            return Int64(seconds * 1000)
        }
        var segments: [TranscriptSegment] = [], speakers = Set<String>()
        var spanStart: Int64 = -1, end: Int64 = -1, duration: Int64 = 0
        var speaker = "", body = ""
        for (index, value) in values.enumerated() {
            let previousEnd = end
            guard let start = number(value["startTime"]), let nextEnd = number(value["endTime"]) else { continue }
            end = nextEnd
            if spanStart == -1 { spanStart = start }
            let delta = end.subtractingReportingOverflow(start)
            let sum = duration.addingReportingOverflow(delta.partialValue)
            guard !delta.overflow && !sum.overflow else { throw TranscriptParseError.invalidSegments }
            duration = sum.partialValue
            let previousSpeaker = speaker
            speaker = value["speaker"] as? String ?? ""
            speakers.insert(speaker)
            if speaker.isEmpty && !previousSpeaker.isEmpty { speaker = previousSpeaker }
            let words = value["body"] as? String ?? ""
            if previousSpeaker != speaker && !body.isEmpty {
                segments.append(.init(startMilliseconds: spanStart, endMilliseconds: previousEnd, words: trim(body), speaker: previousSpeaker))
                spanStart = start; body = words; duration = 0
                continue
            }
            body += " " + words
            if duration >= 5000 {
                if index + 1 < values.count, duration < 8000,
                   let first = (values[index + 1]["body"] as? String)?.unicodeScalars.first,
                   !CharacterSet.alphanumerics.contains(first) { continue }
                segments.append(.init(startMilliseconds: spanStart, endMilliseconds: end, words: trim(body), speaker: speaker))
                duration = 0; body = ""; spanStart = -1
            }
        }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.init(startMilliseconds: spanStart, endMilliseconds: end, words: trim(body), speaker: speaker))
        }
        return try result(segments, speakers)
    }

    private static let vttTime = try! NSRegularExpression(pattern: #"^(?:([0-9]{1,2}):)?([0-9]{2}):([0-9]{2})\.([0-9]{3})$"#)
    private static let srtTime = try! NSRegularExpression(pattern: #"^([0-9]{2}):([0-9]{2}):([0-9]{2}),([0-9]{3})$"#)
    private static let voice = try! NSRegularExpression(pattern: #"<v(?:\.[^\t\n\r &<>.]+)*[ \t]([^\n\r&>]+)>"#)
    private static func time(_ text: String, regex: NSRegularExpression) -> Int64? {
        let text = text as NSString
        guard let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
        let values = (1...4).map { index -> Int64 in
            let range = match.range(at: index)
            return range.location == NSNotFound ? 0 : Int64(text.substring(with: range)) ?? 0
        }
        return values[0] * 3_600_000 + values[1] * 60_000 + values[2] * 1000 + values[3]
    }

    private static func vtt(_ text: String) throws -> EpisodeTranscript {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var segments: [TranscriptSegment] = [], speakers = Set<String>(), speaker = ""
        var candidate: TranscriptSegment?, index = 0
        while index < lines.count {
            let line = lines[index]; index += 1
            guard line.contains("-->") else { continue }
            let parts = line.components(separatedBy: "-->")
            guard parts.count >= 2, let start = time(trim(parts[0]), regex: vttTime),
                  let endText = trim(parts[1]).split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let end = time(String(endText), regex: vttTime) else { throw TranscriptParseError.invalidDocument }
            var payload: [String] = []
            while index < lines.count && !lines[index].isEmpty { payload.append(lines[index].trimmingCharacters(in: .whitespacesAndNewlines)); index += 1 }
            let raw = payload.joined(separator: " ")
            if let match = voice.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let range = Range(match.range(at: 1), in: raw) {
                speaker = String(raw[range]); speakers.insert(speaker)
            }
            let words = HTMLNesting.exceeds(raw) ? HTMLNesting.plainText(raw, compact: true).replacingOccurrences(of: "\n", with: " ")
                : try SwiftSoup.parse(raw).text()
            if let old = candidate, old.speaker == speaker, end - old.startMilliseconds < 8000 {
                candidate?.endMilliseconds = end; candidate?.words += " " + words
            } else {
                if let candidate { segments.append(candidate) }
                candidate = .init(startMilliseconds: start, endMilliseconds: end, words: words, speaker: speaker)
            }
            if let value = candidate, value.endMilliseconds - value.startMilliseconds >= 5000 { segments.append(value); candidate = nil }
        }
        if let candidate { segments.append(candidate) }
        return try result(segments, speakers)
    }

    private static func srt(_ text: String) throws -> EpisodeTranscript {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var segments: [TranscriptSegment] = [], speakers = Set<String>()
        var speaker = "", previousSpeaker = "", spanBody = ""
        var spanStart: Int64 = -1, end: Int64 = -1, duration: Int64 = 0, index = 0
        while index < lines.count {
            let line = lines[index]; index += 1
            guard line.contains("-->") else { continue }
            let parts = line.components(separatedBy: "-->")
            let previousEnd = end
            guard parts.count >= 2, let start = time(trim(parts[0]), regex: srtTime),
                  let nextEnd = time(trim(parts[1]), regex: srtTime) else { continue }
            end = nextEnd
            if spanStart == -1 { spanStart = start }
            duration += end - start
            var linesOfBody: [String] = []
            while index < lines.count {
                let next = lines[index]; index += 1
                if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                linesOfBody.append(next.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !linesOfBody.isEmpty else { throw TranscriptParseError.invalidDocument }
            var body = linesOfBody.joined(separator: " ")
            if let separator = body.range(of: ": ") {
                previousSpeaker = speaker
                speaker = String(body[..<separator.lowerBound]); speakers.insert(speaker)
                // Preserve text after the first speaker delimiter, including further colons.
                body = String(body[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !previousSpeaker.isEmpty && speaker != previousSpeaker && !spanBody.isEmpty {
                    segments.append(.init(startMilliseconds: spanStart, endMilliseconds: previousEnd, words: spanBody, speaker: previousSpeaker))
                    duration = 0; spanStart = start; spanBody = body; continue
                }
            }
            spanBody = trim(spanBody + " " + body)
            if duration >= 5000 && end > spanStart {
                segments.append(.init(startMilliseconds: spanStart, endMilliseconds: end, words: spanBody, speaker: speaker))
                duration = 0; spanStart = -1; spanBody = ""
            }
        }
        if !spanBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && end > spanStart {
            segments.append(.init(startMilliseconds: spanStart, endMilliseconds: end, words: trim(spanBody), speaker: speaker))
        }
        return try result(segments, speakers)
    }
}
