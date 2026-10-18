import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// iOS writes Android 3.12.1 `Antennapod.db` backups. The schema oracle is a real database pulled from Android
/// 3.12.1 (`TestSupport/Data/android-first-journey/Antennapod.db`); value expectations are hand-written from the
/// Android source, not from the writer.
@Suite(.serialized) struct AndroidDatabaseBackupTests {
    private static let realAndroid = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data/android-first-journey/Antennapod.db").standardized

    private func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseBackup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func rows(_ url: URL, _ sql: String) throws -> [[String]] {
        let db = try BackupSQLite(url: url, create: false); defer { try? db.close() }
        return try db.rows(sql).map { $0.map { value in
            switch value {
            case .integer(let n): String(n)
            case .real(let d): String(d)
            case .text(let s): s ?? "NULL"
            case .null: "NULL"
            }
        } }
    }

    @Test func schemaAndFilePropertiesMatchRealAndroidDatabase() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("AntennaPodBackup.db")
        try AndroidDatabaseBackup.write(.init(feeds: [], queue: []), to: output)
        let query = "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name != 'sqlite_sequence' ORDER BY type, name"
        #expect(try rows(output, query) == rows(Self.realAndroid, query))
        #expect(try rows(output, "PRAGMA user_version") == [["3110000"]])
        #expect(try rows(output, "PRAGMA page_size") == [["4096"]])
        #expect(try rows(output, "PRAGMA encoding") == [["UTF-8"]])
        #expect(try rows(output, "SELECT locale FROM android_metadata") == [["en_US"]])
        let header = try Data(contentsOf: output)
        #expect(header.prefix(16) == Data("SQLite format 3\0".utf8))
        #expect(header[18] == 1 && header[19] == 1, "Rollback journal, not WAL")
        #expect(!FileManager.default.fileExists(atPath: output.path + "-wal") && !FileManager.default.fileExists(atPath: output.path + "-journal"))
    }

    @Test func libraryStateMapsToAndroidColumns() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let published = Date(timeIntervalSince1970: 1_700_000_000.4)
        var parsed = ParsedFeed(format: .atom, identifier: "urn:feed", title: "Original", description: "About", author: "Author",
                                language: "en", link: "https://example.test/", imageURL: "https://example.test/art.png")
        parsed.funding = [.init(url: "https://pay.test", content: "Support"), .init(url: nil, content: "Other")]
        parsed.episodes = [
            .init(identifier: "e1", title: "One", description: "<p>Notes</p>", link: "https://example.test/1", publicationDate: published,
                  imageURL: "https://example.test/1.png", paymentLink: "https://pay.test/1",
                  media: .init(url: "https://cdn.test/1.mp3", size: 1234, mimeType: "audio/mpeg", durationMilliseconds: 600_000),
                  chapters: [.init(startMilliseconds: 0, title: "Intro"), .init(startMilliseconds: 60_000, title: "Part", link: "https://c.test", imageURL: "https://c.test/i.png")],
                  chapterURL: "https://example.test/chapters.json", transcript: .init(format: .vtt, url: "https://example.test/t.vtt"),
                  socialInteractionURL: "https://social.test/1"),
            .init(identifier: "e2", title: "Two", publicationDate: published.addingTimeInterval(-86_400),
                  media: .init(url: "https://cdn.test/2.mp3", size: 99, mimeType: "audio/mpeg", durationMilliseconds: 1_000)),
        ]
        let fetched = FetchedFeed(feed: parsed, source: "https://example.test/feed.xml", responseURL: URL(string: "https://example.test/feed.xml")!, validator: "\"etag-1\"")
        var feed = try await store.insert(fetched)
        let one = try #require(feed.episodes.first { $0.details.identifier == "e1" }).id
        let two = try #require(feed.episodes.first { $0.details.identifier == "e2" }).id
        try await store.updatePreferences(feedID: feed.id) {
            $0.customTitle = "Renamed"; $0.autoDownload = .enabled; $0.keepUpdated = false; $0.tags = ["News", "Tech"]
            $0.autoDelete = .never
            $0.volumeAdaptation = .lightBoost; $0.skip = .init(introSeconds: 12, endingSeconds: 34)
            $0.showEpisodeNotification = true; $0.newEpisodesAction = .queue
            $0.automaticDownloadFilter = .init(include: "keep \"this phrase\"", exclude: "drop", minimumDurationSeconds: 300)
        }
        try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["unplayed", "paused"]))
        try await store.setFeedEpisodeSortOrder(feedID: feed.id, order: .titleAscending)
        try await store.updateEpisode(id: one) {
            $0.userState.playState = .played; $0.userState.isFavorite = true; $0.userState.autoDownloadEnabled = false
            $0.userState.positionMilliseconds = 42_000; $0.userState.playedDurationMilliseconds = 5_000_000_000
            $0.userState.lastPlayedTimeMilliseconds = 1_700_000_100_000; $0.userState.lastPlayedHistoryMilliseconds = 1_700_000_200_000
            $0.userState.isDownloaded = true; $0.userState.localFileURL = "/var/mobile/Containers/Data/x/one.mp3"
            $0.userState.downloadDate = Date(timeIntervalSince1970: 1_700_000_300)
        }
        _ = try await store.enqueue([two, one])
        try await store.updateEpisode(id: two) { $0.userState.playState = .new }
        feed = try #require(try await store.feed(id: feed.id))
        var speeds = PlaybackSpeedPreferences(); speeds.feeds[feed.id] = 1.5; speeds.silence.feeds[feed.id] = .aggressive
        let output = directory.appendingPathComponent("backup.db")
        try AndroidDatabaseBackup.write(.init(feeds: [feed], queue: try await store.queue().map { .init(episodeID: $0.id, feedID: feed.id) },
            credentials: [feed.id: .init(username: "user", password: "secret")], speeds: speeds), to: output)
        // Evidence hook: keep this backup for Android 3.12.1 import proof (runner sets the path).
        if let keep = ProcessInfo.processInfo.environment["DATABASE_BACKUP_KEEP"] {
            try? FileManager.default.removeItem(atPath: keep); try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: keep))
        }

        let f = try #require(try rows(output, "SELECT id,title,custom_title,file_url,download_url,link,description,payment_link,last_update,language,author,image_url,type,feed_identifier,auto_download,username,password,include_filter,exclude_filter,minimal_duration_filter,keep_updated,is_paged,next_page_link,hide,sort_order,last_update_failed,auto_delete_action,feed_playback_speed,feed_skip_silence,feed_volume_adaption,tags,feed_skip_intro,feed_skip_ending,episode_notification,state,new_episodes_action FROM Feeds").first)
        #expect(f == [String(feed.id), "Original", "Renamed", "NULL", "https://example.test/feed.xml", "https://example.test/", "About",
                      "https://pay.test\u{1F}Support\u{1E}null\u{1F}Other", "\"etag-1\"", "en", "Author", "https://example.test/art.png",
                      "atom", "urn:feed", "2", "user", "secret", "keep \"this phrase\"", "drop", "300", "0", "0", "NULL",
                      "unplayed,paused", "3", "0", "2", "1.5", "2", "3", "News\u{1E}Tech", "12", "34", "1", "0", "3"])

        let i = try rows(output, "SELECT id,title,pubDate,read,link,description,payment_link,media,feed,has_simple_chapters,item_identifier,image_url,auto_download,podcastindex_chapter_url,podcastindex_transcript_type,podcastindex_transcript_url,social_interact_url FROM FeedItems ORDER BY id")
        let expectedOne = [String(one), "One", "1700000000400", "1", "https://example.test/1", "<p>Notes</p>", "https://pay.test/1", "NULL",
                           String(feed.id), "1", "e1", "https://example.test/1.png", "0", "https://example.test/chapters.json",
                           "text/vtt", "https://example.test/t.vtt", "https://social.test/1"]
        #expect(i.first { $0[0] == String(one) } == expectedOne)
        #expect(i.first { $0[0] == String(two) }?[3] == "-1", "New episode keeps NEW (-1)")

        let m = try rows(output, "SELECT id,duration,file_url,download_url,downloaded,position,filesize,mime_type,playback_completion_date,feeditem,played_duration,has_embedded_picture,last_played_time FROM FeedMedia WHERE feeditem = \(one)")
        #expect(m == [[String(one), "600000", "NULL", "https://cdn.test/1.mp3", "0", "42000", "1234", "audio/mpeg", "1700000200000",
                       String(one), String(Int32.max), "0", "1700000100000"]], "downloaded on iOS exports as not downloaded; Int32 clamp")
        #expect(try rows(output, "SELECT id,feeditem,feed FROM Queue ORDER BY id") == [["0", String(two), String(feed.id)], ["1", String(one), String(feed.id)]])
        #expect(try rows(output, "SELECT feeditem,feed FROM Favorites") == [[String(one), String(feed.id)]])
        #expect(try rows(output, "SELECT title,start,feeditem,link,image_url FROM SimpleChapters ORDER BY id") == [
            ["Intro", "0", String(one), "NULL", "NULL"], ["Part", "60000", String(one), "https://c.test", "https://c.test/i.png"]])
        try await store.close()
    }

    @Test func defaultFeedPreferencesUseSourceSentinels() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = LibraryFeed(id: 7, source: "antennapod_local:folder", metadata: .init(format: .rss, title: "Local"), episodes: [])
        let output = directory.appendingPathComponent("backup.db")
        try AndroidDatabaseBackup.write(.init(feeds: [feed], queue: []), to: output)
        #expect(try rows(output, "SELECT type,payment_link,feed_playback_speed,feed_skip_silence,tags,hide,sort_order,username,auto_download,downloaded FROM Feeds") ==
                [["NULL", "NULL", "-1.0", "1", "#root", "", "NULL", "NULL", "1", "0"]])
    }

    /// Large library: every feed, episode, media row and queue entry is written, in one consistent file.
    @Test func largeLibraryWritesEveryRow() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        var feeds: [LibraryFeed] = [], queue: [AndroidDatabaseBackup.Source.QueueEntry] = []
        for f in 1...250 {
            let episodes = (1...40).map { e in
                let id = Int64(f * 1_000 + e)
                var state = EpisodeUserState(); state.playedDurationMilliseconds = Int64(e) * 1_000
                return LibraryEpisode(id: id, details: .init(identifier: "f\(f)e\(e)", title: "Episode \(e)",
                    media: .init(url: "https://large.test/\(f)/\(e).mp3", size: 1, mimeType: "audio/mpeg", durationMilliseconds: 60_000)), userState: state)
            }
            feeds.append(LibraryFeed(id: Int64(f), source: "https://large.test/\(f).xml", metadata: .init(format: .rss, title: "Feed \(f)"), episodes: episodes))
            queue.append(.init(episodeID: Int64(f * 1_000 + 1), feedID: Int64(f)))
        }
        let output = directory.appendingPathComponent("large.db")
        try AndroidDatabaseBackup.write(.init(feeds: feeds, queue: queue), to: output)
        #expect(try rows(output, "SELECT count(*) FROM Feeds") == [["250"]])
        #expect(try rows(output, "SELECT count(*), sum(played_duration) FROM FeedMedia") == [["10000", String(250 * (40 * 41 / 2) * 1_000)]])
        #expect(try rows(output, "SELECT count(*) FROM FeedItems i JOIN FeedMedia m ON m.feeditem = i.id AND m.id = i.id") == [["10000"]])
        #expect(try rows(output, "SELECT count(*), min(id), max(id) FROM Queue") == [["250", "0", "249"]])
        #expect(try rows(output, "PRAGMA integrity_check") == [["ok"]])
    }

    @Test func refusesExistingDestinationWithoutTouchingIt() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.db")
        try Data("keep".utf8).write(to: output)
        #expect(throws: AndroidDatabaseBackup.Failure.destinationExists) { try AndroidDatabaseBackup.write(.init(feeds: [], queue: []), to: output) }
        #expect(try Data(contentsOf: output) == Data("keep".utf8))
    }
}
