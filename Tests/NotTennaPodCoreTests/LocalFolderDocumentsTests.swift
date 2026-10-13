import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

/// Stands in for the provider's ubiquitous-item resource keys, which only a device with
/// iCloud Drive can report. Unlisted names are ordinary local files.
final class LocalAvailabilityFixture: Sendable {
    struct ProbeFailure: Error {}
    private struct State {
        var states: [String: LocalDocumentAvailability] = [:]
        var failures: [String: any Error & Sendable] = [:]
        var probed: [String] = []
    }
    private let state = Mutex(State())
    func set(_ name: String, _ value: LocalDocumentAvailability?) { state.withLock { $0.states[name] = value } }
    /// A provider error for `name` (a transient one by default); nil clears every failure.
    func fail(_ name: String?, with error: any Error & Sendable = ProbeFailure()) {
        state.withLock { if let name { $0.failures[name] = error } else { $0.failures = [:] } }
    }
    var probed: [String] { state.withLock { $0.probed } }
    var source: LocalFolderDocuments.AvailabilitySource {
        { url in
            try self.state.withLock { state in
                let name = url.lastPathComponent
                state.probed.append(name)
                if let failure = state.failures[name] { throw failure }
                return state.states[name] ?? .unknown
            }
        }
    }

    /// The legacy stub iCloud leaves for an evicted "name": a small property list. Its bytes,
    /// including the size it records, are never read.
    static func writePlaceholder(in folder: URL, for name: String, size: Int64) throws {
        let stub: [String: Any] = ["NSURLNameKey": name, "NSURLFileSizeKey": size, "NSURLFileResourceTypeKey": "NSURLFileResourceTypeRegular"]
        try PropertyListSerialization.data(fromPropertyList: stub, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("." + name + ".icloud"))
    }
}

struct LocalFolderDocumentsTests {
    private func fixture(availability: LocalFolderDocuments.AvailabilitySource? = nil,
                         _ body: (URL, LocalFolderDocuments) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFolder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: directory)
        try await body(directory, availability.map { LocalFolderDocuments(bookmark: bookmark, availability: $0) }
            ?? LocalFolderDocuments(bookmark: bookmark))
    }

    @Test func providerKeysDecideAvailabilityAndAnOrdinaryFileIsUnknown() async throws {
        #expect(LocalDocumentAvailability(isUbiquitousItem: true, downloadingStatus: .current) == .current)
        #expect(LocalDocumentAvailability(isUbiquitousItem: true, downloadingStatus: .downloaded) == .downloadedStale)
        #expect(LocalDocumentAvailability(isUbiquitousItem: true, downloadingStatus: .notDownloaded) == .notDownloaded)
        #expect(LocalDocumentAvailability(isUbiquitousItem: true, downloadingStatus: nil) == .unknown)
        for ubiquitous in [false, nil] as [Bool?] {
            #expect(LocalDocumentAvailability(isUbiquitousItem: ubiquitous, downloadingStatus: .notDownloaded) == .unknown)
        }
        // The production path reads the real resource keys; a plain local file is not a cloud document.
        try await fixture { folder, documents in
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("plain.mp3"))
            #expect(try LocalFolderDocuments.providerAvailability(folder.appendingPathComponent("plain.mp3")) == .unknown)
            #expect(try await documents.entries().map(\.availability) == [.unknown])
        }
    }

    @Test func listingCarriesEachAvailabilityIntoTheScanWithoutReadingAnyFile() async throws {
        let provider = LocalAvailabilityFixture()
        let states: [LocalDocumentAvailability] = [.current, .downloadedStale, .notDownloaded, .unknown]
        for state in states { provider.set("\(state).mp3", state) }
        try await fixture(availability: provider.source) { folder, documents in
            for state in states { try Data([1, 2]).write(to: folder.appendingPathComponent("\(state).mp3")) }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: false)
            let entries = try await documents.entries()
            for state in states {
                let entry = try #require(entries.first { $0.name == "\(state).mp3" })
                #expect(entry.availability == state && entry.size == 2 && entry.resourceIdentity != nil)
            }
            #expect(entries.first { $0.name == "nested" }?.availability == .unknown)
            #expect(!provider.probed.contains("nested"))
            let input = try await documents.scanInput { url, _ in
                Issue.record("Listing must not read \(url.lastPathComponent)"); return LocalFileMetadata()
            }
            #expect(Set(input.files.map { "\($0.name)=\($0.availability)" }) == Set(states.map { "\($0).mp3=\($0)" }))
            // A directory is never media, but its name is present.
            #expect(Set(input.presentNames ?? []) == Set(states.map { "\($0).mp3" } + ["nested"]))
        }
    }

    @Test func confirmedPlaceholderIsListedUnderItsDocumentNameUntilTheDocumentArrives() async throws {
        let provider = LocalAvailabilityFixture()
        try await fixture(availability: provider.source) { folder, documents in
            let name = "Episode #1 你好.mp3", stub = "." + name + ".icloud"
            try LocalAvailabilityFixture.writePlaceholder(in: folder, for: name, size: 4_242)
            for evidence in [stub, name] {
                // Either the stub or the document's own URL may carry the provider's answer.
                provider.set(stub, nil); provider.set(name, nil); provider.set(evidence, .notDownloaded)
                let entry = try #require(try await documents.entries().first)
                #expect(entry.name == name && entry.availability == .notDownloaded && entry.size == 0)
                #expect(entry.preferredMIMEType == "audio/mpeg" && entry.resourceIdentity == nil && !entry.isDirectory)
                let input = try await documents.scanInput { _, _ in LocalFileMetadata() }
                #expect(input.files.map(\.name) == [name] && input.files.first?.mediaMIMEType == "audio/mpeg")
                #expect(input.documentResources?.isEmpty == true)
            }
            let placeholderIdentity = try #require(try await documents.entries().first?.identity)
            // While both exist the document under its own name wins; then the stub goes.
            provider.set(stub, .notDownloaded)
            try Data(count: 4_242).write(to: folder.appendingPathComponent(name))
            provider.set(name, .current)
            #expect(try await documents.entries().map(\.name) == [name])
            try FileManager.default.removeItem(at: folder.appendingPathComponent(stub))
            let arrived = try #require(try await documents.entries().first)
            #expect(arrived.identity == placeholderIdentity && arrived.availability == .current && arrived.size == 4_242)
        }
    }

    @Test func localFileNamedLikeAPlaceholderStaysAnOrdinaryFile() async throws {
        // No provider evidence: the real resource keys of a local file say nothing about iCloud.
        try await fixture { folder, documents in
            try LocalAvailabilityFixture.writePlaceholder(in: folder, for: "a.mp3", size: 4_242)
            try Data([1]).write(to: folder.appendingPathComponent(".b.mp3.icloud"))
            let entries = try await documents.entries().sorted { $0.name < $1.name }
            #expect(entries.map(\.name) == [".a.mp3.icloud", ".b.mp3.icloud"])
            #expect(entries.allSatisfy { $0.availability == .unknown && $0.resourceIdentity != nil })
        }
        #expect(LocalFolderDocuments.placeholderName(".a.mp3.icloud") == "a.mp3")
        #expect(LocalFolderDocuments.placeholderName("..hidden.icloud") == ".hidden")
        for name in ["a.mp3.icloud", "..icloud", "...icloud", ".icloud", ".a.mp3.ICLOUD"] {
            #expect(LocalFolderDocuments.placeholderName(name) == nil, "\(name)")
        }
    }

    @Test func aStubWhoseDocumentTheProviderCannotAnswerForFailsTheListing() async throws {
        let provider = LocalAvailabilityFixture()
        try await fixture(availability: provider.source) { folder, documents in
            try LocalAvailabilityFixture.writePlaceholder(in: folder, for: "a.mp3", size: 64)
            // The stub says nothing; asking about its document fails for now.
            provider.fail("a.mp3")
            await #expect(throws: LocalAvailabilityFixture.ProbeFailure.self) { try await documents.entries() }
            await #expect(throws: LocalAvailabilityFixture.ProbeFailure.self) { try await documents.scanInput { _, _ in LocalFileMetadata() } }
            // A definite "no such document" leaves an ordinary file of that name.
            for missing: any Error & Sendable in [CocoaError(.fileReadNoSuchFile), CocoaError(.fileNoSuchFile), POSIXError(.ENOENT)] {
                provider.fail("a.mp3", with: missing)
                #expect(try await documents.entries().map { "\($0.name)=\($0.availability)" } == [".a.mp3.icloud=unknown"])
            }
            provider.fail(nil); provider.set("a.mp3", .notDownloaded)
            #expect(try await documents.entries().map { "\($0.name)=\($0.availability)" } == ["a.mp3=notDownloaded"])
        }
    }

    @Test func providerFailureForOneFileFailsTheWholeListing() async throws {
        let provider = LocalAvailabilityFixture()
        provider.fail("b.mp3")
        try await fixture(availability: provider.source) { folder, documents in
            for name in ["a.mp3", "b.mp3", "c.mp3"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
            await #expect(throws: LocalAvailabilityFixture.ProbeFailure.self) { try await documents.entries() }
            await #expect(throws: LocalAvailabilityFixture.ProbeFailure.self) { try await documents.scanInput { _, _ in LocalFileMetadata() } }
            provider.fail(nil)
            #expect(try await documents.entries().count == 3)
        }
    }

    @Test func bookmarkRoundTripListsImmediateChildrenAndFreshChanges() async throws {
        try await fixture { folder, documents in
            let files = ["你好 %.mp3", "Name # ?.ogg", ".hidden.mp3", "%2E%2E.m4a"]
            for name in files { try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name)) }
            let subdirectory = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
            try Data([4]).write(to: subdirectory.appendingPathComponent("inside.mp3"))
            // Serialize and decode just as a future persistent feed record will do.
            let saved = try JSONEncoder().encode(documents.bookmark)
            let reopened = LocalFolderDocuments(bookmark: try JSONDecoder().decode(Data.self, from: saved))
            let entries = try await reopened.entries()
            #expect(Set(entries.map(\.name)) == Set(files + ["nested"]))
            #expect(entries.filter { !$0.isDirectory }.allSatisfy { $0.size == 3 && $0.modified != nil && !$0.isSymbolicLink })
            #expect(entries.first { $0.name == "nested" }?.isDirectory == true)
            try Data([5, 6]).write(to: folder.appendingPathComponent("added.mp3"))
            #expect(try await reopened.entries().first { $0.name == "added.mp3" }?.size == 2)
        }
    }

    @Test func deletionRemovesOnlyNamedFileAndRescanReflectsIt() async throws {
        try await fixture { folder, documents in
            let first = folder.appendingPathComponent("episode #1.mp3")
            let other = folder.appendingPathComponent("keep.mp3")
            try Data([1, 2]).write(to: first); try Data([9]).write(to: other)
            #expect(try await documents.delete(fileNamed: first.lastPathComponent) == .deleted)
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(try Data(contentsOf: other) == Data([9]))
            #expect(try await documents.entries().map(\.name) == ["keep.mp3"])
            #expect(try await documents.delete(fileNamed: first.lastPathComponent) == .alreadyMissing)
        }
    }

    @Test func directoryDeletionAndPathTraversalAreRejectedWithoutMutation() async throws {
        try await fixture { folder, documents in
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let protected = nested.appendingPathComponent("keep.mp3")
            try Data([7]).write(to: protected)
            for name in ["", ".", "..", "../outside.mp3", "/tmp/file.mp3", "nested/keep.mp3", "bad\0name"] {
                await #expect(throws: LocalFolderDocuments.Failure.invalidName) { try await documents.delete(fileNamed: name) }
            }
            await #expect(throws: LocalFolderDocuments.Failure.cannotDeleteDirectory) { try await documents.delete(fileNamed: "nested") }
            #expect(try Data(contentsOf: protected) == Data([7]))
        }
    }

    @Test func symbolicLinkDeletionPreservesTarget() async throws {
        try await fixture { folder, documents in
            let target = folder.appendingPathComponent("keep.mp3")
            let link = folder.appendingPathComponent("link.mp3")
            try Data([4, 5]).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(try await documents.entries().first { $0.name == "link.mp3" }?.isSymbolicLink == true)
            #expect(try await documents.delete(fileNamed: "link.mp3") == .deleted)
            #expect(try Data(contentsOf: target) == Data([4, 5]))
        }
    }

    @Test func cancelledRequestCannotDeleteAndDoesNotPoisonNextOperation() async throws {
        try await fixture { folder, documents in
            let target = folder.appendingPathComponent("keep.mp3")
            try Data([8]).write(to: target)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await documents.delete(fileNamed: "keep.mp3")
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try Data(contentsOf: target) == Data([8]))
            #expect(try await documents.delete(fileNamed: "keep.mp3") == .deleted)
        }
    }

    @Test func invalidBookmarkAndNonFolderInputFail() async throws {
        await #expect(throws: (any Error).self) { try await LocalFolderDocuments(bookmark: Data([0, 1, 2])).entries() }
        #expect(throws: LocalFolderDocuments.Failure.notDirectory) {
            try LocalFolderDocuments.makeBookmark(directory: URL(string: "https://example.invalid")!)
        }
        try await fixture { folder, _ in
            let file = folder.appendingPathComponent("audio.mp3")
            try Data([1]).write(to: file)
            #expect(throws: LocalFolderDocuments.Failure.notDirectory) { try LocalFolderDocuments.makeBookmark(directory: file) }
        }
    }

    @Test func missingFolderFailsInsteadOfReportingAnEmptySuccessfulRefresh() async throws {
        try await fixture { folder, documents in
            try FileManager.default.removeItem(at: folder)
            await #expect(throws: (any Error).self) { try await documents.entries() }
            await #expect(throws: (any Error).self) { try await documents.delete(fileNamed: "episode.mp3") }
        }
    }
    private final class HeldWriterPresenter: NSObject, NSFilePresenter, Sendable {
        typealias Writer = @Sendable ((@Sendable () -> Void)?) -> Void
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let writer = Mutex<Writer?>(nil)
        var waiting: Bool { writer.withLock { $0 != nil } }
        init(url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
        func relinquishPresentedItem(toWriter pending: @escaping Writer) { writer.withLock { $0 = pending } }
        func release() {
            let pending = writer.withLock { let pending = $0; $0 = nil; return pending }
            pending?(nil)
        }
    }

    @Test func cancellationWhileARealFilePresenterBlocksPreventsDeletion() async throws {
        try await fixture { folder, documents in
            let file = folder.appendingPathComponent("held.mp3")
            try Data([1, 9]).write(to: file)
            let presenter = HeldWriterPresenter(url: file)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let deletion = Task { try await documents.delete(fileNamed: "held.mp3") }
            defer { deletion.cancel() }
            let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
            while !presenter.waiting && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(presenter.waiting, "The real coordinator must be waiting on the presenter before cancellation")
            deletion.cancel()
            await #expect(throws: CancellationError.self) { try await deletion.value }
            #expect(try Data(contentsOf: file) == Data([1, 9]))
            presenter.release()
        }
    }

}
