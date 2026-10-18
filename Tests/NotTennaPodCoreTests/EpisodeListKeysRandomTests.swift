import Foundation
import Testing
@testable import NotTennaPodCore

/// 20,000 random records (optional fields present and absent; dates negative, sub-millisecond, exactly half a
/// millisecond and huge; titles with quotes, backslashes, slashes, control and non-BMP characters; media present or
/// absent; download dates nil, zero, negative or positive) keyed by the triggers and by the fill: both equal the Swift
/// reference, and random updates, moves and deletions keep keys and counts exact.
@Suite(.serialized) struct EpisodeListKeysRandomTests {
    struct Generator {
        var random = LargeAndroidLibrary.Random(state: 0x5EED_2026_1014)

        mutating func chance(_ oneIn: Int) -> Bool { random.chance(oneIn) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { random.int(range) }
        mutating func int64(_ range: ClosedRange<Int64>) -> Int64 {
            range.lowerBound &+ Int64(bitPattern: random.next() % UInt64(bitPattern: range.upperBound &- range.lowerBound &+ 1))
        }
        mutating func double(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * Double(random.next() >> 11) / Double(1 << 53)
        }

        static let pieces = ["word", "\"quoted\"", "back\\slash", "a/b", "//", "\u{1}", "\u{1F}", "\n\t", "\u{7F}", "\u{2028}", "\u{2029}",
                             "😀", "𝄞", "é", "e\u{301}", "ß", "İ", "", " ", "null", "{\"x\":1}", "\u{FEFF}", "\u{0}", "日本語"]

        mutating func text() -> String {
            (0..<int(0...5)).map { _ in Self.pieces[int(0...(Self.pieces.count - 1))] }.joined()
        }

        /// Seconds since 2001 whose list key lands exactly on half a millisecond, positive or negative.
        mutating func halfMillisecond() -> Double {
            while true {
                let milliseconds = Double(int64(-60_000_000_000_000...60_000_000_000_000))
                var reference = (milliseconds + 0.5) / 1_000 - 978_307_200
                for _ in 0..<4 {
                    let x = (reference + 978_307_200) * 1_000
                    if x - x.rounded(.down) == 0.5 { return reference }
                    reference = chance(2) ? reference.nextUp : reference.nextDown
                }
            }
        }

        mutating func date() -> Date? {
            switch int(0...7) {
            case 0: return nil
            case 1: return Date(timeIntervalSinceReferenceDate: double(-3e9...3e9))
            case 2: return Date(timeIntervalSinceReferenceDate: Double(int64(-2_000_000_000...2_000_000_000)) + double(0...0.000999))
            case 3: return Date(timeIntervalSinceReferenceDate: halfMillisecond())
            case 4: return Date(timeIntervalSinceReferenceDate: double(-1e11...1e11))
            case 5: return Date(timeIntervalSinceReferenceDate: -978_307_200 + double(-0.002...0.002))
            case 6: return Date(timeIntervalSinceReferenceDate: Double(int64(-1_000_000...1_000_000)))
            default: return Date(timeIntervalSince1970: Double(int64(0...2_000_000_000_000)) / 1_000)
            }
        }

        mutating func episode(id: Int64) -> LibraryEpisode {
            var details = ParsedEpisode()
            details.identifier = chance(5) ? nil : text() + "\(id)"
            details.title = chance(6) ? nil : text()
            details.description = chance(3) ? nil : String(repeating: "notes ", count: int(0...40))
            details.link = chance(2) ? nil : "https://example.test/\(id)"
            details.publicationDate = date()
            if !chance(4) {
                var media = ParsedMedia(url: chance(8) ? nil : "https://media.example.test/\(text())/\(id).mp3", size: int64(-5...5_000_000_000))
                media.durationMilliseconds = Int32(truncatingIfNeeded: int64(-10...200_000_000))
                media.mimeType = chance(2) ? "audio/mpeg" : nil
                media.hasEmbeddedPicture = chance(3) ? nil : chance(2)
                details.media = media
            }
            var state = EpisodeUserState()
            state.playState = EpisodePlayState.allCases[int(0...2)]
            state.isFavorite = chance(4)
            state.autoDownloadEnabled = !chance(5)
            state.positionMilliseconds = Int32(truncatingIfNeeded: int64(-5...10_000_000))
            state.playedDurationMilliseconds = int64(-5...100_000_000)
            state.lastPlayedTimeMilliseconds = chance(3) ? 0 : int64(-1_000...2_000_000_000_000)
            state.lastPlayedHistoryMilliseconds = chance(2) ? nil : [0, -1, int64(1...2_000_000_000_000)][int(0...2)]
            state.isDownloaded = chance(3)
            state.downloadDate = [nil, Date(timeIntervalSinceReferenceDate: 0), Date(timeIntervalSinceReferenceDate: -double(1...1e9)),
                                  Date(timeIntervalSinceReferenceDate: double(0...1e9))][int(0...3)]
            // A file path never holds NUL (POSIX), which SQLite's text functions treat as the string's end.
            let file = text().replacingOccurrences(of: "\u{0}", with: "")
            state.localFileURL = [nil, "", "/var/media/\(file)\(id).mp3", "plain\(file)\(id)", "/trailing/\(id)/", "/a/./b/../c.mp3"][int(0...5)]
            state.playedHereMilliseconds = chance(3) ? int64(0...1_000) : nil
            return LibraryEpisode(id: id, details: details, userState: state, hasStoredChapters: chance(5))
        }
    }

    @Test func twentyThousandRandomRecordsMatchTheReferenceThroughTriggersAndFill() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        var feeds: [Int64] = []
        for number in 0..<6 {
            let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/r\(number).xml", title: "R\(number)", count: 1),
                                              options: .init(now: EpisodeListKeysTests.now))
            feeds.append(feed.id)
        }
        try await store.updatePreferences(feedID: feeds[4]) { $0.subscriptionState = .archived }
        try await store.close()
        var generator = Generator()
        var episodes: [LibraryEpisode] = []
        var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
        for index in 0..<20_000 {
            let episode = generator.episode(id: 1_000_000 + Int64(index))
            episodes.append(episode)
            statements.append(("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)",
                               [.integer(episode.id), .integer(feeds[index % feeds.count]), .blob(try DerivedDataOracle.record(episode))]))
            if index % 9 == 0 { statements.append(("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(episode.id), .integer(feeds[index % feeds.count])])) }
        }
        statements.append(("COMMIT", []))
        try DerivedDataOracle.write(url, statements)
        try EpisodeListKeysTests.expectExact(url, "inserted")
        let halves = episodes.filter { episode in
            guard let date = episode.details.publicationDate else { return false }
            let x = date.timeIntervalSince1970 * 1_000
            return x - x.rounded(.down) == 0.5
        }
        #expect(halves.count > 1_000 && halves.contains { $0.details.publicationDate!.timeIntervalSince1970 < 0 }, "exact halves both sides of 1970")
        // Random updates (record-only and upsert forms), moves, reveals and deletions.
        statements = [("BEGIN", [])]
        for index in stride(from: 0, to: 20_000, by: 3) {
            var episode = episodes[index]
            let fresh = generator.episode(id: episode.id)
            switch generator.int(0...4) {
            case 0: episode.userState = fresh.userState
            case 1: episode.details = fresh.details
            case 2: episode = fresh
            case 3: statements.append(("UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(feeds[generator.int(0...5)]), .integer(episode.id)])); continue
            default:
                statements.append(generator.chance(2) ? ("DELETE FROM episodes WHERE id = ?", [.integer(episode.id)])
                                  : ("DELETE FROM ntp_hidden_episodes WHERE episode_id = ?", [.integer(episode.id)]))
                continue
            }
            statements.append(generator.chance(2)
                ? ("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try DerivedDataOracle.record(episode)), .integer(episode.id)])
                : ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, (SELECT feed_id FROM episodes WHERE id = ?1), 1, ?) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record",
                   [.integer(episode.id), .blob(try DerivedDataOracle.record(episode))]))
        }
        statements.append(("COMMIT", []))
        try DerivedDataOracle.write(url, statements)
        try EpisodeListKeysTests.expectExact(url, "updated")
        // The fill computes the same rows: every key and count taken out and filled again.
        let triggered = try DerivedDataOracle.storedKeys(url), counted = try DerivedDataOracle.storedCounts(url)
        try RawLibrary.execute(url, "DELETE FROM episode_list_keys; DELETE FROM feed_list_counts; INSERT INTO derived_fill(id, next_id, end_id) VALUES (1, 0, (SELECT max(id) FROM episodes))")
        let refill = try FeedLibraryStore(url: url)
        #expect(!refill.derivedReady)
        try await refill.fillDerivedData(batch: 3_000)
        #expect(try DerivedDataOracle.storedKeys(url) == triggered)
        #expect(try DerivedDataOracle.storedCounts(url) == counted)
        try EpisodeListKeysTests.expectExact(url, "filled")
        try await refill.close()
    }
}
