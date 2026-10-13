import Foundation

/// Port of source `DBUpgrader.upgrade` (storage/database/.../DBUpgrader.java:19–357), run only on the
/// private copy of an imported backup so older Android files reach the 3.12.1 (`3110000`) shape
/// before they are read by column name. Guards, statements and data transformations follow the
/// source in order; the one Android-only step (≤15 `MediaMetadataRetriever` on downloaded files)
/// cannot find Android paths on iOS, so — as on Android for a missing file — those rows keep -1.
enum AndroidDatabaseUpgrader {
    static func upgrade(_ db: BackupSQLite, from old: Int64) throws {
        func run(_ statements: String...) throws { for sql in statements { try db.execute(sql) } }
        if old <= 1 { try run("ALTER TABLE Feeds ADD COLUMN type TEXT") }
        if old <= 2 { try run("ALTER TABLE SimpleChapters ADD COLUMN link TEXT") }
        if old <= 3 { try run("ALTER TABLE FeedItems ADD COLUMN item_identifier TEXT") }
        if old <= 4 { try run("ALTER TABLE Feeds ADD COLUMN feed_identifier TEXT") }
        if old <= 5 {
            try run("ALTER TABLE DownloadLog ADD COLUMN reason_detailed TEXT", "ALTER TABLE DownloadLog ADD COLUMN title TEXT")
        }
        if old <= 6 { try run("ALTER TABLE SimpleChapters ADD COLUMN type INTEGER") }
        if old <= 7 { try run("ALTER TABLE FeedMedia ADD COLUMN playback_completion_date INTEGER") }
        if old <= 8 {
            // DBUpgrader:51–75 selects every item (the bound "? > 0" compares text with 0) and sets
            // FeedMedia.feeditem for its legacy media id, in cursor (rowid) order: the last item wins.
            try run("ALTER TABLE FeedMedia ADD COLUMN feeditem INTEGER",
                    "UPDATE FeedMedia SET feeditem = (SELECT id FROM FeedItems WHERE FeedItems.media = FeedMedia.id ORDER BY rowid DESC LIMIT 1) WHERE EXISTS (SELECT 1 FROM FeedItems WHERE FeedItems.media = FeedMedia.id)")
        }
        if old <= 9 { try run("ALTER TABLE Feeds ADD COLUMN auto_download INTEGER DEFAULT 1") }
        if old <= 10 {
            try run("ALTER TABLE Feeds ADD COLUMN flattr_status INTEGER", "ALTER TABLE FeedItems ADD COLUMN flattr_status INTEGER",
                    "ALTER TABLE FeedMedia ADD COLUMN played_duration INTEGER")
        }
        if old <= 11 {
            try run("ALTER TABLE Feeds ADD COLUMN username TEXT", "ALTER TABLE Feeds ADD COLUMN password TEXT",
                    "ALTER TABLE FeedItems ADD COLUMN image INTEGER")
        }
        if old <= 12 {
            try run("ALTER TABLE Feeds ADD COLUMN is_paged INTEGER DEFAULT 0", "ALTER TABLE Feeds ADD COLUMN next_page_link TEXT")
        }
        if old <= 13 {
            try run("DELETE FROM SimpleChapters WHERE id NOT IN (SELECT MIN(id) as id FROM SimpleChapters GROUP BY title,start,feeditem,link,type)")
        }
        if old <= 14 {
            try run("ALTER TABLE FeedItems ADD COLUMN auto_download INTEGER",
                    "UPDATE FeedItems SET auto_download = (SELECT auto_download FROM Feeds WHERE Feeds.id = FeedItems.feed)",
                    "ALTER TABLE Feeds ADD COLUMN hide TEXT",
                    "ALTER TABLE Feeds ADD COLUMN last_update_failed INTEGER DEFAULT 0",
                    "CREATE INDEX FeedItems_feed ON FeedItems (feed)",
                    "CREATE INDEX FeedMedia_feeditem ON FeedMedia (feeditem)",
                    "CREATE INDEX Queue_feeditem ON Queue (feeditem)",
                    "CREATE INDEX SimpleChapters_feeditem ON SimpleChapters (feeditem)")
        }
        if old <= 15 {
            try run("ALTER TABLE FeedMedia ADD COLUMN has_embedded_picture INTEGER DEFAULT -1",
                    "UPDATE FeedMedia SET has_embedded_picture=0 WHERE downloaded=0")
        }
        if old <= 16 {
            try run("UPDATE FeedItems SET read=-1 WHERE id IN (SELECT FeedItems.id FROM FeedItems INNER JOIN FeedMedia ON FeedItems.id=FeedMedia.feeditem LEFT OUTER JOIN Queue ON FeedItems.id=Queue.feeditem WHERE FeedItems.read = 0 AND FeedMedia.downloaded = 0 AND FeedMedia.position = 0 AND Queue.id IS NULL)")
        }
        if old <= 17 { try run("ALTER TABLE Feeds ADD COLUMN auto_delete_action INTEGER DEFAULT 0") }
        if old < 1_030_005 {
            try run("UPDATE FeedItems SET auto_download=0 WHERE (read=1 OR id IN (SELECT feeditem FROM FeedMedia WHERE position>0 OR downloaded=1)) AND id NOT IN (SELECT feeditem FROM Queue)")
        }
        if old < 1_040_001 { try run("CREATE TABLE Favorites(id INTEGER PRIMARY KEY,feeditem INTEGER,feed INTEGER)") }
        if old < 1_040_002 { try run("ALTER TABLE FeedMedia ADD COLUMN last_played_time INTEGER DEFAULT 0") }
        if old < 1_040_013 {
            try run("CREATE INDEX FeedItems_pubDate ON FeedItems (pubDate)", "CREATE INDEX FeedItems_read ON FeedItems (read)")
        }
        if old < 1_050_003 {
            // Filter token inversion, in the source's exact replace order (DBUpgrader:219–265).
            for (from, to) in [("unplayed", "noplay"), ("not_queued", "noqueue"), ("not_downloaded", "nodl"),
                               ("played", "unplayed"), ("queued", "not_queued"), ("downloaded", "not_downloaded"),
                               ("noplay", "played"), ("noqueue", "queued"), ("nodl", "downloaded"), ("paused", "unplayed")] {
                try run("UPDATE Feeds\nSET hide = replace(hide, '\(from)', '\(to)')")
            }
            try run("ALTER TABLE Feeds ADD COLUMN include_filter TEXT DEFAULT ''",
                    "ALTER TABLE Feeds ADD COLUMN exclude_filter TEXT DEFAULT ''",
                    "ALTER TABLE Feeds ADD COLUMN keep_updated INTEGER DEFAULT 1")
        }
        if old < 1_050_004 { try run("UPDATE Feeds SET last_update=NULL") }
        if old < 1_060_200 { try run("ALTER TABLE Feeds ADD COLUMN custom_title TEXT") }
        if old < 1_060_596 {
            try run("ALTER TABLE Feeds ADD COLUMN image_url TEXT", "ALTER TABLE FeedItems ADD COLUMN image_url TEXT",
                    "UPDATE FeedItems SET image_url  = ( SELECT download_url FROM FeedImages WHERE FeedImages.id = FeedItems.image)",
                    "UPDATE Feeds SET image_url = ( SELECT download_url FROM FeedImages WHERE FeedImages.id = Feeds.image)",
                    "DROP TABLE FeedImages")
        }
        if old < 1_070_400 { try run("ALTER TABLE Feeds ADD COLUMN feed_playback_speed REAL DEFAULT -1.0") }
        if old < 1_070_401 { try run("ALTER TABLE Feeds ADD COLUMN sort_order TEXT") }
        if old < 1_090_000 {
            try run("ALTER TABLE Feeds ADD COLUMN feed_volume_adaption INTEGER DEFAULT 0",
                    "ALTER TABLE SimpleChapters ADD COLUMN image_url TEXT DEFAULT NULL")
        }
        if old < 1_090_001 {
            try run("ALTER TABLE Feeds ADD COLUMN feed_skip_intro INTEGER DEFAULT 0;",
                    "ALTER TABLE Feeds ADD COLUMN feed_skip_ending INTEGER DEFAULT 0;")
        }
        if old < 2_020_000 { try run("ALTER TABLE Feeds ADD COLUMN episode_notification INTEGER DEFAULT 0;") }
        if old < 2_030_000 {
            try run("UPDATE FeedItems SET description = content_encoded, content_encoded = NULL WHERE length(description) < length(content_encoded)",
                    "UPDATE FeedItems SET content_encoded = NULL",
                    "ALTER TABLE Feeds ADD COLUMN tags TEXT;")
        }
        if old < 2_050_000 { try run("ALTER TABLE Feeds ADD COLUMN minimal_duration_filter INTEGER DEFAULT -1") }
        if old < 2_060_000 { try run("ALTER TABLE FeedItems ADD COLUMN podcastindex_chapter_url TEXT") }
        if old < 3_010_000 { try run("ALTER TABLE Feeds ADD COLUMN new_episodes_action INTEGER DEFAULT 0") }
        if old < 3_040_000 { try run("ALTER TABLE Feeds ADD COLUMN feed_skip_silence INTEGER DEFAULT 1") }
        if old < 3_050_000 {
            try run("ALTER TABLE Feeds ADD COLUMN state INTEGER DEFAULT 0",
                    "ALTER TABLE FeedItems ADD COLUMN podcastindex_transcript_url TEXT",
                    "ALTER TABLE FeedItems ADD COLUMN podcastindex_transcript_type TEXT")
        }
        if old < 3_080_000 {
            try run("ALTER TABLE FeedItems ADD COLUMN social_interact_url TEXT",
                    "DELETE FROM Favorites WHERE feeditem NOT IN (SELECT id FROM FeedItems)")
        }
        try run("PRAGMA user_version = \(AndroidDatabaseBackup.version)")
    }
}
