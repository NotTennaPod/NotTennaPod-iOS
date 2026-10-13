import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// A background download that finishes before the first unlock after a restart. iOS hands over the body while
/// protected files cannot be created or read: the body is moved, its response record waits in memory for that task
/// and is written by the job's next attempt; nothing is deleted, failed or adopted by the wrong job, and the system's
/// completion handler is called once.
@Suite(.serialized) struct BackgroundDeferredCompletionTests {
    /// File operations refused as before the first unlock (EPERM behind a Cocoa no-permission error).
    private final class Refusals: Sendable {
        let move = Mutex(false)
        let write = Mutex(false)
        /// The final rename of the incoming body over the retained one.
        let publish = Mutex(false)
        /// A move that fails for this task's own reason (no space), not because of protected data.
        let moveFailure = Mutex<POSIXError?>(nil)
        /// The process ends right after the final rename: what is on disk then is all a relaunch finds.
        let endAfterPublish = Mutex(false)
        static var locked: NSError {
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        }
    }

    private func downloads(_ refusals: Refusals = .init()) -> BackgroundMediaDownloads {
        BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)", fileAccess: .init(move: { from, to in
            if refusals.move.withLock({ $0 }) { throw Refusals.locked }
            if let failure = refusals.moveFailure.withLock({ $0 }) { throw failure }
            try FileManager.default.moveItem(at: from, to: to)
        }, publish: { incoming, body in
            if refusals.publish.withLock({ $0 }) { throw Refusals.locked }
            guard Darwin.rename(incoming.path, body.path) == 0 else { throw POSIXError(.EIO) }
            if refusals.endAfterPublish.withLock({ $0 }) { throw ProcessEnded() }
        }, writeResponse: { response, files in
            if refusals.write.withLock({ $0 }) { throw Refusals.locked }
            try files.write(response)
        }))
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let files: BackgroundMediaDownloads.Files
        let request = URL(string: "https://example.test/episode.mp3")!
        let record: BackgroundMediaDownloads.TaskRecord
        var description: String { BackgroundMediaDownloads.describe(record) }

        init(root: URL? = nil, folder: String = "media", name: String = "episode-1-download-1.media", library: String? = "library-1") throws {
            self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("Deferred-\(UUID())", isDirectory: true)
            let media = self.root.appendingPathComponent(folder, isDirectory: true)
            destination = media.appendingPathComponent(name)
            files = .init(destination: destination)
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            try Data().write(to: destination)
            // As `transfer` writes it before the task starts.
            record = .init(destination: files.key, base: 0, library: library)
            try files.write(record)
        }

        /// The system's temporary file holding a finished body.
        func location(_ body: Data) throws -> URL {
            let url = root.appendingPathComponent("system-tmp-\(UUID().uuidString)")
            try body.write(to: url)
            return url
        }

        func response(length: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Length": "\(length)", "ETag": "\"v1\"", "Content-Type": "audio/mpeg"])!
        }

        var input: MediaDownloadRequest { .init(source: request.absoluteString, destination: destination) }
    }

    private static let body = Data((0..<5_000).map { UInt8($0 % 251) })

    /// The system's callbacks for one finished task while protected data is unavailable.
    private func finishWhileLocked(_ downloads: BackgroundMediaDownloads, _ fixture: Fixture, task: Int = 7) throws {
        downloads.finishDownloading(task: task, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        downloads.complete(task: task, description: fixture.description, error: nil)
    }

    private func permissions(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - The callback sequence and recovery

    @Test func transferFinishedWhileLockedIsKeptAndAdoptedOnceDataIsAvailable() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        let completions = Mutex(0)
        let completed = AsyncStream<Void>.makeStream()
        downloads.expectEvents { completions.withLock { $0 += 1 }; completed.continuation.yield() }

        downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        #expect(try Data(contentsOf: fixture.files.body) == Self.body, "the body is moved inside the callback")
        #expect(SavedState.isAbsent(fixture.files.responseFile) && downloads.deferredTasks == [7])
        downloads.complete(task: 7, description: fixture.description, error: nil)
        #expect(downloads.unclaimedOutcome(fixture.files.key) == nil, "a missing record while locked is not a bad server response")
        #expect(try Data(contentsOf: fixture.files.body) == Self.body && downloads.deferredTasks == [7])
        downloads.finishEvents()
        downloads.finishEvents()
        for await _ in completed.stream { break }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(completions.withLock { $0 } == 1, "the system's completion handler is called exactly once, without waiting")

        // Protected data becomes available: the job's next attempt writes the record, then validates and publishes.
        refusals.write.withLock { $0 = false }
        let response = try #require(try downloads.finishedResponse(fixture.files, request: fixture.request))
        #expect(response.status == 200 && response.header("ETag") == "\"v1\"" && downloads.deferredTasks.isEmpty)
        guard case .finished(let result) = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input,
                                                                                      capacity: { _ in .max }) else {
            Issue.record("not finished"); return
        }
        #expect(result.size == 5_000 && result.validator == "\"v1\"")
        #expect(try Data(contentsOf: fixture.destination) == Self.body)
    }

    /// The record that waited may be written as soon as the task completes, when protected data came back meanwhile.
    @Test func recordWrittenAtCompletionWhenDataCameBackMeanwhile() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        refusals.write.withLock { $0 = false }
        downloads.complete(task: 7, description: fixture.description, error: nil)
        #expect(downloads.deferredTasks.isEmpty)
        #expect(fixture.files.finishedResponse()?.status == 200)
        guard case .success = downloads.unclaimedOutcome(fixture.files.key) else { Issue.record("not a success"); return }
    }

    /// The process ends before the first unlock: the record in memory is gone. The body is never adopted without it;
    /// the next attempt transfers again from the destination's verified bytes, which stay untouched.
    @Test func withoutTheRecordInMemoryTheBodyIsNeverAdoptedAndTheAttemptStartsAgain() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = Data("verified prefix".utf8)
        try verified.write(to: fixture.destination)
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        try finishWhileLocked(downloads(refusals), fixture)
        #expect(try Data(contentsOf: fixture.files.body) == Self.body, "kept through the locked callbacks")

        let relaunched = downloads()
        #expect(try relaunched.finishedResponse(fixture.files, request: fixture.request) == nil, "a transfer is needed")
        #expect(try Data(contentsOf: fixture.destination) == verified)
        guard case .restartFull = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input,
                                                                             capacity: { _ in .max }) else {
            Issue.record("an unvalidated body was adopted"); return
        }
        #expect(try Data(contentsOf: fixture.destination) == verified)
    }

    // MARK: - Refusals

    @Test func refusedMoveIsAnInterruptionThatDeletesNothing() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = Data("verified prefix".utf8), resume = Data("resume data".utf8)
        try verified.write(to: fixture.destination)
        try fixture.files.writeResumeData(resume)
        let refusals = Refusals(); refusals.move.withLock { $0 = true }
        let downloads = downloads(refusals)
        try finishWhileLocked(downloads, fixture)
        #expect(downloads.unclaimedOutcome(fixture.files.key) == nil, "interrupted, not failed")
        #expect(SavedState.isAbsent(fixture.files.body) && downloads.deferredTasks.isEmpty)
        #expect(try Data(contentsOf: fixture.destination) == verified)
        #expect(try Data(contentsOf: fixture.files.resumeFile) == resume)
        #expect(try fixture.files.checkedTaskRecord() == fixture.record)
    }

    @Test func sidecarsThatCannotBeReadAreKeptNotTakenForABadResponse() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let downloads = downloads()
        downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        try permissions(0, fixture.files.responseFile)
        defer { try? permissions(0o644, fixture.files.responseFile) }
        downloads.complete(task: 7, description: fixture.description, error: nil)
        #expect(downloads.unclaimedOutcome(fixture.files.key) == nil, "not a bad server response")
        #expect(throws: SavedStateUnavailable.self) { try downloads.finishedResponse(fixture.files, request: fixture.request) }
        do {
            _ = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input, capacity: { _ in .max })
            Issue.record("assembled from a record it could not read")
        } catch { #expect(SavedState.isUnavailable(error)) }
        try permissions(0o644, fixture.files.responseFile)
        #expect(try Data(contentsOf: fixture.files.body) == Self.body, "nothing was removed")
        guard case .finished = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input,
                                                                          capacity: { _ in .max }) else {
            Issue.record("not finished"); return
        }
        #expect(try Data(contentsOf: fixture.destination) == Self.body)
    }

    // MARK: - Identity: library moves, new attempts, other jobs

    /// A Keep at logout moves the library's folder while the record waits: the record follows its transfer by library
    /// identity, into the folder where the body is now.
    @Test func recordThatWaitsFollowsItsLibraryWhenTheFolderMoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Deferred-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Fixture(root: root, folder: "Server Libraries/library-1/media")
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        try finishWhileLocked(downloads, before)
        let old = root.appendingPathComponent("Server Libraries/library-1", isDirectory: true)
        let moved = root.appendingPathComponent("Previous Libraries/library-1", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: moved)
        BackgroundMediaDownloads.normalizeRecords(mediaFolder: moved.appendingPathComponent("media", isDirectory: true), identity: "library-1")
        let oldPath = old.standardizedFileURL.path, newPath = moved.standardizedFileURL.path
        downloads.setResolver { destination, library in
            library == "library-1" ? destination.replacingOccurrences(of: oldPath, with: newPath) : destination
        }
        refusals.write.withLock { $0 = false }
        let after = BackgroundMediaDownloads.Files(destination: moved.appendingPathComponent("media/episode-1-download-1.media"))
        #expect(try downloads.finishedResponse(after, request: before.request)?.status == 200)
        #expect(after.finishedResponse() != nil && downloads.deferredTasks.isEmpty)
    }

    /// The record that waits is adopted only by its own transfer: not after a new attempt rewrote the task record, not
    /// for another request, not by another library's transfer, not by another job's destination.
    @Test func recordThatWaitsIsNeverAdoptedByAnotherAttemptRequestLibraryOrJob() throws {
        enum Case: CaseIterable { case newAttempt, otherRequest, otherLibrary, otherJob }
        for scenario in Case.allCases {
            let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let refusals = Refusals(); refusals.write.withLock { $0 = true }
            let downloads = downloads(refusals)
            try finishWhileLocked(downloads, fixture)
            refusals.write.withLock { $0 = false }
            var files = fixture.files, request = fixture.request
            switch scenario {
            case .newAttempt:
                try fixture.files.write(.init(destination: fixture.files.key, base: 2_000, resource: fixture.request,
                                              entityTag: "\"v2\"", total: 9_000, library: "library-1"))
            case .otherRequest:
                request = URL(string: "https://example.test/another-episode.mp3")!
            case .otherLibrary:
                try fixture.files.write(.init(destination: fixture.files.key, base: 0, library: "library-2"))
            case .otherJob:
                files = try Fixture(root: fixture.root, name: "episode-1-download-2.media").files
            }
            #expect(try downloads.finishedResponse(files, request: request) == nil, "\(scenario)")
            #expect(SavedState.isAbsent(files.responseFile) && SavedState.isAbsent(fixture.files.responseFile), "\(scenario)")
            #expect(downloads.deferredTasks == (scenario == .otherJob ? [7] : []), "\(scenario)")
        }
    }

    /// A newer finished body for the destination supersedes a record still waiting for an older task.
    @Test func newerFinishedBodySupersedesAnOlderWaitingRecord() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        try finishWhileLocked(downloads, fixture, task: 7)
        try finishWhileLocked(downloads, fixture, task: 8)
        #expect(downloads.deferredTasks == [8])
    }

    // MARK: - A finished body that cannot be opened now is never deleted, nor a verified prefix
    // truncated

    /// Writes a durable finished response (as `finishDownloading` does when it can).
    private func finished(_ fixture: Fixture, record: BackgroundMediaDownloads.TaskRecord? = nil, status: Int = 200,
                          headers: [String: String]? = nil, body: Data = Self.body) throws {
        try fixture.files.write(record ?? fixture.record)
        try body.write(to: fixture.files.body)
        try fixture.files.write(.init(status: status, url: fixture.request,
                                      headers: headers ?? ["Content-Length": "\(body.count)", "ETag": "\"v1\""]))
    }

    @Test func unavailableBodyDeletesNothingAndKeepsTheVerifiedDestination() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = Data("verified prefix".utf8)
        try verified.write(to: fixture.destination)
        try finished(fixture)
        try permissions(0, fixture.files.body)
        defer { try? permissions(0o644, fixture.files.body) }
        do {
            _ = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input, capacity: { _ in .max })
            Issue.record("assembled a body it could not open")
        } catch { #expect(SavedState.isUnavailable(error)) }
        try permissions(0o644, fixture.files.body)
        #expect(try Data(contentsOf: fixture.files.body) == Self.body, "the finished body stays")
        #expect(fixture.files.finishedResponse() != nil, "its record stays")
        #expect(try Data(contentsOf: fixture.destination) == verified, "the verified destination is not truncated")
        guard case .finished = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input,
                                                                          capacity: { _ in .max }) else {
            Issue.record("not finished"); return
        }
        #expect(try Data(contentsOf: fixture.destination) == Self.body)
    }

    @Test func unavailableDestinationDeletesNothing() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = Data("verified prefix".utf8)
        try verified.write(to: fixture.destination)
        try finished(fixture)
        try permissions(0, fixture.destination)
        defer { try? permissions(0o644, fixture.destination) }
        do {
            _ = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input, capacity: { _ in .max })
            Issue.record("assembled into a destination it could not open")
        } catch { #expect(SavedState.isUnavailable(error)) }
        try permissions(0o644, fixture.destination)
        #expect(try Data(contentsOf: fixture.files.body) == Self.body && fixture.files.finishedResponse() != nil)
        #expect(try Data(contentsOf: fixture.destination) == verified)
    }

    /// A range continuation whose body cannot be read: the verified prefix stays exactly as it was, and so do the files.
    @Test func unavailableRangeBodyLeavesThePrefixAndTheFiles() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prefix = Data(Self.body.prefix(2_000)), rest = Data(Self.body.dropFirst(2_000))
        try prefix.write(to: fixture.destination)
        let record = BackgroundMediaDownloads.TaskRecord(destination: fixture.files.key, base: 2_000, resource: fixture.request,
                                                         entityTag: "\"v1\"", total: 5_000, library: "library-1")
        try finished(fixture, record: record, status: 206,
                     headers: ["Content-Range": "bytes 2000-4999/5000", "ETag": "\"v1\"", "Content-Length": "3000"], body: rest)
        try permissions(0, fixture.files.body)
        defer { try? permissions(0o644, fixture.files.body) }
        do {
            _ = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input, capacity: { _ in .max })
            Issue.record("appended a body it could not open")
        } catch { #expect(SavedState.isUnavailable(error)) }
        try permissions(0o644, fixture.files.body)
        #expect(try Data(contentsOf: fixture.destination) == prefix)
        #expect(try Data(contentsOf: fixture.files.body) == rest && fixture.files.finishedResponse() != nil)
        guard case .finished = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input,
                                                                          capacity: { _ in .max }) else {
            Issue.record("not finished"); return
        }
        #expect(try Data(contentsOf: fixture.destination) == Self.body)
    }

    /// A newer task's move refused before the first unlock: the older completion still retained for the destination
    /// (its body and record) stays until a replacement is actually in place.
    @Test func refusedMoveKeepsAnOlderRetainedCompletion() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let older = Data("older finished body".utf8)
        try finished(fixture, body: older)
        let refusals = Refusals(); refusals.move.withLock { $0 = true }
        let downloads = downloads(refusals)
        try finishWhileLocked(downloads, fixture, task: 9)
        #expect(try Data(contentsOf: fixture.files.body) == older && fixture.files.finishedResponse() != nil)
        #expect(SavedState.isAbsent(fixture.files.incoming))
    }

    /// The incoming body reaches `.body.incoming`, but its final rename over the retained body is
    /// refused. The older completion (its body, its record and a record still waiting in memory) is kept intact.
    @Test func refusedFinalRenameKeepsTheOlderCompletion() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let older = Data("older finished body".utf8)
        try finished(fixture, body: older)
        let refusals = Refusals(); refusals.publish.withLock { $0 = true }
        let first = downloads(refusals)
        try finishWhileLocked(first, fixture, task: 9)
        #expect(try Data(contentsOf: fixture.files.body) == older && fixture.files.finishedResponse()?.header("Content-Length") == "\(older.count)")
        #expect(SavedState.isAbsent(fixture.files.incoming) && first.unclaimedOutcome(fixture.files.key) == nil)
        // An older completion whose record still waits in memory keeps it too.
        let waiting = try Fixture(root: fixture.root, name: "episode-1-download-2.media")
        let deferring = Refusals(); deferring.write.withLock { $0 = true }
        let other = downloads(deferring)
        try finishWhileLocked(other, waiting, task: 7)
        deferring.publish.withLock { $0 = true }
        let newer = Data("newer body".utf8)
        other.finishDownloading(task: 8, description: waiting.description, request: waiting.request,
                                response: waiting.response(length: newer.count), location: try waiting.location(newer))
        #expect(try Data(contentsOf: waiting.files.body) == Self.body && other.deferredTasks == [7])
        deferring.publish.withLock { $0 = false }; deferring.write.withLock { $0 = false }
        #expect(try other.finishedResponse(waiting.files, request: waiting.request)?.header("Content-Length") == "\(Self.body.count)")
    }

    // MARK: - A body and its record are adopted only as the pair written together

    /// Stands for the process ending at that point: nothing after it runs.
    private struct ProcessEnded: Error {}

    /// A verified prefix ABCD and a retained finished range body EFGH (bytes 4–7 of 8) with its record.
    private func rangeCompletion(_ fixture: Fixture) throws {
        try Data("ABCD".utf8).write(to: fixture.destination)
        let record = BackgroundMediaDownloads.TaskRecord(destination: fixture.files.key, base: 4, resource: fixture.request,
                                                         entityTag: "\"old\"", total: 8, library: "library-1")
        try finished(fixture, record: record, status: 206,
                     headers: ["Content-Range": "bytes 4-7/8", "ETag": "\"old\"", "Content-Length": "4"], body: Data("EFGH".utf8))
    }

    /// What a relaunch makes of the destination's finished files: never the new body under the old record.
    private func expectNoMixedAdoption(_ fixture: Fixture, _ case: String) async throws {
        let relaunched = downloads()
        #expect(try relaunched.finishedResponse(fixture.files, request: fixture.request) == nil, "\(`case`)")
        let assembly = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: fixture.input, capacity: { _ in .max })
        guard case .restartFull = assembly else { Issue.record("adopted \(assembly) (\(`case`))"); return }
        #expect(try Data(contentsOf: fixture.destination) == Data("ABCD".utf8), "the verified bytes alone (\(`case`))")
    }

    /// The process ends right after a new body (a full response, wxyz) was renamed over the retained range body,
    /// before the older record was removed: the relaunch never appends wxyz under the older range record.
    @Test func endingRightAfterTheRenameNeverPairsTheNewBodyWithTheOldRecord() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try rangeCompletion(fixture)
        let refusals = Refusals(); refusals.endAfterPublish.withLock { $0 = true }
        let ended = downloads(refusals)
        let wxyz = Data("wxyz".utf8)
        ended.finishDownloading(task: 8, description: fixture.description, request: fixture.request,
                                response: fixture.response(length: wxyz.count), location: try fixture.location(wxyz))
        #expect(try Data(contentsOf: fixture.files.body) == wxyz && !SavedState.isAbsent(fixture.files.responseFile))
        try await expectNoMixedAdoption(fixture, "ended after the rename")
    }

    /// The older record can neither be removed nor replaced (here a refused write: the user-immutable flag), so the
    /// new body's record waits in memory; after a relaunch the older record is still never taken for the new body.
    @Test func olderRecordThatCannotBeRemovedIsNeverTakenForTheNewBody() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try rangeCompletion(fixture)
        #expect(Darwin.chflags(fixture.files.responseFile.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = Darwin.chflags(fixture.files.responseFile.path, 0) }
        let downloads = downloads()
        let wxyz = Data("wxyz".utf8)
        downloads.finishDownloading(task: 8, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: wxyz.count), location: try fixture.location(wxyz))
        #expect(try Data(contentsOf: fixture.files.body) == wxyz && downloads.deferredTasks == [8])
        _ = Darwin.chflags(fixture.files.responseFile.path, 0)
        try await expectNoMixedAdoption(fixture, "older record not removable")
    }

    // MARK: - Assembly publishes the body it validated, never one published during its awaits

    /// The job's request whose representation save (the worker awaits the store there) first runs `meanwhile`.
    private func input(_ fixture: Fixture, meanwhile: @escaping @Sendable () throws -> Void) -> MediaDownloadRequest {
        .init(source: fixture.request.absoluteString, destination: fixture.destination, acceptRepresentation: { _ in try meanwhile() })
    }

    /// A newer finished body (a full response wxyz) is published while the assembly of the retained range body EFGH
    /// awaits its representation save: the assembly appends EFGH under its own record, and leaves wxyz and its record.
    @Test func rangeAssemblyAppendsTheBodyItValidatedNotOnePublishedMeanwhile() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try rangeCompletion(fixture)
        let downloads = downloads()
        let wxyz = Data("wxyz".utf8), location = try fixture.location(wxyz)
        let assembly = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: input(fixture) {
            downloads.finishDownloading(task: 9, description: fixture.description, request: fixture.request,
                                        response: fixture.response(length: wxyz.count), location: location)
        }, capacity: { _ in .max })
        guard case .finished(let result) = assembly else { Issue.record("not finished: \(assembly)"); return }
        #expect(try Data(contentsOf: fixture.destination) == Data("ABCDEFGH".utf8) && result.validator == "\"old\"")
        #expect(try Data(contentsOf: fixture.files.body) == wxyz && fixture.files.finishedResponse()?.header("ETag") == "\"v1\"",
                "the newer body and its record are left alone")
    }

    /// The same for a full response: the held body EFGH is published (copied, since its file was replaced), never wxyz.
    @Test func fullAssemblyPublishesTheBodyItValidatedNotOnePublishedMeanwhile() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("old bytes".utf8).write(to: fixture.destination)
        let efgh = Data("EFGH".utf8)
        try finished(fixture, headers: ["Content-Length": "4", "ETag": "\"old\""], body: efgh)
        let downloads = downloads()
        let wxyz = Data("wxyz".utf8), location = try fixture.location(wxyz)
        let assembly = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: input(fixture) {
            downloads.finishDownloading(task: 9, description: fixture.description, request: fixture.request,
                                        response: fixture.response(length: wxyz.count), location: location)
        }, capacity: { _ in .max })
        guard case .finished(let result) = assembly else { Issue.record("not finished: \(assembly)"); return }
        #expect(try Data(contentsOf: fixture.destination) == efgh && result.validator == "\"old\"")
        #expect(try Data(contentsOf: fixture.files.body) == wxyz && fixture.files.finishedResponse()?.header("ETag") == "\"v1\"",
                "the newer body and its record are left alone")
    }

    /// The attempt is cancelled after the newer body was published during its representation save: nothing of the
    /// newer transfer is removed, and the verified bytes stay as they were.
    @Test func cancelledAssemblyLeavesABodyPublishedMeanwhile() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try rangeCompletion(fixture)
        let downloads = downloads()
        let wxyz = Data("wxyz".utf8), location = try fixture.location(wxyz)
        await #expect(throws: CancellationError.self) {
            _ = try await BackgroundMediaDownloads.assemble(files: fixture.files, input: input(fixture) {
                downloads.finishDownloading(task: 9, description: fixture.description, request: fixture.request,
                                            response: fixture.response(length: wxyz.count), location: location)
                throw CancellationError()
            }, capacity: { _ in .max })
        }
        #expect(try Data(contentsOf: fixture.destination) == Data("ABCD".utf8))
        #expect(try Data(contentsOf: fixture.files.body) == wxyz && fixture.files.finishedResponse()?.header("ETag") == "\"v1\"")
    }

    // MARK: - A task's own failure to keep its body is its outcome, not a superseded callback

    @Test func ownMoveFailureIsDeliveredWithoutAWaiter() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.moveFailure.withLock { $0 = POSIXError(.ENOSPC) }
        let downloads = downloads(refusals)
        try finishWhileLocked(downloads, fixture)
        guard case .failure(let error) = downloads.unclaimedOutcome(fixture.files.key) else { Issue.record("no outcome"); return }
        #expect((error as? POSIXError)?.code == .ENOSPC)
    }

    @Test func ownMoveFailureReachesTheWaitingAttempt() async throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.moveFailure.withLock { $0 = POSIXError(.ENOSPC) }
        let downloads = downloads(refusals)
        let attempt = Task { try await downloads.waitForOutcome(of: 7, at: fixture.destination) }
        while !downloads.isWaiting(at: fixture.destination) { await Task.yield() }
        try finishWhileLocked(downloads, fixture)
        do { try await attempt.value; Issue.record("succeeded") }
        catch { #expect((error as? POSIXError)?.code == .ENOSPC, "the storage error, not a cancellation: \(error)") }
    }

    /// The failed task's error is delivered and stays its own: a replacement task that then finishes (before or after
    /// that delivery) keeps its body and succeeds.
    @Test func ownMoveFailureThenAReplacementTask() throws {
        for interleaved in [false, true] {
            let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let refusals = Refusals(); refusals.moveFailure.withLock { $0 = POSIXError(.ENOSPC) }
            let downloads = downloads(refusals)
            downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                        response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
            if !interleaved { downloads.complete(task: 7, description: fixture.description, error: nil) }
            refusals.moveFailure.withLock { $0 = nil }
            downloads.finishDownloading(task: 8, description: fixture.description, request: fixture.request,
                                        response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
            if interleaved {
                downloads.complete(task: 7, description: fixture.description, error: nil)
                guard case .failure(let error) = downloads.unclaimedOutcome(fixture.files.key) else { Issue.record("no outcome"); return }
                #expect((error as? POSIXError)?.code == .ENOSPC)
            }
            #expect(try Data(contentsOf: fixture.files.body) == Self.body, "the replacement's body is kept")
            downloads.complete(task: 8, description: fixture.description, error: nil)
            guard case .success = downloads.unclaimedOutcome(fixture.files.key) else { Issue.record("the replacement did not succeed"); return }
        }
    }

    // MARK: - The record that waited is published only through the ownership fence

    /// Between the two callbacks a new attempt rewrote the destination's task record (another library's): the
    /// completion writes nothing and leaves the successor's files alone.
    @Test func completionNeverPublishesAWaitingRecordAfterANewAttempt() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        let successor = BackgroundMediaDownloads.TaskRecord(destination: fixture.files.key, base: 0, library: "library-2")
        try fixture.files.write(successor)
        refusals.write.withLock { $0 = false }
        downloads.complete(task: 7, description: fixture.description, error: nil)
        #expect(SavedState.isAbsent(fixture.files.responseFile), "the stale response is never written")
        #expect(try fixture.files.checkedTaskRecord() == successor && downloads.deferredTasks.isEmpty)
        #expect(downloads.unclaimedOutcome(fixture.files.key) == nil)
    }

    /// Between the two callbacks a newer task's body replaced this task's: its completion neither publishes, judges nor
    /// removes anything, and the newer task completes normally.
    @Test func staleCompletionLeavesTheReplacementAlone() throws {
        let fixture = try Fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        downloads.finishDownloading(task: 7, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: Self.body.count), location: try fixture.location(Self.body))
        let newer = Data("newer body".utf8)
        downloads.finishDownloading(task: 8, description: fixture.description, request: fixture.request,
                                    response: fixture.response(length: newer.count), location: try fixture.location(newer))
        refusals.write.withLock { $0 = false }
        downloads.complete(task: 7, description: fixture.description, error: nil)
        #expect(try Data(contentsOf: fixture.files.body) == newer && downloads.deferredTasks == [8])
        #expect(SavedState.isAbsent(fixture.files.responseFile) && downloads.unclaimedOutcome(fixture.files.key) == nil)
        downloads.complete(task: 8, description: fixture.description, error: nil)
        #expect(fixture.files.finishedResponse()?.header("Content-Length") == "\(newer.count)")
        guard case .success = downloads.unclaimedOutcome(fixture.files.key) else { Issue.record("not a success"); return }
    }

    /// Between the two callbacks a Keep moved the library's folder: the completion publishes the record beside the body
    /// where it is now.
    @Test func completionPublishesTheWaitingRecordWhereTheLibraryMovedBetweenCallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Deferred-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Fixture(root: root, folder: "Server Libraries/library-1/media")
        let refusals = Refusals(); refusals.write.withLock { $0 = true }
        let downloads = downloads(refusals)
        downloads.finishDownloading(task: 7, description: before.description, request: before.request,
                                    response: before.response(length: Self.body.count), location: try before.location(Self.body))
        let old = root.appendingPathComponent("Server Libraries/library-1", isDirectory: true)
        let moved = root.appendingPathComponent("Previous Libraries/library-1", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: moved)
        BackgroundMediaDownloads.normalizeRecords(mediaFolder: moved.appendingPathComponent("media", isDirectory: true), identity: "library-1")
        let oldPath = old.standardizedFileURL.path, newPath = moved.standardizedFileURL.path
        downloads.setResolver { destination, library in
            library == "library-1" ? destination.replacingOccurrences(of: oldPath, with: newPath) : destination
        }
        refusals.write.withLock { $0 = false }
        downloads.complete(task: 7, description: before.description, error: nil)
        let after = BackgroundMediaDownloads.Files(destination: moved.appendingPathComponent("media/episode-1-download-1.media"))
        #expect(after.finishedResponse()?.status == 200 && downloads.deferredTasks.isEmpty)
        #expect(try Data(contentsOf: after.body) == Self.body)
    }

    // MARK: - The worker

    private final class UnavailableOnce: MediaTransferring {
        let calls = Mutex(0)
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw SavedStateUnavailable() }
            try Data("complete".utf8).write(to: input.destination)
            return MediaDownloadResult(destination: input.destination, size: 8, validator: nil)
        }
    }

    /// Saved state that cannot be reached now parks the job: no failure is counted or logged, nothing is deleted, and
    /// the next start completes the job.
    @Test func workerTreatsUnavailableSavedStateAsAnInterruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeferredWorker-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episode = ParsedEpisode(identifier: "episode", title: "Episode", media: ParsedMedia(url: "https://example.test/a.mp3", size: 8))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: [episode]),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory, now: Date()))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let worker = MediaDownloadWorker(store: store, transfer: UnavailableOnce(), wait: { _ in }, network: network,
                                         duration: { _ in nil }, artwork: { _ in false })
        #expect(try await worker.run(id: job.id) == .waitingForAccess)
        let waiting = try #require(try await store.downloadJob(id: job.id))
        #expect(waiting.state == .waiting && waiting.countedAttempts == 0 && (waiting.logs ?? []).isEmpty)
        #expect(try await worker.run(id: job.id) == .completed)
        try await store.close()
    }
}
