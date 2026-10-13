import Foundation

/// The player's last saved reading position, not a per-episode scroll history.
/// The standalone library keeps it in `shownotes-scroll.json`; a server library in its `playback-library.json`.
@MainActor
public final class ShownotesScrollStore {
    private struct Position: Codable, Equatable {
        let episodeID: Int64
        let offset: Double
    }
    private let file: URL?
    private let library: PlaybackLibraryFile?
    private var position: Position?

    public init() { file = nil; library = nil }

    public init(file: URL) throws {
        self.file = file
        library = nil
        if let data = try SavedState.contents(of: file) {
            position = try JSONDecoder().decode(Position.self, from: data)
        }
    }

    /// A server library's position, kept in its `playback-library.json`.
    public init(library: PlaybackLibraryFile) {
        file = nil
        self.library = library
        position = library.value.shownotes.map { Position(episodeID: $0.episodeID, offset: $0.offset) }
    }

    public func offset(for episodeID: Int64) -> Double? {
        guard let position, position.episodeID == episodeID,
              position.offset.isFinite, position.offset >= 0 else { return nil }
        return position.offset
    }

    /// Database import: the saved position refers to an episode id of the replaced library.
    public func reset() throws {
        if let file, FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try library?.update { $0.shownotes = nil }
        position = nil
    }

    public func save(episodeID: Int64, offset: Double) throws {
        guard offset.isFinite else { return }
        // UIKit rubber-banding can temporarily place the viewport above the top.
        let next = Position(episodeID: episodeID, offset: max(0, offset))
        guard next != position else { return }
        if let file { try JSONEncoder().encode(next).write(to: file, options: .atomic) }
        try library?.update { $0.shownotes = .init(episodeID: next.episodeID, offset: next.offset) }
        position = next
    }
}
