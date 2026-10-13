import CoreMedia
import Foundation

/// Stream indices identify tracks only within this prepared source generation.
struct FFmpegMediaSelection: Sendable {
    var audioTrackID: Int32?
    var videoTrackID: Int32?
    var includeAudio = true
    var includeVideo = true
    static let automatic = FFmpegMediaSelection()
}

struct FFmpegMediaMetadata: Sendable {
    struct Track: Sendable {
        enum Kind: String, Sendable { case audio, video, other }
        let id: Int32
        let kind: Kind
        let codec: String
        let language: String?
        let timeBase: CMTime
        let duration: CMTime?
        let sampleRate, channels: Int
        let channelLayout: String
        let width, height: Int
        let pixelAspectRatio: Double
        let rotationDegrees: Double
        let decodable: Bool
        var title: String? = nil
    }
    /// Positive container timestamp origin removed from emitted episode times.
    let timelineOrigin: CMTime
    let containerName: String
    let tracks: [Track]
    let selectedAudioTrackID, selectedVideoTrackID: Int32?
    let duration: CMTime?
    let sourceSeekable: Bool
}
