import Foundation

/// Supplies current facts; the coordinator owns pending requests and one-time consent.
@MainActor
public final class StreamingAccessProvider {
    private let preferences: MobileNetworkPreferenceStore
    private let network: DownloadNetworkMonitor

    public init(preferences: MobileNetworkPreferenceStore, network: DownloadNetworkMonitor = .shared) {
        self.preferences = preferences
        self.network = network
    }

    public static func needsStreaming(_ episode: LibraryEpisode) -> Bool {
        // The source tests the saved flag/path, not file existence. Missing local
        // media must reach the file error path without silently spending mobile data.
        if episode.userState.isDownloaded, episode.userState.localFileURL != nil { return false }
        // Native file URLs are the engine's local source representation. Android
        // content URLs require a separate import/resolution layer, still pending.
        if let text = episode.details.media?.url, let url = URL(string: text), url.isFileURL { return false }
        return true
    }

    public func access(for episode: LibraryEpisode, isCasting: Bool = false) async throws -> PlaybackStreamingAccess {
        let needsStreaming = Self.needsStreaming(episode)
        if !needsStreaming || isCasting || preferences.allows(.streaming) {
            return .init(needsStreaming: needsStreaming, streamingAllowed: preferences.allows(.streaming), isCasting: isCasting)
        }
        // Await the first observation, not a connected/unmetered path. An offline
        // observation must still reach the source's permission/error flow.
        let state = try await network.observedState()
        return .init(needsStreaming: true,
                     streamingAllowed: preferences.allows(.streaming) || !state.restricted, isCasting: isCasting)
    }
}
