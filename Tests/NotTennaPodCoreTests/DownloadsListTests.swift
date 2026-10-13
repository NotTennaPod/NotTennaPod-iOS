import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct DownloadsListTests {
    private func episode(_ id: Int64, title: String, size: Int64, downloaded: Bool = true) -> LibraryEpisode {
        var value = LibraryEpisode(id: id, details: .init(title: title, publicationDate: Date(timeIntervalSince1970: Double(id)),
            media: .init(url: "https://example.test/\(id)", size: size, durationMilliseconds: Int32(id * 1000))))
        value.userState.isDownloaded = downloaded
        return value
    }
    private func job(_ id: Int64, source: String, state: LibraryDownloadJob.State) -> LibraryDownloadJob {
        .init(id: id, episodeID: id, source: source, destination: URL(filePath: "/tmp/unused-\(id)"),
              enqueuedByDownload: false, createdAt: .distantPast, state: state, attempts: 0, updatedAt: .distantPast)
    }
    @Test func activeURLGroupUsesHistoryOrderAndDoesNotDuplicateCompletedURLs() {
        var a = episode(1, title: "Zulu", size: 10, downloaded: false)
        var b = episode(2, title: "Alpha", size: 20, downloaded: false)
        a.userState.lastPlayedHistoryMilliseconds = 20; b.userState.lastPlayedHistoryMilliseconds = 30
        var duplicate = episode(5, title: "Duplicate", size: 10, downloaded: false)
        duplicate.details.media?.url = "https://example.test/3"
        let values = [a, b, episode(3, title: "Charlie", size: 100), episode(4, title: "Bravo", size: 30), duplicate]
        let jobs = [job(1, source: "https://example.test/1", state: .waiting), job(2, source: "https://example.test/2", state: .transferring),
                    job(3, source: "https://example.test/3", state: .waiting), job(6, source: "https://example.test/5", state: .failed)]
        #expect(DownloadsList.episodes(values, jobs: jobs, order: .titleAscending).map(\.id) == [2, 1, 4, 3])
        #expect(DownloadsList.episodes(values, jobs: jobs, order: .sizeLargest).map(\.id) == [2, 1, 3, 4])
        #expect(DownloadsList.episodes(values, jobs: [], order: nil).map(\.id) == [4, 3])
    }
    @Test func downloadedSizeSortingUsesRecordedBytesAndIDTies() {
        let values = [episode(3, title: "c", size: 10), episode(2, title: "b", size: 30), episode(1, title: "a", size: 10)]
        #expect(DownloadsList.episodes(values, jobs: [], order: .sizeSmallest).map(\.id) == [1, 3, 2])
        #expect(DownloadsList.episodes(values, jobs: [], order: .sizeLargest).map(\.id) == [2, 1, 3])
        #expect(DownloadsList.order(.global) == .dateNewest && DownloadsList.order(.filenameAscending) == .dateNewest)
        #expect(FeedEpisodeSortOrder.Field.choices(local: false) == [.title, .duration, .date, .global])
    }
    @Test func playedDeletionIncludesFavoritesButExcludesUnplayedAndMissingFiles() {
        var played = episode(1, title: "Played favorite", size: 10)
        played.userState.playState = .played; played.userState.isFavorite = true
        let unplayed = episode(2, title: "Unplayed", size: 10)
        var missing = episode(3, title: "Already deleted", size: 10, downloaded: false); missing.userState.playState = .played
        var newest = episode(4, title: "Played", size: 10); newest.userState.playState = .played
        #expect(DownloadsList.playedDownloadIDs([newest, missing, unplayed, played]) == [1, 4])
    }
    @Test func immediateSortPersistenceReopensAndOldPreferencesKeepSourceDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadsList-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        try Data("{\"allowMobile\":false,\"enqueue\":true,\"deleteRemovesFromQueue\":false,\"enqueueLocation\":\"BACK\"}".utf8).write(to: url)
        let preferences = try DownloadPreferenceStore(file: url)
        #expect(DownloadsList.order(preferences.value.listSortOrder) == .dateNewest && preferences.value.buttonActionPlay != true)
        let editor = FeedSortEditor(selection: .dateNewest, local: false, includesGlobal: false, fields: DownloadsList.sortFields) { order in
            var value = preferences.value; value.listSortOrder = order; try preferences.update(value)
        }
        #expect(editor.fields == [.title, .duration, .date, .size])
        editor.select(.size); #expect(editor.selection == .sizeLargest)
        await editor.select(.size)?.value
        #expect(try DownloadPreferenceStore(file: url).value.listSortOrder == .sizeSmallest)
        #expect(editor.select(.filename) == nil)
    }
}
