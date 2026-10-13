import AudioToolbox
import Foundation

/// Assemble actual native/container metadata and the source's custom comments.
/// Call inside LocalFolderDocuments.read; all I/O finishes before returning.
public enum LocalMediaMetadataReader {
    /// Artwork reloads do not need another custom-description or date parse.
    public static func artwork(url: URL,
                               checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Data? {
        let picture: Data?
        do { picture = try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: checkCancellation).artwork }
        catch let failure as NativeLocalAudioMetadataReader.Failure {
            guard case .nativeOpen = failure else { throw failure }
            try checkCancellation()
            picture = try CodecLocalMetadataReader.read(url: url, checkCancellation: checkCancellation)
                .streams.compactMap(\.attachedPicture).first
        }
        try checkCancellation()
        return picture
    }

    public static func read(url: URL, timeZone: TimeZone = .current,
                            checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> LocalFileMetadata {
        let native: NativeLocalAudioMetadata
        do { native = try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: checkCancellation) }
        catch let failure as NativeLocalAudioMetadataReader.Failure {
            guard case .nativeOpen = failure else { throw failure }
            try checkCancellation()
            return try readUsingCodec(url: url, timeZone: timeZone, checkCancellation: checkCancellation)
        }
        var seconds = native.estimatedDurationSeconds
        if native.format?.id == kAudioFormatOpus, let frames = native.packetTable?.validFrames,
           frames >= 0, let rate = native.format?.sampleRate, rate.isFinite, rate > 0 {
            // AudioFile's estimate includes Opus pre-skip. Its valid-frame count
            // represents the playable duration returned by Android metadata.
            seconds = Double(frames) / rate
        }
        let result = LocalFileMetadata(title: native.title,
            publicationDate: LocalMetadataDateParser.parse(native.recordedDate, timeZone: timeZone),
            durationMilliseconds: milliseconds(seconds),
            description: try LocalMediaDescriptionReader.read(url: url, checkCancellation: checkCancellation),
            embeddedArtwork: native.artwork)
        try checkCancellation()
        return result
    }

    /// Also exercised directly on the host: macOS natively opens Vorbis while
    /// iOS requires this path. This is not a user preference or test-only stub.
    static func readUsingCodec(url: URL, timeZone: TimeZone = .current,
                               checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> LocalFileMetadata {
        let codec = try CodecLocalMetadataReader.read(url: url, checkCancellation: checkCancellation)
        let primary = codec.streams.first { $0.kind == .audio }
            ?? codec.streams.first { $0.kind == .video && $0.attachedPicture == nil }
        func tag(_ key: String) -> String? {
            codec.tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
                ?? primary?.tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        var seconds = codec.durationMicroseconds.map { Double($0) / 1_000_000 }
        if codec.container == "ogg", let stream = primary, let duration = stream.duration,
           stream.timeBaseNumerator > 0, stream.timeBaseDenominator > 0 {
            var streamSeconds = Double(duration) * Double(stream.timeBaseNumerator) / Double(stream.timeBaseDenominator)
            if stream.codec == "opus", stream.sampleRate > 0 {
                streamSeconds -= Double(max(0, stream.initialPaddingFrames)) / Double(stream.sampleRate)
            }
            seconds = streamSeconds
        }
        let result = LocalFileMetadata(title: tag("title"),
            publicationDate: LocalMetadataDateParser.parse(tag("date") ?? tag("creation_time"), timeZone: timeZone),
            durationMilliseconds: milliseconds(seconds),
            description: try LocalMediaDescriptionReader.read(url: url, checkCancellation: checkCancellation),
            embeddedArtwork: codec.streams.compactMap(\.attachedPicture).first)
        try checkCancellation()
        return result
    }

    /// The source native retriever rounds microseconds to milliseconds. Invalid
    /// or unrepresentable metadata must not trap or become a negative duration.
    static func milliseconds(_ seconds: Double?) -> Int32? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let value = (seconds * 1000).rounded()
        guard value.isFinite, value <= Double(Int32.max) else { return nil }
        return Int32(value)
    }
}
