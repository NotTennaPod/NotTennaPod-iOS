import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: the account-level policies go through one facade. In the standalone library it reads and writes
/// today's JSON values, unchanged.
@Suite @MainActor struct AccountPolicyTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AccountPolicy-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The file holds `expected` with the keys the screens' own write produced (content and structure, not bytes:
    /// `JSONEncoder` does not keep key order between encodings).
    private func expectSameJSON<Value: Codable & Equatable>(_ file: URL, as expected: Value) throws {
        let data = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode(Value.self, from: data) == expected)
        let saved = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSDictionary)
        #expect(saved == written)
    }

    @Test func standaloneFacadeReadsAndWritesTodaysPreferenceFiles() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadFile = root.appendingPathComponent("download-preferences.json")
        let queueFile = root.appendingPathComponent("queue-interaction.json")
        let download = try DownloadPreferenceStore(file: downloadFile)
        let queue = try QueueInteractionPreferenceStore(file: queueFile)
        let policy = AccountPolicy.standalone(download: download, queue: queue)
        #expect(policy.newEpisodesAction == .inbox && policy.enqueueLocation == .back)
        #expect(!policy.keepSorted && policy.activeKeepSortedOrder == nil && policy.keepSortedOrder == QueueSortOrder(storedValue: nil))
        #expect(!FileManager.default.fileExists(atPath: downloadFile.path), "reading writes nothing")

        try policy.setNewEpisodesAction(.queue)
        try policy.setEnqueueLocation(.front)
        try policy.setKeepSorted(true, order: .durationShortLong)
        // Exactly what the screens wrote before the facade.
        var expectedDownload = DownloadPreferences(); expectedDownload.newEpisodesAction = .queue; expectedDownload.enqueueLocation = .front
        #expect(download.value == expectedDownload)
        try expectSameJSON(downloadFile, as: expectedDownload)
        let expectedQueue = QueueInteractionPreferences(keepSorted: true, keepSortedOrderName: QueueSortOrder.durationShortLong.rawValue)
        #expect(queue.value == expectedQueue)
        try expectSameJSON(queueFile, as: expectedQueue)
        #expect(policy.newEpisodesAction == .queue && policy.enqueueLocation == .front)
        #expect(policy.activeKeepSortedOrder == .durationShortLong)
        #expect(policy.queueInsertionSettings() == QueueInsertionSettings(download: download.value, queue: queue.value))
        // Other values in the same files are kept.
        var other = download.value; other.smartMarkAsPlayedSeconds = 60; try download.update(other)
        try policy.setEnqueueLocation(.afterCurrentlyPlaying)
        #expect(download.value.smartMarkAsPlayedSeconds == 60 && download.value.newEpisodesAction == .queue)
    }

    @Test func missingStoresReadAsDefaultsAndCannotBeChanged() throws {
        let policy = AccountPolicy.standalone(download: nil, queue: nil)
        #expect(policy.newEpisodesAction == .inbox && policy.enqueueLocation == .back && !policy.keepSorted)
        #expect(throws: AccountPolicyError.unavailable) { try policy.setEnqueueLocation(.front) }
        #expect(throws: AccountPolicyError.unavailable) { try policy.setKeepSorted(true, order: .dateNewOld) }
    }

    /// The seam for server libraries: any backing serves the same facade.
    @Test func anotherBackingServesTheSameFacade() throws {
        final class Account: AccountPolicyBacking {
            var newEpisodesAction: NewEpisodesAction? = .nothing
            var enqueueLocation: EnqueueLocation = .random
            var keepSorted = true
            var keepSortedOrder: QueueSortOrder = .episodeTitleAZ
            func setNewEpisodesAction(_ action: NewEpisodesAction) throws { newEpisodesAction = action }
            func setEnqueueLocation(_ location: EnqueueLocation) throws { enqueueLocation = location }
            func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws { self.keepSorted = keepSorted; keepSortedOrder = order }
        }
        let policy = AccountPolicy(backing: Account())
        #expect(policy.newEpisodesAction == .nothing && policy.enqueueLocation == .random && policy.activeKeepSortedOrder == .episodeTitleAZ)
        try policy.setKeepSorted(false, order: .dateOldNew)
        #expect(policy.activeKeepSortedOrder == nil && policy.keepSortedOrder == .dateOldNew)
    }
}
