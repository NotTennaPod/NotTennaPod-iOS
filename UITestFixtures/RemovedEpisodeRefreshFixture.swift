#if DEBUG
import Foundation
import NotTennaPodCore

/// Test-owned local documents only. Production refresh and deletion are never
/// invoked by the move trigger: the ordinary visible Refresh action does that.
struct RemovedEpisodeRefreshFixture: Codable, Sendable {
    let root: URL
    let feedID: Int64
    let removedID: Int64
    let survivorID: Int64

    enum PreparationError: Error {
        case scanSuperseded
        case scanFailed(LocalFolderScanFailure)
        case expectedEpisodesMissing
    }

    static let feedTitle = "Removal refresh folder"
    static let removedTitle = "Removal target"
    static let survivorTitle = "Removal survivor"
    var folder: URL { root.appendingPathComponent("provider-folder", isDirectory: true) }
    var original: URL { folder.appendingPathComponent(Self.removedTitle + ".wav") }
    var retained: URL { root.appendingPathComponent("retained-document.wav") }
    var survivor: URL { folder.appendingPathComponent(Self.survivorTitle + ".wav") }

    static func prepare(root: URL, store: FeedLibraryStore) async throws -> Self {
        let manifest = root.appendingPathComponent("fixture.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifest))
            guard saved.root == root else { throw CocoaError(.fileReadCorruptFile) }
            // Relaunch must read persisted application state, never reseed it.
            return saved
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            // An interrupted setup is an explicit failure, not permission to
            // reconstruct files or queue state and conceal a durability defect.
            throw CocoaError(.fileWriteFileExists)
        }
        let folder = root.appendingPathComponent("provider-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = waveData()
        for title in [removedTitle, survivorTitle] {
            try bytes.write(to: folder.appendingPathComponent(title + ".wav"), options: .atomic)
        }
        let feed = try await store.registerLocalFolder(title: feedTitle,
            directoryIdentity: "removal-fixture-" + root.lastPathComponent,
            bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
        let outcome = try await LocalFeedRefreshService(store: store).refresh(feedID: feed.feed.id,
            description: "Test-owned local documents", author: "Local folder")
        switch outcome {
        case .updated: break
        case .failed(let failure): throw PreparationError.scanFailed(failure)
        case .superseded: throw PreparationError.scanSuperseded
        }
        guard let updated = try await store.feed(id: feed.feed.id),
              let removed = updated.episodes.first(where: { $0.details.title == removedTitle }),
              let survivor = updated.episodes.first(where: { $0.details.title == survivorTitle }),
              updated.episodes.count == 2 else { throw PreparationError.expectedEpisodesMissing }
        _ = try await store.enqueue([removed.id, survivor.id])
        let fixture = Self(root: root, feedID: feed.feed.id, removedID: removed.id, survivorID: survivor.id)
        try JSONEncoder().encode(fixture).write(to: manifest, options: .atomic)
        return fixture
    }

    func moveTarget() throws {
        guard !FileManager.default.fileExists(atPath: retained.path) else { return }
        try FileManager.default.moveItem(at: original, to: retained)
        try Data("moved after selected playback paused\n".utf8)
            .write(to: root.appendingPathComponent("moved.txt"), options: .atomic)
    }

    @MainActor func moveAfterTargetPlaysThenPauses(playback: PlaybackCoordinator) async throws {
        guard !FileManager.default.fileExists(atPath: retained.path) else { return }
        var playedTarget = false
        for await _ in playback.events() {
            try Task.checkCancellation()
            guard playback.episode?.id == removedID else { continue }
            if playback.phase == .playing { playedTarget = true }
            if playedTarget, playback.phase == .paused {
                try moveTarget()
                return
            }
        }
    }

    /// Valid mono PCM WAV, 60 seconds at 8 kHz. Long enough to remain outside
    /// the application's ordinary 30-second smart-completion threshold.
    static func waveData() -> Data {
        let sampleRate: UInt32 = 8_000, frames: UInt32 = sampleRate * 60
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); word(UInt32(36 + frames * 2)); text("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(sampleRate)
        word(sampleRate * 2); word(UInt16(2)); word(UInt16(16)); text("data"); word(frames * 2)
        for index in 0..<frames {
            word(Int16(sin(Double(index) * 2 * .pi * 220 / Double(sampleRate)) * 1_000))
        }
        return data
    }
}
#endif
