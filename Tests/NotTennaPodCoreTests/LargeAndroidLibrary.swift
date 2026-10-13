import Foundation
import SQLite3

/// A deterministic, realistically large Android 3.12.1 library.
///
/// The schema is the one the Android 3.12.1 app wrote itself (`emulator-parity-library.db`, see
/// `TestSupport/Data/database-restore/android-3.12.1/`): the file is copied, emptied and
/// refilled, so the result is an Android-schema backup that only the real restore can import.
/// Every expected value in `Summary` comes from the generated rows, never from the Swift reader.
enum LargeAndroidLibrary {
    static let androidFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data/database-restore/android-3.12.1/emulator-parity-library.db")
        .standardized

    struct Shape: Sendable {
        var feeds = 500
        var episodes = 50_000
        /// Feeds 0..<heavyFeeds carry `heavyEpisodes` each (long-running shows), the next
        /// `mediumFeeds` carry `mediumEpisodes`, the rest share what remains.
        var heavyFeeds = 10, heavyEpisodes = 1_500
        var mediumFeeds = 100, mediumEpisodes = 200
        var archivedFeeds = 15, previewFeeds = 5
        var queue = 300, favorites = 200
        /// Roughly one episode in this many is New (Inbox) and one in `historyEvery` was completed.
        var newEvery = 45, historyEvery = 10
        var chapteredEpisodes = 1_000, chaptersPerEpisode = 5
        var downloadLog = 2_000
        static let standard = Shape()
    }

    struct Episode: Sendable {
        let id: Int64, feed: Int64, title: String, pubDate: Int64, read: Int, completion: Int64, duration: Int
    }

    struct Summary: Sendable {
        var feedIDs: [Int64] = []
        var subscribedFeedIDs: Set<Int64> = [], archivedFeedIDs: Set<Int64> = [], previewFeedIDs: Set<Int64> = []
        var feedTitles: [Int64: String] = [:]
        var episodes: [Episode] = []
        var queue: [Int64] = []
        var favorites: Set<Int64> = []
        /// A word that occurs in exactly the titles of `searchHits` (subscribed feeds only).
        var searchWord = "", searchHits: [Int64] = []
        var largestFeedID: Int64 = 0

        /// Android's Inbox query: New episodes of subscribed feeds, newest first, equal dates by id.
        var inboxOrder: [Int64] {
            episodes.filter { $0.read == -1 && subscribedFeedIDs.contains($0.feed) }
                .sorted { $0.pubDate == $1.pubDate ? $0.id < $1.id : $0.pubDate > $1.pubDate }.map(\.id)
        }
        /// Android's playback history: completion date, newest first, every feed state.
        var historyOrder: [Int64] {
            episodes.filter { $0.completion > 0 }.sorted { $0.completion == $1.completion ? $0.id < $1.id : $0.completion > $1.completion }.map(\.id)
        }
    }

    /// SplitMix64: fixed seed, identical library on every run and machine.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ oneIn: Int) -> Bool { next() % UInt64(oneIn) == 0 }
    }

    static let words = ("about after again against analysis archive audio author before between book call career chapter city "
        + "climate code community conversation culture daily data design detail development digital discussion economy "
        + "education election energy episode event family feature film food future game garden government guest health "
        + "history home idea industry interview island journey language law leader learning letter library life light "
        + "market media medicine memory method mind money morning mountain movie music nature network news night ocean "
        + "opinion people philosophy planet podcast policy politics power practice president problem program project "
        + "question radio reading report research review river science season series show society software space sport "
        + "story strategy student study system technology theory travel trial truth university update video village "
        + "voice war water weather week winter world writer year").split(separator: " ").map(String.init)

    /// Writes the library to `url` (a new file) and returns what the generated rows contain.
    @discardableResult
    static func write(to url: URL, shape: Shape = .standard, seed: UInt64 = 0x5EED_2026_1001) throws -> Summary {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: androidFixture, to: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "LargeAndroidLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        final class Statement {
            let handle: OpaquePointer
            init(_ db: OpaquePointer, _ sql: String) throws {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw NSError(domain: "LargeAndroidLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
                }
                handle = statement
            }
            deinit { sqlite3_finalize(handle) }
            func run(_ values: [Any?]) throws {
                sqlite3_reset(handle); sqlite3_clear_bindings(handle)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (index, value) in values.enumerated() {
                    let position = Int32(index + 1)
                    switch value {
                    case let value as Int64: sqlite3_bind_int64(handle, position, value)
                    case let value as Int: sqlite3_bind_int64(handle, position, Int64(value))
                    case let value as Double: sqlite3_bind_double(handle, position, value)
                    case let value as String: sqlite3_bind_text(handle, position, value, -1, transient)
                    default: sqlite3_bind_null(handle, position)
                    }
                }
                guard sqlite3_step(handle) == SQLITE_DONE else { throw NSError(domain: "LargeAndroidLibrary", code: 3) }
            }
        }

        try exec("BEGIN")
        for table in ["Feeds", "FeedItems", "FeedMedia", "DownloadLog", "Queue", "SimpleChapters", "Favorites", "sqlite_sequence"] {
            try exec("DELETE FROM \(table)")
        }
        let feedInsert = try Statement(db, """
            INSERT INTO Feeds (id, title, custom_title, file_url, download_url, downloaded, link, description, payment_link, last_update,
              language, author, image_url, type, feed_identifier, auto_download, username, password, include_filter, exclude_filter,
              minimal_duration_filter, keep_updated, is_paged, next_page_link, hide, sort_order, last_update_failed, auto_delete_action,
              feed_playback_speed, feed_skip_silence, feed_volume_adaption, tags, feed_skip_intro, feed_skip_ending,
              episode_notification, state, new_episodes_action)
            VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, NULL, ?, 'en', ?, ?, ?, NULL, 1, NULL, NULL, '', '', -1, 1, 0, NULL, ?, NULL, 0, 0,
              -1.0, 1, 0, ?, 0, 0, 0, ?, 0)
            """)
        let itemInsert = try Statement(db, """
            INSERT INTO FeedItems (id, title, pubDate, read, link, description, payment_link, media, feed, has_simple_chapters,
              item_identifier, image_url, auto_download, podcastindex_chapter_url, podcastindex_transcript_type,
              podcastindex_transcript_url, social_interact_url)
            VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, NULL, 1, NULL, NULL, NULL, NULL)
            """)
        let mediaInsert = try Statement(db, """
            INSERT INTO FeedMedia (id, duration, file_url, download_url, downloaded, position, filesize, mime_type,
              playback_completion_date, feeditem, played_duration, has_embedded_picture, last_played_time)
            VALUES (?, ?, NULL, ?, 0, ?, ?, 'audio/mpeg', ?, ?, ?, 0, ?)
            """)
        let chapterInsert = try Statement(db, "INSERT INTO SimpleChapters (title, start, feeditem, link, image_url) VALUES (?, ?, ?, NULL, NULL)")
        let queueInsert = try Statement(db, "INSERT INTO Queue (id, feeditem, feed) VALUES (?, ?, ?)")
        let favoriteInsert = try Statement(db, "INSERT INTO Favorites (id, feeditem, feed) VALUES (?, ?, ?)")
        let logInsert = try Statement(db, """
            INSERT INTO DownloadLog (feedfile, feedfile_type, reason, successful, completion_date, reason_detailed, title)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)

        var random = Random(state: seed)
        var summary = Summary()
        func sentence(_ range: ClosedRange<Int>) -> String {
            (0..<random.int(range)).map { _ in words[random.int(0...(words.count - 1))] }.joined(separator: " ")
        }
        // Episode counts per feed: a few very long shows, many medium, the rest small.
        let remainingFeeds = shape.feeds - shape.heavyFeeds - shape.mediumFeeds
        let remaining = shape.episodes - shape.heavyFeeds * shape.heavyEpisodes - shape.mediumFeeds * shape.mediumEpisodes
        precondition(remainingFeeds > 0 && remaining >= remainingFeeds)
        var counts = Array(repeating: shape.heavyEpisodes, count: shape.heavyFeeds)
            + Array(repeating: shape.mediumEpisodes, count: shape.mediumFeeds)
            + (0..<remainingFeeds).map { remaining / remainingFeeds + ($0 < remaining % remainingFeeds ? 1 : 0) }
        // Feed ids are not in title order and not dense, like a library that has seen deletions.
        var feedIDs = (0..<shape.feeds).map { Int64($0 * 3 + 7) }
        for index in feedIDs.indices.reversed() { feedIDs.swapAt(index, random.int(0...index)) }
        for index in counts.indices.reversed() { counts.swapAt(index, random.int(0...index)) }
        summary.largestFeedID = feedIDs[counts.firstIndex(of: counts.max()!)!]
        let now: Int64 = 1_790_000_000_000
        let searchWord = "zyxwvut"
        var episodeID: Int64 = 0, mediaID: Int64 = 0
        let tagNames = ["News", "Science", "Comedy", "History", "Technology", "Sport"]
        for (index, feedID) in feedIDs.enumerated() {
            let state = index < shape.archivedFeeds ? 2 : index < shape.archivedFeeds + shape.previewFeeds ? 1 : 0
            let title = "\(words[random.int(0...(words.count - 1))].capitalized) \(sentence(1...4)) \(feedID)"
            let tags = random.chance(3) ? tagNames[random.int(0...(tagNames.count - 1))] + "\u{1E}" + "#root" : "#root"
            try feedInsert.run([feedID, title, "https://large.test/feeds/\(feedID).xml", now - Int64(random.int(0...86_400_000)),
                                "https://large.test/shows/\(feedID)", sentence(20...80), "Mon, 14 Sep 2026 15:04:22 GMT",
                                sentence(2...3).capitalized, "https://large.test/art/\(feedID).png", random.chance(10) ? "atom" : "rss",
                                "", tags, state])
            summary.feedIDs.append(feedID); summary.feedTitles[feedID] = title
            switch state {
            case 0: summary.subscribedFeedIDs.insert(feedID)
            case 1: summary.previewFeedIDs.insert(feedID)
            default: summary.archivedFeedIDs.insert(feedID)
            }
            let span = Int64(random.int(1...15)) * 365 * 86_400_000
            for number in 0..<counts[index] {
                episodeID += 1; mediaID += 1
                // Older episodes first, roughly evenly spaced, with a few identical dates.
                let pubDate = now - span + span * Int64(number) / Int64(max(1, counts[index])) - Int64(random.int(0...3_600_000)) / 1000 * 1000
                let read = random.chance(shape.newEvery) ? -1 : random.chance(2) ? 1 : 0
                var title = "\(number + 1). \(sentence(3...9).capitalized)"
                if summary.searchHits.count < 7, state == 0, random.chance(997) { title += " \(searchWord)"; summary.searchHits.append(episodeID) }
                let description = "<p>" + sentence(30...330) + "</p>"
                let chaptered = episodeID % Int64(max(1, shape.episodes / max(1, shape.chapteredEpisodes))) == 0
                try itemInsert.run([episodeID, title, pubDate, read, "https://large.test/shows/\(feedID)/\(number)", description,
                                    feedID, chaptered ? 1 : 0, "guid-\(feedID)-\(number)"])
                let duration = random.int(5...150) * 60_000 + random.int(0...59_999)
                let completion: Int64 = read == 1 && random.chance(max(1, shape.historyEvery / 2)) ? pubDate + Int64(random.int(1...30)) * 86_400_000 : 0
                let position = read == 0 && random.chance(20) ? random.int(1_000...(duration - 1)) : 0
                try mediaInsert.run([mediaID, duration, "https://large.test/media/\(feedID)/\(number).mp3", position,
                                     Int64(duration) * 16, completion, episodeID, completion > 0 ? duration : position,
                                     completion > 0 ? completion : 0])
                if chaptered {
                    for chapter in 0..<shape.chaptersPerEpisode {
                        try chapterInsert.run(["Chapter \(chapter + 1)", chapter * duration / shape.chaptersPerEpisode, episodeID])
                    }
                }
                summary.episodes.append(.init(id: episodeID, feed: feedID, title: title, pubDate: pubDate, read: read,
                                              completion: completion, duration: duration))
            }
        }
        summary.searchWord = searchWord
        // Queue: random unplayed-or-new episodes of subscribed feeds; Android stores queue order in Queue.id.
        var queued = Set<Int64>()
        while summary.queue.count < shape.queue {
            let episode = summary.episodes[random.int(0...(summary.episodes.count - 1))]
            guard summary.subscribedFeedIDs.contains(episode.feed), episode.read != 1, queued.insert(episode.id).inserted else { continue }
            try queueInsert.run([summary.queue.count, episode.id, episode.feed])
            summary.queue.append(episode.id)
        }
        while summary.favorites.count < shape.favorites {
            let episode = summary.episodes[random.int(0...(summary.episodes.count - 1))]
            guard summary.favorites.insert(episode.id).inserted else { continue }
            try favoriteInsert.run([summary.favorites.count, episode.id, episode.feed])
        }
        for number in 0..<shape.downloadLog {
            let feedID = feedIDs[random.int(0...(feedIDs.count - 1))]
            let failed = random.chance(4)
            try logInsert.run([feedID, 0, failed ? 11 : 0, failed ? 0 : 1, now - Int64(number) * 600_000,
                               failed ? "Unable to resolve host" : nil, summary.feedTitles[feedID]])
        }
        try exec("COMMIT")
        return summary
    }
}
