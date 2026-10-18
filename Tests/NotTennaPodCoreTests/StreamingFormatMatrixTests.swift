import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct StreamingFormatMatrixTests {
    /// Containers Apple's own parser and AVPlayer route can open. WebM/Opus is not one
    /// of them (AudioFileStream reports kAudioFileUnsupportedFileTypeError): the app
    /// identifies WebM as Matroska before this detector runs and plays it through the
    /// bundled decoder, covered end to end by PCMRemoteRoutingTests and
    /// BufferedPCMPlaybackEngineTests ("tone-opus.webm").
    nonisolated static let formats = ["tone.wav", "tone.m4a", "tone-tail.m4a", "tone.aac", "tone.flac",
                          "tone-vorbis.ogg", "tone-opus.ogg"]
    private enum Failure: Error { case timedOut }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: formats)
    func nativeDetectorRecognizesOtherOriginalContainers(name: String) throws {
        let bytes = try Data(contentsOf: fixture(name))
        let detector = try StreamingAudioTypeDetector()
        do {
            try detector.append(bytes)
            let type = try detector.finish()
            print("Detector \(name): type=\(type), examined=\(detector.bytesExamined)/\(bytes.count)")
            #expect(!type.isEmpty)
            #expect(detector.maximumBufferedBytes <= 4096)
        } catch {
            print("Detector \(name): error=\(error), examined=\(detector.bytesExamined)/\(bytes.count)")
            throw error
        }
    }

    @Test(arguments: formats)
    func sourcePlaysOtherOriginalContainersOverHTTP(name: String) async throws {
        let bytes = try Data(contentsOf: fixture(name))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "application/octet-stream"], body: bytes)
        }
        defer { server.stop() }
        let source = try ProgressiveHTTPMediaSource(url: server.url)
        let item = AVPlayerItem(asset: source.asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait {
            let state = await source.snapshot()
            return item.status != .unknown || state.failure != nil
        }
        let state = await source.snapshot()
        print("HTTP source \(name): status=\(item.status.rawValue), type=\(state.contentType ?? "unknown"), duration=\(item.duration.seconds), sourceError=\(state.failure ?? "none"), nativeError=\(String(describing: item.error))")
        try #require(state.failure == nil && item.status == .readyToPlay)
        player.play()
        try await wait { player.currentTime().seconds >= 0.3 || item.status == .failed }
        #expect(player.currentTime().seconds >= 0.3 && item.status == .readyToPlay)
        #expect(item.duration.seconds.isFinite && item.duration.seconds > 0)
    }
}
