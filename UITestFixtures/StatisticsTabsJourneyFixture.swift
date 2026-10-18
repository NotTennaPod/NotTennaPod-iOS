#if DEBUG
import Foundation
import SQLite3
import Synchronization
import NotTennaPodCore

/// Statistics tabs UI journey only (`-test-seed-android-database <db>` + `-test-seed-android-downloads`, UUID test
/// libraries). The database import brings Android downloads in as not downloaded (their files are Android
/// paths), so the Downloads statistics would start at 0 B. This re-marks the source
/// database's downloaded media (`FeedMedia.downloaded > 0`) as iOS downloads with the stored size and
/// date, once, before the library opens, so the tab shows the oracle's `download_inputs`.
enum StatisticsTabsJourneyFixture {
    struct Download: Sendable { let episodeID: Int64, size: Int64, date: Int64 }

    static func markDownloads(from source: URL, directory: URL) throws {
        let marker = directory.appendingPathComponent("statistics-downloads-seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let downloads = try read(source)
        let files = directory.appendingPathComponent("statistics-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let library = directory.appendingPathComponent("library.sqlite")
        let done = DispatchSemaphore(value: 0)
        let failure = Mutex<(any Error)?>(nil)
        Task.detached {
            do {
                let store = try FeedLibraryStore(url: library)
                for download in downloads {
                    let file = files.appendingPathComponent("\(download.episodeID).mp3")
                    try Data([0]).write(to: file)
                    try await store.updateEpisode(id: download.episodeID) {
                        $0.userState.isDownloaded = true
                        $0.userState.localFileURL = file.path
                        $0.userState.downloadDate = Date(timeIntervalSince1970: Double(download.date) / 1000)
                        $0.details.media?.size = download.size
                    }
                }
                try await store.close()
            } catch { failure.withLock { $0 = error } }
            done.signal()
        }
        done.wait()
        if let error = failure.withLock({ $0 }) { throw error }
        try Data("seeded\n".utf8).write(to: marker, options: .atomic)
    }

    private static func read(_ url: URL) throws -> [Download] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT feeditem, filesize, downloaded FROM FeedMedia WHERE downloaded > 0 ORDER BY id", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Download] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(.init(episodeID: sqlite3_column_int64(statement, 0), size: sqlite3_column_int64(statement, 1),
                              date: sqlite3_column_int64(statement, 2)))
        }
        return rows
    }
}
#endif
