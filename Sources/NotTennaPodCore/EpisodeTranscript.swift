import Foundation

public struct TranscriptSegment: Equatable, Codable, Sendable {
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public var words: String
    public var speaker: String

    public init(startMilliseconds: Int64, endMilliseconds: Int64, words: String, speaker: String = "") {
        self.startMilliseconds = startMilliseconds; self.endMilliseconds = endMilliseconds
        self.words = words; self.speaker = speaker
    }
}

/// Parsed, ordered content. Selection/follow state belongs to the transcript screen.
public struct EpisodeTranscript: Equatable, Sendable {
    public let segments: [TranscriptSegment]
    public let speakers: Set<String>

    public init(segments: [TranscriptSegment], speakers: Set<String>) throws {
        guard !segments.isEmpty,
              zip(segments, segments.dropFirst()).allSatisfy({ $0.startMilliseconds < $1.startMilliseconds }) else {
            throw TranscriptParseError.invalidSegments
        }
        self.segments = segments; self.speakers = speakers
    }

    /// The source keeps the preceding segment highlighted through gaps and chooses
    /// the first one before its start. Empty content is rejected during parsing.
    public func segmentIndex(at milliseconds: Int64) -> Int {
        var lower = 0, upper = segments.count - 1
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if segments[middle].startMilliseconds > milliseconds { upper = middle - 1 }
            else { lower = middle }
        }
        return lower
    }

    public func timecodeHeading(at index: Int) -> String? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let time = Self.timecode(segment.startMilliseconds)
        if !segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if index > 0 && segments[index - 1].speaker == segment.speaker { return nil }
            return time + " • " + segment.speaker
        }
        return speakers.isEmpty && index.isMultiple(of: 5) ? time : nil
    }

    public func selectedText(indices: Set<Int>) -> String {
        var result = "", lastSpeaker: String?, previous: Int?
        for index in indices.sorted() where segments.indices.contains(index) {
            if let previous, index != previous + 1 { result += "\n[...]\n" }
            let segment = segments[index]
            if !segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lastSpeaker != segment.speaker { result += "\n" + segment.speaker + " : "; lastSpeaker = segment.speaker }
            } else { lastSpeaker = nil }
            if !result.isEmpty && !result.hasSuffix(" ") { result += " " }
            result += segment.words
            previous = index
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timecode(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

public enum TranscriptParseError: Error, Equatable, Sendable { case invalidSegments, invalidDocument }
