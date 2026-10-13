import CoreMedia
import Foundation

/// Stable media identity across recovery generations. Decoder setup runs off MainActor;
/// each session owns a decoder read scope, while the factory retains encoded source
/// state across seeks. A live decoder also retains that source until cancellation.
/// Native presentation ownership remains on MainActor. No session activation.
@MainActor struct PCMRecoveryFactory {
    private enum Source: Sendable {
        case native(URL)
        case localNative(NativeLocalAudioSource)
        case capturedNative(NativeAudioPlaybackSource)
        case buffered(FFmpegPlaybackSource)
        case media(FFmpegPlaybackSource)
        case mp3(NativeMP3PlaybackSource)
    }
    private let source: Source
    var providesSourceDuration: Bool {
        if case .native = source { return false }
        return true
    }
    private let maximumOutputFrames: Int
    private let maximumQueuedBuffers: Int
    /// Audio kept queued in the renderer, in time, so the queue never depends on the main thread answering
    /// within a fraction of a second (0.37 s at 44.1 kHz ran dry whenever the screen stalled
    /// ~0.25 s, heard as constant skipping at 1.75×). Production sets one second, within Android's
    /// 0.25–0.75 s AudioTrack buffer plus its decoder queue, so speed changes still land promptly.
    var minimumQueuedSeconds: Double = 0
    static let productionQueuedSeconds: Double = 1
    func queuedBuffers(sampleRate: Int) -> Int {
        let needed = Int((minimumQueuedSeconds * Double(sampleRate) / Double(maximumOutputFrames)).rounded(.up))
        return min(64, max(maximumQueuedBuffers, needed))
    }
    private let makeTransport: @MainActor () throws -> any PCMPresentationTransport

    var mediaSource: FFmpegPlaybackSource? {
        guard case .media(let source) = source else { return nil }
        return source
    }

    init(mediaSource: FFmpegPlaybackSource, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .media(mediaSource), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    init(url: URL, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        guard url.isFileURL else { throw NativePCMDecoder.Failure.notLocal }
        try self.init(source: .native(url), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Explicit local native source route, including startup metadata. Reached through
    /// `PCMPlaybackFactory.make`, which only tests call; the app selects `processedIfSupported`.
    init(nativeSourceURL url: URL, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .localNative(NativeLocalAudioSource(url: url, maximumFrames: maximumOutputFrames)),
            maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
            makeTransport: makeTransport)
    }

    init(nativeSource: NativeLocalAudioSource, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .localNative(nativeSource), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    init(localMP3Source: NativeMP3PlaybackSource, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .mp3(localMP3Source), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Explicit codec selection; format/rate routing must select this after inspecting media.
    /// Do not change offline/direct decoding merely to enable playback buffering.
    init(bufferedURL url: URL, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        let source = Source.buffered(try FFmpegPlaybackSource(url: url, maximumFrames: maximumOutputFrames))
        try self.init(source: source, maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    init(bufferedInput: HTTPCodecByteInput, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .buffered(FFmpegPlaybackSource(input: bufferedInput, maximumFrames: maximumOutputFrames)), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Sniffing and every replacement decoder share the captured file/document,
    /// even if its original pathname disappears or is reused for another item.
    init(bufferedFile: LocalAudioBytes, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .buffered(FFmpegPlaybackSource(file: bufferedFile, maximumFrames: maximumOutputFrames)),
            maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
            makeTransport: makeTransport)
    }

    init(bufferedSource: FFmpegPlaybackSource, maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .buffered(bufferedSource), maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    /// Explicit internal MP3 route. Reached through `PCMPlaybackFactory.make`, which only
    /// tests call; the app selects `processedIfSupported`.
    init(mp3URL url: URL, proxy: PodcastProxy, credentials: FeedCredentials? = nil, cache: SharedStreamingCache? = nil, retry: PCMSourceRetry? = nil,
         maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        try self.init(source: .mp3(NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials, cache: cache, retry: retry)),
            maximumOutputFrames: maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers,
            makeTransport: makeTransport)
    }

    init(remote: PCMRemoteInput, url: URL, proxy: PodcastProxy, credentials: FeedCredentials?, cache: SharedStreamingCache,
         maximumOutputFrames: Int, maximumQueuedBuffers: Int,
         makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        let source: Source
        switch remote.format {
        case .mp3:
            source = .mp3(NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials,
                cache: cache, preparedInput: remote))
        case .buffered: source = .buffered(FFmpegPlaybackSource(remote: remote, url: url, proxy: proxy,
            credentials: credentials, cache: cache, maximumFrames: maximumOutputFrames))
        case .native:
            source = .capturedNative(try NativeAudioPlaybackSource(remote: remote, url: url,
                proxy: proxy, credentials: credentials, cache: cache, maximumFrames: maximumOutputFrames))
        }
        try self.init(source: source, maximumOutputFrames: maximumOutputFrames,
            maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: makeTransport)
    }

    private init(source: Source, maximumOutputFrames: Int, maximumQueuedBuffers: Int,
                 makeTransport: @escaping @MainActor () throws -> any PCMPresentationTransport) throws {
        guard (1...65536).contains(maximumOutputFrames), (1...64).contains(maximumQueuedBuffers) else {
            throw SampleBufferPCMOutput.Failure.invalidCapacity
        }
        self.source = source
        self.maximumOutputFrames = maximumOutputFrames
        self.maximumQueuedBuffers = maximumQueuedBuffers
        self.makeTransport = makeTransport
    }

    init(url: URL, muted: Bool) throws {
        try self.init(url: url, makeTransport: { NativeSampleBufferTransport(muted: muted) })
    }

    func bufferedProducerSnapshot() async -> FFmpegPacketProducer.Snapshot? {
        guard case .buffered(let source) = source else { return nil }
        return await source.producerSnapshot()
    }

    func make(positionMilliseconds: Int64, parameters: PCMRecoverySession.Parameters) async throws -> SampleBufferPlaybackSession {
        guard positionMilliseconds >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
        guard parameters.speed.isFinite, (0.5...4).contains(parameters.speed) else {
            throw PCMSpeedProcessor.Failure.invalidSpeed
        }
        if case .media(let source) = source {
            return try await makeMedia(source: source, positionMilliseconds: positionMilliseconds, parameters: parameters)
        }
        let stream = try await Self.open(source: source, position: positionMilliseconds,
            parameters: parameters, maximumFrames: maximumOutputFrames)
        do {
            try Task.checkCancellation()
            let transport = try makeTransport()
            do {
                let output: any PCMPresentationTransport
                if let backend = transport as? any PCMVolumePresentationTransport {
                    output = try VolumeControlledPCMTransport(backend: backend, sampleRate: stream.sampleRate,
                        channels: stream.channels, maximumFrames: maximumOutputFrames,
                        setting: parameters.volume, baseVolume: parameters.baseVolume)
                } else {
                    guard parameters.volume == .off && parameters.baseVolume == 1 else { throw PlaybackVolumeError.unsupportedEngine }
                    output = transport
                }
                return try SampleBufferPlaybackSession(stream: stream, transport: output,
                    maximumQueuedBuffers: queuedBuffers(sampleRate: stream.sampleRate), starvationResumeSeconds: minimumQueuedSeconds / 2)
            } catch { transport.close(); throw error }
        } catch { await stream.cancel(); throw error }
    }

    private func makeMedia(source: FFmpegPlaybackSource, positionMilliseconds: Int64,
                           parameters: PCMRecoverySession.Parameters) async throws -> SampleBufferPlaybackSession {
        let media = try await source.makeMedia(start: CMTime(value: positionMilliseconds, timescale: 1000))
        do {
            let decoder = try await media.makeAudioDecoder()
            let stream = try decoder.map { try LocalPCMPlaybackStream(decoder: $0, skipSilence: parameters.skipSilence,
                speed: parameters.speed, maximumOutputFrames: maximumOutputFrames) }
            var transport = try makeTransport()
            if stream == nil, let idleAudioTransport = transport as? NativeSampleBufferTransport {
                let muted = idleAudioTransport.isMuted
                idleAudioTransport.close()
                transport = NativeSampleBufferTransport(muted: muted, audioEnabled: false)
            }
            do {
                let raw = transport as? NativeSampleBufferTransport
                let hasVideo = media.metadata.selectedVideoTrackID != nil
                guard !hasVideo || raw != nil else { throw PlaybackTrackSelectionError.unsupported }
                let output: any PCMPresentationTransport
                if let stream, let backend = transport as? any PCMVolumePresentationTransport {
                    output = try VolumeControlledPCMTransport(backend: backend, sampleRate: stream.sampleRate,
                        channels: stream.channels, maximumFrames: maximumOutputFrames,
                        setting: parameters.volume, baseVolume: parameters.baseVolume)
                } else {
                    guard stream == nil || (parameters.volume == .off && parameters.baseVolume == 1) else {
                        throw PlaybackVolumeError.unsupportedEngine
                    }
                    output = transport
                }
                return try SampleBufferPlaybackSession(stream: stream, transport: output,
                    maximumQueuedBuffers: stream.map { queuedBuffers(sampleRate: $0.sampleRate) } ?? maximumQueuedBuffers,
                    starvationResumeSeconds: minimumQueuedSeconds / 2,
                    videoSource: hasVideo ? media : nil, videoTransport: hasVideo ? raw : nil,
                    videoDurationMilliseconds: media.metadata.duration.map { CMTimeConvertScale($0, timescale: 1000, method: .roundTowardZero).value },
                    videoSeekable: media.metadata.sourceSeekable)
            } catch { transport.close(); throw error }
        } catch { await media.cancel(); throw error }
    }

    @concurrent private static func open(source: Source, position: Int64, parameters: PCMRecoverySession.Parameters,
                                         maximumFrames: Int) async throws -> LocalPCMPlaybackStream {
        try Task.checkCancellation()
        let start = CMTime(value: position, timescale: 1000)
        let decoder: any PCMDecoding
        switch source {
        case .media: throw PlaybackTrackSelectionError.unsupported // Constructed by the joined session branch.
        case .native(let url):
            return try LocalPCMPlaybackStream(url: url, start: start, skipSilence: parameters.skipSilence,
                speed: parameters.speed, maximumOutputFrames: maximumFrames)
        case .buffered(let source):
            decoder = try await source.makeDecoder(start: start)
        case .mp3(let source):
            decoder = try await source.makeDecoder(start: start, prepareSourceTimeline: true)
        case .capturedNative(let source):
            decoder = try await source.makeDecoder(start: start, processStartupTrim: true)
        case .localNative(let source):
            decoder = try await source.makeDecoder(start: start, processStartupTrim: true)
        }
        do {
            try Task.checkCancellation()
            return try LocalPCMPlaybackStream(decoder: decoder, skipSilence: parameters.skipSilence,
                speed: parameters.speed, maximumOutputFrames: maximumFrames)
        } catch { await decoder.cancel(); throw error }
    }
}
