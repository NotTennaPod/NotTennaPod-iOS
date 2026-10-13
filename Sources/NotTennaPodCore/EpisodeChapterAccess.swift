import Foundation

/// Application chapter access uses a selected library episode, not an arbitrary
/// file URL in feed metadata. Views own request cancellation; this owner retains
/// the transport/cache and keeps file grants alive through each complete read.
public struct EpisodeChapterAccess: Sendable {
    enum Request: Sendable { case chapters, image(EmbeddedChapterImage) }
    enum Result: Sendable { case chapters([ParsedChapter]?), image(Data) }
    typealias FileRead = @Sendable (URL, @Sendable () throws -> Void, Request) throws -> Result
    typealias RemoteRead = @Sendable (URL, PodcastProxy, FeedCredentials?, String, Request) async throws -> Result

    private let store: FeedLibraryStore
    private let loader: EpisodeChapterLoader
    private let proxy: @Sendable () -> PodcastProxy
    private let credentials: @Sendable (Int64) async throws -> FeedCredentials?
    private let userAgent: String
    private let fileRead: FileRead
    private let remoteRead: RemoteRead

    public init(store: FeedLibraryStore, loader: EpisodeChapterLoader,
                proxy: @escaping @Sendable () -> PodcastProxy,
                credentials: @escaping @Sendable (Int64) async throws -> FeedCredentials? = { _ in nil },
                userAgent: String = HTTPUserAgent.unversioned) {
        self.init(store: store, loader: loader, proxy: proxy, credentials: credentials, userAgent: userAgent,
                  fileRead: Self.readFile, remoteRead: Self.readRemote)
    }

    init(store: FeedLibraryStore, loader: EpisodeChapterLoader,
         proxy: @escaping @Sendable () -> PodcastProxy = { .init() },
         credentials: @escaping @Sendable (Int64) async throws -> FeedCredentials? = { _ in nil },
         userAgent: String = HTTPUserAgent.unversioned, fileRead: @escaping FileRead = Self.readFile,
         remoteRead: @escaping RemoteRead = Self.readRemote) {
        self.store = store; self.loader = loader; self.proxy = proxy
        self.credentials = credentials; self.userAgent = userAgent
        self.fileRead = fileRead; self.remoteRead = remoteRead
    }

    public func load(episode: LibraryEpisode, loaded: [ParsedChapter]? = nil,
                     forceRefresh: Bool = false) async throws -> [ParsedChapter] {
        try await requireCurrent(episode)
        let loader = loader, identity = EpisodeChapterIdentity(episode)
        // A downloaded file removed behind the library's back is read again (and so falls back as before).
        let fileGone = episode.userState.isDownloaded && episode.userState.localFileURL.map {
            !FileManager.default.fileExists(atPath: $0) } == true
        let result = try await loader.load(stored: episode.details.chapters, loaded: loaded,
            externalURL: episode.details.chapterURL, forceRefresh: forceRefresh) {
                try await loader.mediaChapters(identity, forceRefresh: forceRefresh || fileGone) {
                    guard case .chapters(let chapters) = try await readMedia(episode, request: .chapters) else { return nil }
                    return chapters
                }
            }
        try await requireCurrent(episode)
        return result
    }

    public func artwork(_ reference: EmbeddedChapterImage, episode: LibraryEpisode) async throws -> Data? {
        guard case .image(let bytes) = try await readMedia(episode, request: .image(reference)) else { return nil }
        return bytes
    }

    private func requireCurrent(_ episode: LibraryEpisode) async throws {
        try Task.checkCancellation()
        guard let current = try await store.episode(id: episode.id),
              EpisodeChapterIdentity(current) == EpisodeChapterIdentity(episode) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func readMedia(_ episode: LibraryEpisode, request: Request) async throws -> Result? {
        try await requireCurrent(episode)
        let result: Result
        if let reference = try await store.localDocument(episodeID: episode.id) {
            guard let identity = episode.details.media?.url, let name = episode.details.link,
                  reference.identity.utf16.elementsEqual(identity.utf16),
                  reference.filename.utf16.elementsEqual(name.utf16), reference.size == episode.details.media?.size else {
                throw CancellationError()
            }
            let documents = LocalFolderDocuments(bookmark: reference.folder.bookmark), read = fileRead
            result = try await documents.read(fileNamed: reference.filename) { url, check in try read(url, check, request) }
            try Task.checkCancellation()
            guard try await store.recordLocalChapterRead(episodeID: episode.id, reference: reference,
                refreshedBookmark: documents.bookmark) else { throw CancellationError() }
        } else if episode.userState.isDownloaded, let path = episode.userState.localFileURL {
            guard path.hasPrefix("/"), !path.contains("\0"), let reference = DownloadedArtworkReference(episode),
                  try await store.downloadedArtworkReference(episodeID: episode.id) == reference else { throw CancellationError() }
            let read = fileRead, url = URL(fileURLWithPath: path)
            let task = Task.detached(priority: .utility) { try read(url, { try Task.checkCancellation() }, request) }
            result = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
            guard try await store.downloadedArtworkReference(episodeID: episode.id) == reference else { throw CancellationError() }
        } else {
            guard let text = episode.details.media?.url, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
            let configuration = proxy()
            let login = try await credentials(store.feedID(forEpisode: episode.id))
            try await requireCurrent(episode)
            result = try await remoteRead(url, configuration, login, userAgent, request)
        }
        try await requireCurrent(episode)
        return result
    }

    static func readFile(_ url: URL, check: @Sendable () throws -> Void, request: Request) throws -> Result {
        switch request {
        case .chapters: return .chapters(try EmbeddedChapterReader.read(url: url, checkCancellation: check))
        case .image(let reference): return .image(try reference.read(url: url, checkCancellation: check))
        }
    }
    static func readRemote(_ url: URL, proxy: PodcastProxy, credentials: FeedCredentials?, userAgent: String,
                           request: Request) async throws -> Result {
        let reader = RemoteChapterMediaReader(proxy: proxy, credentials: credentials, userAgent: userAgent)
        switch request {
        case .chapters: return .chapters(try await reader.read(url: url))
        case .image(let reference): return .image(try await reader.artwork(reference, url: url))
        }
    }
}

/// Position, playback flags and favorite edits do not change chapter data.
/// Literal URL/path comparison avoids conflating distinct server/provider names.
struct EpisodeChapterIdentity: Equatable, Sendable {
    let id: Int64
    let mediaURL, localPath, chapterURL, documentName: [UInt16]?
    let mediaSize: Int64?
    let downloaded: Bool
    let downloadDate: Date?
    let stored: [ParsedChapter]?
    init(_ episode: LibraryEpisode) {
        id = episode.id; mediaURL = episode.details.media?.url.map { Array($0.utf16) }
        localPath = episode.userState.localFileURL.map { Array($0.utf16) }
        chapterURL = episode.details.chapterURL.map { Array($0.utf16) }
        documentName = episode.details.link.map { Array($0.utf16) }
        mediaSize = episode.details.media?.size; downloaded = episode.userState.isDownloaded
        downloadDate = episode.userState.downloadDate; stored = episode.details.chapters
    }
}
