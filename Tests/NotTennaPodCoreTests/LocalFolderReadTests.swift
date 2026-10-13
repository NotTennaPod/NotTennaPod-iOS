import Foundation
import Darwin
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalFolderReadTests {
    private func fixture(_ body: (URL, LocalFolderDocuments) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRead-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        try await body(folder, LocalFolderDocuments(bookmark: bookmark))
    }

    @Test func nativeTypeAndExactURLFactsAccompanyFreshEnumeration() async throws {
        try await fixture { folder, documents in
            let names = ["你好 # %.mp3", "%2E%2E.png"]
            for name in names { try Data([1, 2]).write(to: folder.appendingPathComponent(name)) }
            let entries = try await documents.entries()
            // POSIX resolves the physical path independently of Foundation's URL
            // normalization, which can retain the /var alias even after resolving.
            let path = try #require(folder.path.withCString { realpath($0, nil) })
            defer { free(path) }
            let physicalFolder = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            let reopened = LocalFolderDocuments(bookmark: documents.bookmark)
            #expect(Set(try await reopened.entries().map(\.identity)) == Set(entries.map(\.identity)))
            for (index, name) in names.enumerated() {
                let entry = try #require(entries.first { $0.name == name })
                #expect(entry.identity == physicalFolder.appendingPathComponent(name).absoluteString)
                #expect(entry.contentTypeIdentifier == (index == 0 ? "public.mp3" : "public.png"))
                #expect(entry.preferredMIMEType == (index == 0 ? "audio/mpeg" : "image/png"))
                #expect(entry.size == 2)
            }
        }
    }

    @Test func coordinatedReaderHandlesLiteralNamesSeekAndClosesBeforeReturn() async throws {
        try await fixture { folder, documents in
            let name = "%2E%2E # 你好.mp3"
            let file = folder.appendingPathComponent(name)
            try Data([0, 1, 2, 3, 4]).write(to: file)
            let bytes = try await documents.read(fileNamed: name) { url, check in
                #expect(!Thread.isMainThread)
                #expect(url.lastPathComponent == name)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try check(); try handle.seek(toOffset: 2)
                return try handle.read(upToCount: 2)
            }
            #expect(bytes == Data([2, 3]))
            #expect(try await documents.delete(fileNamed: name) == .deleted)
        }
    }

    @Test func invalidDirectoryMissingAndCancelledReadsNeverCallReader() async throws {
        try await fixture { folder, documents in
            let invoked = Mutex(false)
            let reader: @Sendable (URL, @Sendable () throws -> Void) throws -> Int = { _, _ in
                invoked.withLock { $0 = true }; return 1
            }
            for name in ["", ".", "..", "../outside", "/tmp/file", "folder/file", "bad\0name"] {
                await #expect(throws: LocalFolderDocuments.Failure.invalidName) { try await documents.read(fileNamed: name, reader) }
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: false)
            await #expect(throws: LocalFolderDocuments.Failure.cannotReadDirectory) {
                try await documents.read(fileNamed: "nested", reader)
            }
            await #expect(throws: (any Error).self) { try await documents.read(fileNamed: "missing.mp3", reader) }
            try Data([1]).write(to: folder.appendingPathComponent("a.mp3"))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await documents.read(fileNamed: "a.mp3", reader)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(invoked.withLock { $0 } == false)
        }
    }

    @Test func readerFailureReleasesAccessForFollowingOperations() async throws {
        try await fixture { folder, documents in
            try Data([1, 2]).write(to: folder.appendingPathComponent("a.mp3"))
            await #expect(throws: CocoaError(.fileReadCorruptFile)) {
                try await documents.read(fileNamed: "a.mp3") { _, _ -> Int in throw CocoaError(.fileReadCorruptFile) }
            }
            #expect(try await documents.read(fileNamed: "a.mp3") { url, _ in try Data(contentsOf: url) } == Data([1, 2]))
            #expect(try await documents.delete(fileNamed: "a.mp3") == .deleted)
        }
    }

    @Test(arguments: [false, true])
    func cancellationDuringReaderDiscardsResultAndDoesNotPoisonNextRead(polls: Bool) async throws {
        try await fixture { folder, documents in
            try Data([9]).write(to: folder.appendingPathComponent("a.mp3"))
            let entered = Mutex(false), release = DispatchSemaphore(value: 0)
            let task = Task {
                try await documents.read(fileNamed: "a.mp3") { url, check in
                    entered.withLock { $0 = true }
                    release.wait() // Test-only hold on the dedicated I/O queue.
                    if polls { try check() }
                    return try Data(contentsOf: url)
                }
            }
            defer { task.cancel(); release.signal() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(entered.withLock { $0 })
            task.cancel(); release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await documents.read(fileNamed: "a.mp3") { url, _ in try Data(contentsOf: url) } == Data([9]))
        }
    }

    @Test func symlinkReadsResolvedFileButDeletionStillRemovesOnlyLink() async throws {
        try await fixture { folder, documents in
            let target = folder.appendingPathComponent("actual.mp3")
            try Data([6, 7]).write(to: target)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.mp3"), withDestinationURL: target)
            let data = try await documents.read(fileNamed: "link.mp3") { url, _ in
                #expect(url.lastPathComponent == "actual.mp3")
                return try Data(contentsOf: url)
            }
            #expect(data == Data([6, 7]))
            #expect(try await documents.delete(fileNamed: "link.mp3") == .deleted)
            #expect(try Data(contentsOf: target) == data)
        }
    }

    private final class HeldReaderPresenter: NSObject, NSFilePresenter, Sendable {
        typealias Reader = @Sendable ((@Sendable () -> Void)?) -> Void
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let reader = Mutex<Reader?>(nil)
        var waiting: Bool { reader.withLock { $0 != nil } }
        init(url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
        func relinquishPresentedItem(toReader pending: @escaping Reader) { reader.withLock { $0 = pending } }
        func release() { let pending = reader.withLock { let value = $0; $0 = nil; return value }; pending?(nil) }
    }

    @Test func cancellationWhilePresenterBlocksReadNeverEntersReader() async throws {
        try await fixture { folder, documents in
            let file = folder.appendingPathComponent("a.mp3")
            try Data([7]).write(to: file)
            let presenter = HeldReaderPresenter(url: file)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let invoked = Mutex(false)
            let task = Task { try await documents.read(fileNamed: "a.mp3") { _, _ in invoked.withLock { $0 = true }; return 1 } }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !presenter.waiting && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(presenter.waiting)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(invoked.withLock { $0 } == false)
            presenter.release()
        }
    }
}
