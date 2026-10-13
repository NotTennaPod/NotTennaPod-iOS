/// Chapter source priority and metadata enrichment. A nil list is still unloaded
/// or unavailable; an empty list is a completed load with no chapters.
public enum ChapterMerger {
    public static func merge(_ first: [ParsedChapter]?, _ second: [ParsedChapter]?) -> [ParsedChapter]? {
        guard let first else { return second }
        guard var second else { return first }
        if first.count != second.count { return first.count > second.count ? first : second }
        for index in second.indices {
            let difference = second[index].startMilliseconds.subtractingReportingOverflow(first[index].startMilliseconds)
            // Extreme malformed offsets must not overflow into an apparent match.
            if difference.overflow || difference.partialValue < -1000 || difference.partialValue > 1000 {
                return metadataScore(first) > metadataScore(second) ? first : second
            }
            // The source fills entries as it visits them, before a possible later
            // mismatch. Its score comparison includes those enriched entries.
            if second[index].imageURL?.isEmpty != false { second[index].imageURL = first[index].imageURL }
            if second[index].link?.isEmpty != false { second[index].link = first[index].link }
            if second[index].title?.isEmpty != false { second[index].title = first[index].title }
        }
        return second
    }

    private static func metadataScore(_ chapters: [ParsedChapter]) -> Int {
        chapters.reduce(0) { score, chapter in
            score + [chapter.title, chapter.link, chapter.imageURL].filter { $0?.isEmpty == false }.count
        }
    }
}

public enum ChapterPlaybackRules {
    /// Preserve supplied order. In particular, external JSON order is not
    /// sorted by the source parser. Equal start times choose the last equal item.
    public static func currentIndex(in chapters: [ParsedChapter]?, positionMilliseconds: Int64) -> Int {
        guard let chapters, !chapters.isEmpty else { return -1 }
        for index in chapters.indices where chapters[index].startMilliseconds > positionMilliseconds { return index - 1 }
        return chapters.count - 1
    }

    /// Previous/next are seeks and preserve playback intent. Playing a chapter
    /// from the chapter dialog is a separate action that starts playback.
    public static func previousStart(in chapters: [ParsedChapter], displayedIndex: Int,
                                     positionMilliseconds: Int64, speed: Float) -> Int64? {
        guard chapters.indices.contains(displayedIndex) else { return nil }
        guard displayedIndex > 0 else { return 0 }
        let current = chapters[displayedIndex].startMilliseconds
        // The active Media3 callback performs Float arithmetic, including the
        // position conversion and the strict boundary at ten playback seconds.
        if Float(positionMilliseconds) - 10_000 * speed < Float(current) {
            return chapters[displayedIndex - 1].startMilliseconds
        }
        return current
    }

    public static func nextStart(in chapters: [ParsedChapter], displayedIndex: Int) -> Int64? {
        guard chapters.indices.contains(displayedIndex), displayedIndex < chapters.count - 1 else { return nil }
        return chapters[displayedIndex + 1].startMilliseconds
    }
}
