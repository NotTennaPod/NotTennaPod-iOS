import Foundation

/// One playback graph owns the factory across item changes and decoder recovery.
/// Local reader selection follows content; remote identification reuses the captured authenticated connection.
@MainActor final class PCMPlaybackFactory {
    enum Source {
        case local(URL)
        case nativeLocal(URL)
        case remote(URL, proxy: PodcastProxy, credentials: FeedCredentials? = nil)
        case mp3(URL, proxy: PodcastProxy, credentials: FeedCredentials? = nil)
    }
    private let cacheDirectory: URL
    private let maximumOutputFrames: Int
    private let maximumQueuedBuffers: Int
    /// See `PCMRecoveryFactory.minimumQueuedSeconds`; the application passes `productionQueuedSeconds`.
    private let minimumQueuedSeconds: Double
    private let makeTransport: @MainActor () throws -> any PCMPresentationTransport
    private var cacheResult: Result<SharedStreamingCache, any Error>?
    /// Where streamed items' relays are retired when the app may be suspended.
    private let reclaim: StreamingRelayReclaim

    init(cacheDirectory: URL, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4, minimumQueuedSeconds: Double = 0,
         reclaim: StreamingRelayReclaim = .shared,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) {
        self.cacheDirectory = cacheDirectory
        self.reclaim = reclaim
        self.maximumOutputFrames = maximumOutputFrames
        self.maximumQueuedBuffers = maximumQueuedBuffers
        self.minimumQueuedSeconds = minimumQueuedSeconds
        self.makeTransport = makeTransport
    }

    /// Select from captured bytes and actual tracks. Native elementary audio
    /// retains its proven decoder; container families use typed demux inspection
    /// before choosing audio-only processing or a joined audio/video session.
    func processedIfSupported(url: URL, proxy: PodcastProxy, credentials: FeedCredentials?,
                              userAgent: String) async throws -> PCMRecoveryFactory? {
        try await unconfiguredProcessed(url: url, proxy: proxy, credentials: credentials, userAgent: userAgent).map(configured)
    }

    func processedIfSupported(document: LocalPlaybackDocument) async throws -> PCMRecoveryFactory? {
        try await unconfiguredProcessed(document: document).map(configured)
    }

    func make(_ source: Source) async throws -> PCMRecoveryFactory { configured(try await unconfiguredMake(source)) }

    private func configured(_ factory: PCMRecoveryFactory) -> PCMRecoveryFactory {
        var factory = factory
        factory.minimumQueuedSeconds = minimumQueuedSeconds
        return factory
    }

    private func unconfiguredProcessed(url: URL, proxy: PodcastProxy, credentials: FeedCredentials?,
                                       userAgent: String) async throws -> PCMRecoveryFactory? {
        if url.isFileURL { return try await processedLocal(file: LocalAudioBytes(url: url), url: url) }
        let result = cacheResult ?? Result { try SharedStreamingCache(directory: cacheDirectory) }
        cacheResult = result
        let cache = try result.get()
        let remote: PCMRemoteInput
        do { remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache, userAgent: userAgent,
                                                    reclaim: reclaim) }
        catch StreamingAudioTypeError.requiresNativePlaylist { return nil }
        catch StreamingAudioTypeError.unrecognized { return nil }
        catch PCMRemoteInput.Failure.unidentified { return nil }
        if remote.format == .mp3 || (try? NativeAudioSourceTimeline.Format(remote.format)).map({ $0 == .adts || $0 == .flac }) == true {
            return try PCMRecoveryFactory(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache,
                maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        }
        let source = FFmpegPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials,
            cache: cache, maximumFrames: maximumOutputFrames)
        return try await processedMedia(source)
    }

    private func unconfiguredProcessed(document: LocalPlaybackDocument) async throws -> PCMRecoveryFactory? {
        try await processedLocal(file: LocalAudioBytes(document: document),
            url: URL(string: "antennapod-local://\(UUID().uuidString)/media")!)
    }

    private func processedLocal(file: LocalAudioBytes, url: URL) async throws -> PCMRecoveryFactory? {
        let identified: PCMRemoteInput.Format
        do { identified = try await file.identify() }
        catch StreamingAudioTypeError.requiresNativePlaylist { return nil }
        catch StreamingAudioTypeError.unrecognized { return nil }
        catch StreamingAudioTypeError.native { return nil }
        catch PCMRemoteInput.Failure.unidentified { return nil }
        if identified == .mp3 {
            return try PCMRecoveryFactory(localMP3Source: NativeMP3PlaybackSource(localURL: url, file: file),
                maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        }
        let format = try? NativeAudioSourceTimeline.Format(identified)
        if let format, format == .adts || format == .flac || format == .wav {
            let timeline = try await NativeAudioSourceTimeline.read(input: file.lease(), format: format)
            if timeline.supportsNativePacketTimeline {
                return try PCMRecoveryFactory(nativeSource: NativeLocalAudioSource(url: url, maximumFrames: maximumOutputFrames,
                    file: file, format: format), maximumOutputFrames: maximumOutputFrames,
                    maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
            }
        }
        let source = FFmpegPlaybackSource(file: file, maximumFrames: maximumOutputFrames)
        let metadata = try await source.prepareMediaMetadata()
        // Native MP4 is retained only for its proven single-AAC-track contract.
        // Actual video, additional audio choices and fragmented tables use the
        // generalized source; no selected visual track disappears in an audio route.
        if format == .mp4, metadata.selectedVideoTrackID == nil,
           metadata.tracks.filter({ $0.kind == .audio }).count == 1,
           metadata.tracks.first(where: { $0.kind == .audio })?.codec == "aac" {
            let timeline: NativeAudioSourceTimeline?
            do { timeline = try await NativeAudioSourceTimeline.read(input: file.lease(), format: .mp4) }
            catch is NativeMP4SourceTimeline.Failure { timeline = nil }
            if timeline?.supportsNativePacketTimeline == true {
                return try PCMRecoveryFactory(nativeSource: NativeLocalAudioSource(url: url, maximumFrames: maximumOutputFrames,
                    file: file, format: .mp4), maximumOutputFrames: maximumOutputFrames,
                    maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
            }
        }
        return try await processedMedia(source)
    }

    private func processedMedia(_ source: FFmpegPlaybackSource) async throws -> PCMRecoveryFactory {
        let metadata = try await source.prepareMediaMetadata()
        guard metadata.selectedAudioTrackID != nil || metadata.selectedVideoTrackID != nil,
              !metadata.tracks.contains(where: { $0.kind == .video }) || metadata.selectedVideoTrackID != nil else {
            throw PlaybackTrackSelectionError.unsupported
        }
        if metadata.selectedVideoTrackID == nil,
           metadata.tracks.filter({ $0.kind == .audio }).count == 1,
           let codec = metadata.tracks.first(where: { $0.kind == .audio })?.codec,
           ["vorbis", "opus"].contains(codec),
           metadata.containerName.contains("ogg") || metadata.containerName.contains("matroska") {
            return try PCMRecoveryFactory(bufferedSource: source, maximumOutputFrames: maximumOutputFrames,
                maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        }
        return try PCMRecoveryFactory(mediaSource: source, maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Content-based app dispatch. Non-MP3 media keeps the existing native
    /// engine; successful MP3 identification transfers the same captured input.
    func mp3IfSupported(url: URL, proxy: PodcastProxy, credentials: FeedCredentials?,
                        userAgent: String) async throws -> PCMRecoveryFactory? {
        if url.isFileURL {
            guard let identified = try await LocalAudioBytes.openIdentified(url: url), identified.format == .mp3 else { return nil }
            return try PCMRecoveryFactory(localMP3Source: NativeMP3PlaybackSource(localURL: url, file: identified.file),
                maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        }
        let result = cacheResult ?? Result { try SharedStreamingCache(directory: cacheDirectory) }
        cacheResult = result
        let cache = try result.get()
        let input: PCMRemoteInput
        do { input = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache, userAgent: userAgent,
                                                   reclaim: reclaim) }
        catch StreamingAudioTypeError.requiresNativePlaylist { return nil }
        catch StreamingAudioTypeError.unrecognized { return nil }
        catch PCMRemoteInput.Failure.unidentified { return nil }
        guard input.format == .mp3 else { return nil }
        return try PCMRecoveryFactory(remote: input, url: url, proxy: proxy, credentials: credentials, cache: cache,
            maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Registered files use the same identified bytes for every decoder lease.
    /// Non-MP3 containers and native parser rejection keep the existing AV route;
    /// access, cancellation and identity failures are never hidden by fallback.
    func mp3IfSupported(document: LocalPlaybackDocument) async throws -> PCMRecoveryFactory? {
        let file = try LocalAudioBytes(document: document)
        let format: PCMRemoteInput.Format
        do { format = try await file.identify() }
        catch StreamingAudioTypeError.unrecognized { return nil }
        catch StreamingAudioTypeError.native { return nil }
        catch StreamingAudioTypeError.requiresNativePlaylist { return nil }
        catch PCMRemoteInput.Failure.unidentified { return nil }
        guard format == .mp3 else { return nil }
        return try PCMRecoveryFactory(localMP3Source: NativeMP3PlaybackSource(
            localURL: URL(string: "antennapod-local://\(UUID().uuidString)/media")!, file: file),
            maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    private func unconfiguredMake(_ source: Source) async throws -> PCMRecoveryFactory {
        try Task.checkCancellation()
        switch source {
        case .nativeLocal(let url):
            return try PCMRecoveryFactory(nativeSourceURL: url, maximumOutputFrames: maximumOutputFrames,
                maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        case .local(let url):
            // Local media must remain usable even if shared-cache initialization fails.
            if let identified = try await LocalAudioBytes.openIdentified(url: url) {
                try Task.checkCancellation()
                if identified.format == .buffered {
                    return try PCMRecoveryFactory(bufferedFile: identified.file, maximumOutputFrames: maximumOutputFrames,
                        maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
                }
                if identified.format == .mp3 {
                    return try PCMRecoveryFactory(localMP3Source: NativeMP3PlaybackSource(localURL: url, file: identified.file),
                        maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
                        makeTransport: makeTransport)
                }
                if let format = try? NativeAudioSourceTimeline.Format(identified.format) {
                    let source = try NativeLocalAudioSource(url: url, maximumFrames: maximumOutputFrames,
                        file: identified.file, format: format)
                    return try PCMRecoveryFactory(nativeSource: source, maximumOutputFrames: maximumOutputFrames,
                        maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
                }
            }
            return try PCMRecoveryFactory(url: url, maximumOutputFrames: maximumOutputFrames,
                maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
        case let .remote(url, proxy, credentials):
            let result = cacheResult ?? Result { try SharedStreamingCache(directory: cacheDirectory) }
            cacheResult = result
            let cache = try result.get()
            let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache, reclaim: reclaim)
            try Task.checkCancellation()
            return try PCMRecoveryFactory(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache,
                maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
                makeTransport: makeTransport)
        case let .mp3(url, proxy, credentials):
            // SimpleCache retains initialization failure for its owner lifetime;
            // the active source doesn't enable IGNORE_CACHE_ON_ERROR.
            let result = cacheResult ?? Result { try SharedStreamingCache(directory: cacheDirectory) }
            cacheResult = result
            let cache = try result.get()
            return try PCMRecoveryFactory(mp3URL: url, proxy: proxy, credentials: credentials, cache: cache,
                maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
                makeTransport: makeTransport)
        }
    }
}
