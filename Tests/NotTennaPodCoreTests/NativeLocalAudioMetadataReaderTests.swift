import AudioToolbox
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct NativeLocalAudioMetadataReaderTests {
    private func fixture(_ name: String, _ folder: String = "StreamingFormats") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil,
                                       subdirectory: "Fixtures/" + folder))
    }
    private func temporary(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    @Test func opusTitleDateArtworkAndDurationMatchAndroid() throws {
        for (name, title, date, bytes) in [
            ("auphonic.opus", "Title", "2021" as String?, 308),
            ("opus-comment.opus", "Opus Comment Test", nil, 131_217)
        ] {
            let value = try NativeLocalAudioMetadataReader.read(url: fixture(name, "VorbisDescriptions"))
            #expect(value.title == title)
            #expect(value.recordedDate == date)
            #expect(value.artwork?.count == bytes)
            #expect(abs((value.estimatedDurationSeconds ?? 0) - 10) <= 0.1)
        }
    }

    @Test func localFileDurationsAreCorrectWithoutInventedMetadata() throws {
        let mp3 = try #require(Bundle.module.url(forResource: "playback-30sec.mp3", withExtension: nil, subdirectory: "Fixtures"))
        let mp3Value = try NativeLocalAudioMetadataReader.read(url: mp3)
        #expect(abs((mp3Value.estimatedDurationSeconds ?? 0) - 30) <= 0.1)
        #expect(mp3Value.title == nil && mp3Value.recordedDate == nil)
        for name in ["tone.wav", "tone.m4a", "tone.flac"] {
            let value = try NativeLocalAudioMetadataReader.read(url: fixture(name))
            #expect(abs((value.estimatedDurationSeconds ?? 0) - 8) <= 0.1)
            #expect(value.artwork == nil)
        }
    }

    @Test func embeddedArtworkMatchesIndependentBinaryTagExtractionByteForByte() throws {
        var expected = [
            "auphonic.opus": "d641f1cca75de5a37bcd2f235fc0f4803b3c6b8c6cf79f3eafe1a81b81e8656c",
            "opus-comment.opus": "6d28a981e099f02feb2b32a22b1562780f038657731cd860df3c50ca72abe360"
        ]
        #if os(macOS)
        expected["auphonic.ogg"] = "efece7e0b38d8f9eadaeb3482b71a581e099ddf9febe614aed0fe5d5043e8634"
        #endif
        for (name, hash) in expected {
            let value = try NativeLocalAudioMetadataReader.read(url: fixture(name, "VorbisDescriptions"))
            let artwork = try #require(value.artwork)
            #expect(SHA256.hash(data: artwork).map { String(format: "%02x", $0) }.joined() == hash)
        }
        #expect(throws: (any Error).self) {
            try NativeLocalAudioMetadataReader.read(url: fixture("tone-opus.webm"))
        }
    }

    @Test func filenameHintsDoNotOverrideActualContent() async throws {
        try await temporary { folder in
            let original = try fixture("auphonic.opus", "VorbisDescriptions")
            let expected = try NativeLocalAudioMetadataReader.read(url: original)
            for name in ["cover.jpg", "no extension", "%2E%2E # 你好.mp3"] {
                let copy = folder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: original, to: copy)
                #expect(try NativeLocalAudioMetadataReader.read(url: copy) == expected)
            }
        }
    }

    @Test func rejectsRemoteDirectoryMissingAndNonmediaWithoutInventingEmptySuccess() async throws {
        #expect(throws: NativeLocalAudioMetadataReader.Failure.notLocalFile) {
            try NativeLocalAudioMetadataReader.read(url: URL(string: "https://example.invalid/no-network.mp3")!)
        }
        try await temporary { folder in
            #expect(throws: NativeLocalAudioMetadataReader.Failure.notRegularFile) {
                try NativeLocalAudioMetadataReader.read(url: folder)
            }
            #expect(throws: (any Error).self) {
                try NativeLocalAudioMetadataReader.read(url: folder.appendingPathComponent("missing.mp3"))
            }
            for count in [0, 1, 16, 256, 8192] {
                let file = folder.appendingPathComponent("invalid.mp3")
                try Data(repeating: 0, count: count).write(to: file)
                #expect(throws: (any Error).self) { try NativeLocalAudioMetadataReader.read(url: file) }
            }
        }
    }

    @Test func concurrentCoordinatedReadersPreserveOwnershipAndRecoverAfterCancellation() async throws {
        try await temporary { folder in
            let name = "auphonic.opus"
            try FileManager.default.copyItem(at: fixture(name, "VorbisDescriptions"), to: folder.appendingPathComponent(name))
            let documents = LocalFolderDocuments(bookmark: try LocalFolderDocuments.makeBookmark(directory: folder))
            try await withThrowingTaskGroup(of: NativeLocalAudioMetadata.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try await documents.read(fileNamed: name) { url, check in
                            try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: check)
                        }
                    }
                }
                for try await value in group { #expect(value.title == "Title" && value.artwork?.count == 308) }
            }
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await documents.read(fileNamed: name) { url, check in
                    try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: check)
                }
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            let fresh = try await documents.read(fileNamed: name) { url, check in
                try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: check)
            }
            #expect(fresh.title == "Title")
            #expect(try await documents.delete(fileNamed: name) == .deleted)
        }
    }

    @Test func taskCancellationDuringNativeCallbackReleasesCoordinatedAccess() async throws {
        try await temporary { folder in
            let name = "opus-comment.opus"
            try FileManager.default.copyItem(at: fixture(name, "VorbisDescriptions"), to: folder.appendingPathComponent(name))
            let documents = LocalFolderDocuments(bookmark: try LocalFolderDocuments.makeBookmark(directory: folder))
            let probes = Mutex(0), entered = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            let task = Task {
                try await documents.read(fileNamed: name) { url, check in
                    try NativeLocalAudioMetadataReader.read(url: url) {
                        if probes.withLock({ $0 += 1; return $0 }) == 8 {
                            entered.withLock { $0 = true }
                            release.wait() // Test hold on the dedicated native I/O queue.
                        }
                        try check()
                    }
                }
            }
            defer { task.cancel(); release.signal() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered.withLock({ $0 }) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(entered.withLock { $0 })
            task.cancel()
            release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            let recovered = try await documents.read(fileNamed: name) { url, check in
                try NativeLocalAudioMetadataReader.read(url: url, checkCancellation: check)
            }
            #expect(recovered.title == "Opus Comment Test")
            #expect(recovered.artwork?.count == 131_217)
            #expect(try await documents.delete(fileNamed: name) == .deleted)
        }
    }
}
