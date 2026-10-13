import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct CodecLocalMetadataReaderTests {
    private func fixture(_ name: String, folder: String = "VorbisDescriptions") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + folder))
    }
    private func tag(_ key: String, _ tags: [String: String]) -> String? {
        tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    private func temporary(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodecMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    @Test func originalVorbisAndOpusTagsAndImagesSurviveNativeHandleClosure() throws {
        let cases: [(String, String, String?, String, String)] = [
            ("auphonic.ogg", "Title", "2021", "vorbis", "efece7e0b38d8f9eadaeb3482b71a581e099ddf9febe614aed0fe5d5043e8634"),
            ("auphonic.opus", "Title", "2021", "opus", "d641f1cca75de5a37bcd2f235fc0f4803b3c6b8c6cf79f3eafe1a81b81e8656c"),
            ("opus-comment.opus", "Opus Comment Test", nil, "opus", "6d28a981e099f02feb2b32a22b1562780f038657731cd860df3c50ca72abe360")
        ]
        for (name, title, date, codec, imageHash) in cases {
            let value = try CodecLocalMetadataReader.read(url: fixture(name))
            #expect(value.container == "ogg")
            let audio = try #require(value.streams.first { $0.kind == .audio })
            #expect(audio.codec == codec)
            #expect(tag("title", audio.tags) == title)
            #expect(tag("date", audio.tags) == date)
            #expect(tag("comment", audio.tags) == "Summary" || tag("description", audio.tags) == "Summary")
            let pictures = value.streams.compactMap(\.attachedPicture)
            #expect(pictures.count == 1)
            let picture = try #require(pictures.first)
            #expect(SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined() == imageHash)
            #expect(value.durationEstimatedFromBitrate == false)
        }
    }

    @Test func webmDeclaredDurationMatchesAndroidMetadataWithoutPlayerTimelineSubstitution() throws {
        let value = try CodecLocalMetadataReader.read(url: fixture("tone-opus.webm", folder: "StreamingFormats"))
        #expect(value.container.split(separator: ",").contains("matroska"))
        #expect(value.durationMicroseconds == 8_008_000)
        #expect(value.durationEstimatedFromBitrate == false)
        let audio = try #require(value.streams.first { $0.kind == .audio })
        #expect(audio.codec == "opus")
        #expect(audio.sampleRate == 48_000)
        #expect(value.streams.allSatisfy { $0.attachedPicture == nil })
    }

    @Test func actualContentSurvivesMisleadingAndLiteralFilenames() async throws {
        try await temporary { folder in
            let source = try fixture("auphonic.ogg")
            let expected = try CodecLocalMetadataReader.read(url: source)
            for name in ["video.mp4", "no extension", "%2E%2E # 你好.jpg"] {
                let file = folder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: file)
                #expect(try CodecLocalMetadataReader.read(url: file) == expected)
            }
        }
    }

    @Test func cancellationAtEveryObservedBoundaryRetainsOriginalFailureAndAllowsRecovery() throws {
        struct Abort: Error, Equatable { let boundary: Int }
        for name in ["auphonic.ogg", "opus-comment.opus"] {
            let url = try fixture(name)
            let probes = Mutex(0)
            _ = try CodecLocalMetadataReader.read(url: url) { probes.withLock { $0 += 1 } }
            let count = probes.withLock { $0 }
            #expect(count > 10)
            for boundary in 1...count {
                let checks = Mutex(0)
                #expect(throws: Abort(boundary: boundary)) {
                    try CodecLocalMetadataReader.read(url: url) {
                        if checks.withLock({ $0 += 1; return $0 }) == boundary { throw Abort(boundary: boundary) }
                    }
                }
            }
            #expect(try CodecLocalMetadataReader.read(url: url).container == "ogg")
        }
    }

    @Test func rejectsNonlocalMissingDirectoryAndInvalidInputsWithoutEmptySuccess() async throws {
        #expect(throws: CodecLocalMetadataReader.Failure.notLocalFile) {
            try CodecLocalMetadataReader.read(url: URL(string: "https://example.invalid/no-network.webm")!)
        }
        try await temporary { folder in
            #expect(throws: CodecLocalMetadataReader.Failure.notRegularFile) { try CodecLocalMetadataReader.read(url: folder) }
            #expect(throws: (any Error).self) { try CodecLocalMetadataReader.read(url: folder.appendingPathComponent("missing.ogg")) }
            for size in [0, 1, 16, 8192] {
                let file = folder.appendingPathComponent("invalid.ogg")
                try Data(repeating: 0, count: size).write(to: file)
                #expect(throws: (any Error).self) { try CodecLocalMetadataReader.read(url: file) }
            }
        }
    }

    @Test func coordinatedCancellationReleasesOwnershipForFollowingReadsAndDeletion() async throws {
        try await temporary { folder in
            let name = "opus-comment.opus"
            try FileManager.default.copyItem(at: fixture(name), to: folder.appendingPathComponent(name))
            let documents = LocalFolderDocuments(bookmark: try LocalFolderDocuments.makeBookmark(directory: folder))
            let probes = Mutex(0), entered = Mutex(false), release = DispatchSemaphore(value: 0)
            let task = Task {
                try await documents.read(fileNamed: name) { url, check in
                    try CodecLocalMetadataReader.read(url: url) {
                        if probes.withLock({ $0 += 1; return $0 }) == 8 {
                            entered.withLock { $0 = true }; release.wait()
                        }
                        try check()
                    }
                }
            }
            defer { task.cancel(); release.signal() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(entered.withLock { $0 })
            task.cancel(); release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            let fresh = try await documents.read(fileNamed: name) { url, check in
                try CodecLocalMetadataReader.read(url: url, checkCancellation: check)
            }
            #expect(fresh.streams.filter { $0.kind == .audio }.count == 1)
            #expect(fresh.streams.compactMap(\.attachedPicture).first?.count == 131_217)
            #expect(try await documents.delete(fileNamed: name) == .deleted)
        }
    }
}
