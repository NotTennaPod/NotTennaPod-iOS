import Foundation
@testable import NotTennaPodCore

/// Reconstruct the exact pre-periodic schema before the existing older-version
/// fixtures remove their later tables. Never discard pending manual records.
func restoreRefreshSchemaEleven(_ database: LibrarySQLite) throws {
    try database.transaction {
        try database.execute("DROP TABLE episode_swipe_undo")
        try database.execute("DROP TABLE imported_download_log"); try database.execute("DROP TABLE restore_journal")
        try database.execute("CREATE TABLE manual_feed_refresh (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)")
        try database.execute("INSERT INTO manual_feed_refresh SELECT * FROM feed_refresh_request WHERE id = 1")
        try database.execute("CREATE TABLE attempt_old (id INTEGER PRIMARY KEY CHECK(id = 1) REFERENCES manual_feed_refresh(id) ON DELETE CASCADE, record BLOB NOT NULL)")
        try database.execute("INSERT INTO attempt_old SELECT * FROM episode_notification_attempt WHERE id = 1")
        try database.execute("CREATE TABLE work_old (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, request_slot INTEGER NOT NULL CHECK(request_slot = 1) REFERENCES manual_feed_refresh(id) ON DELETE CASCADE, record BLOB NOT NULL)")
        try database.execute("INSERT INTO work_old SELECT * FROM episode_notification_work WHERE request_slot = 1")
        try database.execute("DROP TABLE episode_notification_work")
        try database.execute("DROP TABLE episode_notification_attempt")
        try database.execute("DROP TABLE feed_refresh_request")
        try database.execute("DROP TABLE periodic_feed_schedule")
        try database.execute("ALTER TABLE attempt_old RENAME TO episode_notification_attempt")
        try database.execute("ALTER TABLE work_old RENAME TO episode_notification_work")
        try database.execute("PRAGMA user_version = 11")
    }
}
