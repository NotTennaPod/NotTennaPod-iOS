import UIKit
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted OPML export flow: picker/destination boundary, source progress/success/error/Share
/// composition and lifetime. Picker selection is delivered through the operation's public
/// delegate entry; the real system Save picker is exercised by the OPML export journey test.
@MainActor @Suite(.serialized)
struct OPMLExportFlowTests {
    private final class Host: UIViewController, DocumentExportHost {
        var pickers: [UIDocumentPickerViewController] = []
        var messages: [UIViewController] = []
        var success: (share: (CGRect) -> Void, dismissed: () -> Void)?
        var shares: [UIActivityViewController] = []
        /// The presenter waits (a transition, a screen not attached yet): messages are only queued.
        var holdsMessages = false
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            // The out-of-process system picker is not mounted here; everything else is real UIKit.
            if let picker = controller as? UIDocumentPickerViewController { pickers.append(picker); completion?(); return }
            super.present(controller, animated: animated, completion: completion)
        }
        func presentExportMessage(_ message: UIViewController) {
            messages.append(message)
            if !holdsMessages { present(message, animated: false) }
        }
        func showExportSuccess(share: @escaping (CGRect) -> Void, dismissed: @escaping () -> Void) -> Bool {
            success = (share, dismissed); return true
        }
        func presentExportShare(_ activity: UIActivityViewController, anchor: CGRect) { shares.append(activity) }
    }

    /// Controls when the destination write finishes, to observe in-progress UI.
    private final class Gate: Sendable {
        private let state = Mutex<(open: Bool, failure: String?, writes: [URL])>((false, nil, []))
        func open(failing message: String? = nil) { state.withLock { $0.open = true; $0.failure = message } }
        var writes: [URL] { state.withLock { $0.writes } }
        func write(_ data: Data, _ url: URL) async throws {
            while !state.withLock({ $0.open }) { try await Task.sleep(for: .milliseconds(5)) }
            if let failure = state.withLock({ $0.failure }) {
                throw NSError(domain: "OPMLExportTest", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
            }
            try data.write(to: url)
            state.withLock { $0.writes.append(url) }
        }
    }
    private final class Reads: Sendable {
        let count = Mutex(0)
    }

    private func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }

    private func withFlow(gate: Gate, reads: Reads, payload: String = "<opml/>", write: DocumentExportOperation.Writer? = nil,
                          journal: ExportAttemptJournal? = nil, grant: BackgroundWorkGrant? = nil,
                          payloads: [String]? = nil, onRead: (@Sendable () -> Void)? = nil,
                          _ body: @MainActor (Host, DocumentExportFlow, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLExportFlow-\(UUID())", isDirectory: true)
        let destinations = root.appendingPathComponent("destinations", isDirectory: true)
        try FileManager.default.createDirectory(at: destinations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withViewTestWindow { window, _ in
            let host = Host()
            window.addChild(host); window.view.addSubview(host.view); host.view.frame = window.view.bounds; host.didMove(toParent: window)
            defer { host.presentedViewController?.dismiss(animated: false); host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
            let flow = DocumentExportFlow(host: host, makeOperation: {
                try DocumentExportOperation(stagingRoot: root.appendingPathComponent("stage"),
                    now: Date(timeIntervalSince1970: 1_767_225_600), timeZone: .gmt, payload: {
                        let read = reads.count.withLock { $0 += 1; return $0 }
                        onRead?()
                        return Data((payloads.map { $0[min(read, $0.count) - 1] } ?? payload).utf8)
                    }, write: write ?? { try await gate.write($0, $1) }, journal: journal, grant: grant)
            })
            try await body(host, flow, destinations)
        }
    }

    /// Simulates the system picker moving the staged file to the chosen destination.
    private func choose(_ operation: DocumentExportOperation, in directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(operation.stagedFile.lastPathComponent)
        try FileManager.default.moveItem(at: operation.stagedFile, to: destination)
        operation.documentPicker(operation.picker, didPickDocumentsAt: [destination])
        return destination
    }

    @Test func suggestedNameUsesLaunchDateInUSFormat() throws {
        let instant = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        #expect(DocumentExportOperation.suggestedName(now: instant, timeZone: .gmt) == "nottennapod-feeds-2026-01-01.opml")
        #expect(DocumentExportOperation.suggestedName(now: instant, timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
            == "nottennapod-feeds-2025-12-31.opml")
    }

    @Test func pickerCancelReadsAndWritesNothing() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads) { host, flow, _ in
            flow.begin()
            let picker = try #require(host.pickers.last)
            let staged = try #require(flow.pendingOperationForTesting).stagedFile
            #expect(FileManager.default.fileExists(atPath: staged.path))
            #expect(try Data(contentsOf: staged).isEmpty, "Only an empty named file exists before a destination")
            picker.delegate?.documentPickerWasCancelled?(picker)
            #expect(reads.count.withLock { $0 } == 0)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(host.presentedViewController == nil && host.messages.isEmpty && host.success == nil)
        }
    }

    @Test func destinationThenFreshReadProgressSuccessAndShare() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads, payload: "<opml version=\"2.0\"/>") { host, flow, directory in
            flow.begin()
            // Hold the attempt weakly: the flow and success offer must own it, not the test.
            weak var operation = flow.pendingOperationForTesting
            #expect(reads.count.withLock { $0 } == 0, "No library read before destination selection")
            let staged = try #require(operation).stagedFile
            let destination = try choose(try #require(operation), in: directory)
            try await wait("progress presented") { host.presentedViewController is PleaseWaitController }
            let progress = try #require(host.presentedViewController as? PleaseWaitController)
            let message: UILabel = try #require(find("opmlExportProgressMessage", in: progress.view))
            #expect(message.text == "Please wait…")
            #expect(progress.view.subviews.flatMap(\.subviews).contains { $0 is UIActivityIndicatorView })
            #expect(!progress.view.subviews.flatMap(\.subviews).contains { $0 is UIButton }, "Source progress has no cancel button")
            try await wait("library read after destination") { reads.count.withLock { $0 } == 1 }
            #expect(host.success == nil, "Success only after the write completes")
            gate.open()
            try await wait("success offered") { host.success != nil }
            try await wait("progress dismissed") { host.presentedViewController == nil }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "<opml version=\"2.0\"/>")
            #expect(!FileManager.default.fileExists(atPath: staged.path), "Owned staging removed after success")
            #expect(try #require(operation).phase == .ready, "Success offer retains the finished attempt")
            host.success?.share(.zero)
            let activity = try #require(host.shares.first, "Share must present after the write settled")
            #expect(try #require(operation).phase == .sharing)
            host.success = nil
            #expect(operation != nil, "The share sheet keeps the attempt and destination access alive")
            activity.completionWithItemsHandler?(nil, false, nil, nil)
            try await wait("share released destination") { operation == nil || operation?.phase == .finished }
            #expect(FileManager.default.fileExists(atPath: destination.path), "Share cancellation keeps the saved file")
        }
    }

    /// Source `DatabaseExporter.exportToDocument` compares the destination size with the bytes written.
    @Test func databaseWriteVerifiesDestinationSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLExportSize-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data((0..<65_536).map { UInt8($0 % 251) }), complete = directory.appendingPathComponent("complete.db")
        try await DocumentExportOperation.sizeVerifiedWrite(data, to: complete)
        #expect(try Data(contentsOf: complete) == data)
        #expect(throws: DocumentExportOperation.IncompleteWrite(expected: 65_536, actual: 4_096)) {
            try DocumentExportOperation.verifyWrittenSize(expected: 65_536, actual: 4_096)
        }
        #expect(DocumentExportOperation.IncompleteWrite(expected: 65_536, actual: 4_096).errorDescription
                == "Unable to write entire database. Expected to write 66 KB, but wrote 4 KB.")
    }

    /// A destination that silently keeps only part of the file fails with the source message; no success.
    @Test func truncatingDestinationShowsExportErrorNotSuccess() async throws {
        let gate = Gate(), reads = Reads()
        let truncating: DocumentExportOperation.Writer = { data, url in
            try data.prefix(4).write(to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            try DocumentExportOperation.verifyWrittenSize(expected: Int64(data.count), actual: size)
        }
        try await withFlow(gate: gate, reads: reads, payload: String(repeating: "x", count: 2_000), write: truncating) { host, flow, directory in
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("error presented") { !host.messages.isEmpty }
            let dialog = try #require(host.messages.first as? SourceMessageController)
            let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
            let body: UILabel = try #require(find("sourceMessage", in: dialog.view))
            #expect(title.text == "Export error")
            #expect(body.text == "Unable to write entire database. Expected to write 2 KB, but wrote 4 bytes.")
            #expect(host.success == nil)
        }
    }

    @Test func writeErrorShowsSourceDialogAndRetryIsFreshAttempt() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads) { host, flow, directory in
            gate.open(failing: "Controlled export failure")
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("error presented") { !host.messages.isEmpty }
            let dialog = try #require(host.messages.first as? SourceMessageController)
            let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
            #expect(title.text == "Export error")
            let body: UILabel = try #require(find("sourceMessage", in: dialog.view))
            #expect(body.text == "Controlled export failure")
            let ok: UIButton = try #require(find("sourceMessageOK", in: dialog.view))
            #expect(ok.title(for: .normal) == "OK")
            #expect(host.success == nil)
            ok.sendActions(for: .touchUpInside)
            try await wait("error dismissed") { host.presentedViewController == nil }
            gate.open()
            flow.begin()
            let retry = try #require(flow.pendingOperationForTesting)
            _ = try choose(retry, in: directory.appendingPathComponent("retry", isDirectory: true).creatingDirectory())
            try await wait("retry succeeded") { host.success != nil }
            #expect(reads.count.withLock { $0 } == 2)
        }
    }

    @Test func backHidesProgressOnlyAndCompletionStillOffersSuccess() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads) { host, flow, directory in
            flow.begin()
            let destination = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("progress presented") { host.presentedViewController is PleaseWaitController }
            #expect(host.presentedViewController?.accessibilityPerformEscape() == true)
            try await wait("progress hidden") { host.presentedViewController == nil }
            #expect(gate.writes.isEmpty, "Hiding progress does not cancel or finish the write")
            gate.open()
            try await wait("success after hidden progress") { host.success != nil }
            #expect(gate.writes == [destination])
        }
    }

    @Test func leavingScreenDetachesFeedbackButWriteSettles() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory)
            try await wait("progress presented") { host.presentedViewController is PleaseWaitController }
            flow.detachInterface()
            try await wait("detached progress removed") { host.presentedViewController == nil }
            gate.open()
            try await wait("write settled") { gate.writes == [destination] }
            try await Task.sleep(for: .milliseconds(200))
            #expect(host.success == nil && host.messages.isEmpty && host.presentedViewController == nil)
            #expect(operation.phase == .finished, "Detached success releases destination access")
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// A write finishing while progress is still animating in must still dismiss it and offer success.
    @Test func immediateCompletionDuringProgressAppearanceStillOffersSuccess() async throws {
        let gate = Gate(), reads = Reads()
        gate.open()
        try await withFlow(gate: gate, reads: reads) { host, flow, directory in
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("success offered") { host.success != nil }
            try await wait("no stuck progress") { host.presentedViewController == nil }
        }
    }

    @Test func newerDestinationSupersedesOlderFeedbackWithoutCancellingIt() async throws {
        let gate = Gate(), reads = Reads()
        try await withFlow(gate: gate, reads: reads) { host, flow, directory in
            flow.begin()
            let first = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("first progress") { host.presentedViewController is PleaseWaitController }
            host.presentedViewController?.accessibilityPerformEscape()
            try await wait("first progress hidden") { host.presentedViewController == nil }
            flow.begin()
            let second = try choose(try #require(flow.pendingOperationForTesting),
                                    in: directory.appendingPathComponent("second", isDirectory: true).creatingDirectory())
            gate.open()
            try await wait("both writes settled") { Set(gate.writes) == [first, second] }
            try await wait("one success") { host.success != nil }
            #expect(host.messages.isEmpty)
        }
    }

    // MARK: - An export the system may end

    /// UIKit's background task, as the app's grant sees it.
    private final class Time: BackgroundTimeProviding {
        var isInBackground = false, refuses = false, begun = 0, ended: [Bool] = []
        var expiration: (@MainActor () -> Void)?
        func begin(expired: @escaping @MainActor () -> Void) -> Int? {
            guard !refuses else { return nil }
            begun += 1; expiration = expired; return begun
        }
        func end(_ grant: Int, expired: Bool) { ended.append(expired) }
    }

    private func journal() throws -> (ExportAttemptJournal, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportJournalFlow-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ExportAttemptJournal(root: root), root)
    }
    private func records(_ journal: ExportAttemptJournal) throws -> [ExportAttempt] {
        try ((try? FileManager.default.contentsOfDirectory(at: journal.folder, includingPropertiesForKeys: nil)) ?? []).map {
            try JSONDecoder().decode(ExportAttempt.self, from: Data(contentsOf: $0))
        }
    }

    @Test func theAttemptIsRecordedBeforeThePickerItsDestinationBeforeAnyReadAndResolvedWhenVerified() async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withFlow(gate: gate, reads: reads, journal: journal) { host, flow, directory in
            flow.begin()
            #expect(host.pickers.count == 1)
            let before = try records(journal)
            #expect(before.count == 1 && before[0].destinationName == nil, "Recorded, location unknown, as the picker shows")
            let destination = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("library read") { reads.count.withLock { $0 } == 1 }
            #expect(try records(journal).first?.destinationName == destination.lastPathComponent, "Destination before the payload")
            #expect(try records(journal).first?.destinationBookmark != nil)
            gate.open()
            try await wait("success") { host.success != nil }
            #expect(try records(journal).isEmpty, "Resolved after a verified publication")
            // Cancelled at the picker: resolved too.
            flow.begin()
            #expect(try records(journal).count == 1)
            let picker = try #require(host.pickers.last)
            picker.delegate?.documentPickerWasCancelled?(picker)
            #expect(try records(journal).isEmpty)
        }
    }

    @Test func aShownFailureIsResolvedAndOneNobodySawIsKeptForTheNextLaunch() async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withFlow(gate: gate, reads: reads, journal: journal) { host, flow, directory in
            gate.open(failing: "The provider refused the document")
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("error presented") { !host.messages.isEmpty }
            try await wait("the person was told") { (try? records(journal))?.isEmpty == true }
            host.presentedViewController?.dismiss(animated: false)
            try await wait("dismissed") { host.presentedViewController == nil }
            // The scene went to the background meanwhile: its failure is shown to nobody.
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory.appendingPathComponent("detached", isDirectory: true).creatingDirectory())
            try await wait("progress presented") { host.presentedViewController is PleaseWaitController }
            flow.detachInterface()
            try await wait("detached") { host.presentedViewController == nil }
            // The failure settled: its own staging is gone.
            try await wait("failed") { !FileManager.default.fileExists(atPath: operation.stagedFile.deletingLastPathComponent().path) }
            let kept = try records(journal)
            #expect(kept.count == 1 && kept.first?.destinationName == destination.lastPathComponent)
            #expect(host.messages.count == 1, "Nothing shown")
            ExportAttemptJournal.simulateProcessEnd()
            let notices = PendingNotices(root: root)
            journal.recover(notices: notices)
            #expect(try notices.all().map(\.name) == [destination.lastPathComponent])
        }
    }

    @Test func expirationParksTheWriteAndItContinuesWithAFreshReadWhenActive() async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal(), time = Time()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        try await withFlow(gate: gate, reads: reads, journal: journal, grant: grant) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory)
            try await wait("writing") { reads.count.withLock { $0 } == 1 }
            #expect(time.begun == 0, "In the foreground the export needs no grant")
            flow.detachInterface()
            time.isInBackground = true
            grant.enterBackground()
            #expect(time.begun == 1, "Leaving the app, the export holds the grant")
            let expire = try #require(time.expiration)
            expire()
            #expect(time.ended == [true], "Given back at once")
            #expect(operation.isParked && operation.phase == .writing)
            #expect(try records(journal).count == 1, "Its record stays")
            gate.open()
            // Active again: a fresh read, then the publication (the parked write wrote nothing).
            time.isInBackground = false
            grant.enterForeground()
            try await wait("finished") { gate.writes == [destination] && operation.phase != .writing }
            #expect(reads.count.withLock { $0 } == 2 && gate.writes == [destination])
            #expect(try records(journal).isEmpty && host.messages.isEmpty)
        }
    }

    @Test func aProviderWriteAlreadyRunningWhenTheTimeEndsCounts() async throws {
        let reads = Reads(), (journal, root) = try journal(), time = Time()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        let started = Mutex(false), release = Mutex(false)
        // The provider's accessor is running: cancellation cannot stop it.
        let running: DocumentExportOperation.Writer = { data, url in
            started.withLock { $0 = true }
            while !release.withLock({ $0 }) { await Task.yield() }
            try data.write(to: url)
        }
        try await withFlow(gate: Gate(), reads: reads, write: running, journal: journal, grant: grant) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory)
            try await wait("provider writing") { started.withLock { $0 } }
            time.isInBackground = true
            grant.enterBackground()
            let expire = try #require(time.expiration)
            expire()
            release.withLock { $0 = true }
            try await wait("published") { operation.phase != .writing }
            #expect(try Data(contentsOf: destination) == Data("<opml/>".utf8))
            #expect(reads.count.withLock { $0 } == 1, "Its outcome counted: not written again")
            #expect(try records(journal).isEmpty)
            time.isInBackground = false
            grant.enterForeground()
            #expect(reads.count.withLock { $0 } == 1)
        }
    }

    /// The picker returns while the app is already in the background, and the grant is refused
    /// or this period's time ran out: nothing is read or written until the app is active.
    @Test(arguments: [false, true])
    func withoutBackgroundTimeAtPickerCompletionNothingRunsUntilActive(exhausted: Bool) async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal(), time = Time()
        defer { try? FileManager.default.removeItem(at: root) }
        var other = false
        let grant = BackgroundWorkGrant(time: time, participants: [.init(hasWork: { other }, park: {})], pollInterval: .seconds(30))
        try await withFlow(gate: gate, reads: reads, journal: journal, grant: grant) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            time.isInBackground = true
            if exhausted {
                other = true
                grant.enterBackground()
                let expire = try #require(time.expiration)
                expire()
                other = false
            } else {
                time.refuses = true
            }
            let destination = try choose(operation, in: directory)
            #expect(operation.isParked && !operation.isWriting, "Parked at once")
            #expect(reads.count.withLock { $0 } == 0 && gate.writes.isEmpty)
            #expect(try records(journal).first?.destinationName == destination.lastPathComponent, "Its record waits with it")
            time.isInBackground = false; time.refuses = false
            gate.open()
            grant.enterForeground()
            try await wait("written when active") { gate.writes == [destination] && operation.phase != .writing }
            #expect(reads.count.withLock { $0 } == 1)
            #expect(try records(journal).isEmpty)
        }
    }

    /// The real publisher. The time ends while the first publication is staged; the app is
    /// active again before it finished: cancellation reaches it, the next write waits for it to settle, and the stale
    /// one never writes the document.
    @Test func cancellationReachesThePublisherAndAStalePublicationNeverWrites() async throws {
        let reads = Reads(), (journal, root) = try journal(), time = Time()
        defer { try? FileManager.default.removeItem(at: root); DocumentExportOperation.publicationProbe.withLock { $0 = nil } }
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        let staged = Mutex(0), writes = Mutex(0), finished = Mutex(0), held = DispatchSemaphore(value: 0)
        DocumentExportOperation.publicationProbe.withLock { $0 = { step in
            switch step {
            case .staged: if staged.withLock({ $0 += 1; return $0 }) == 1 { held.wait() }
            case .writing: writes.withLock { $0 += 1 }
            case .finished: finished.withLock { $0 += 1 }
            case .coordinating: break
            }
        } }
        try await withFlow(gate: Gate(), reads: reads, write: DocumentExportOperation.coordinatedWrite, journal: journal, grant: grant,
                           payloads: ["old", "new"]) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory)
            try await wait("first publication staged") { staged.withLock { $0 } == 1 }
            time.isInBackground = true
            grant.enterBackground()
            let expire = try #require(time.expiration)
            expire()
            time.isInBackground = false
            grant.enterForeground() // active again before the first publication finished
            held.signal()
            try await wait("both publications settled") { finished.withLock { $0 } == 2 && operation.phase != .writing }
            #expect(writes.withLock { $0 } == 1, "The stale publication wrote nothing")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
            #expect(reads.count.withLock { $0 } == 2)
            #expect(try records(journal).isEmpty)
        }
    }

    /// A publication waiting for another coordinated writer is cancelled when the time ends.
    @Test func aPublicationWaitingForCoordinationStopsWhenTheTimeEnds() async throws {
        let reads = Reads(), (journal, root) = try journal(), time = Time()
        defer { try? FileManager.default.removeItem(at: root); DocumentExportOperation.publicationProbe.withLock { $0 = nil } }
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        let coordinating = Mutex(0), writes = Mutex(0), finished = Mutex(0), goAhead = DispatchSemaphore(value: 0)
        DocumentExportOperation.publicationProbe.withLock { $0 = { step in
            switch step {
            case .coordinating: if coordinating.withLock({ $0 += 1; return $0 }) == 1 { goAhead.wait() }
            case .writing: writes.withLock { $0 += 1 }
            case .finished: finished.withLock { $0 += 1 }
            case .staged: break
            }
        } }
        try await withFlow(gate: Gate(), reads: reads, write: DocumentExportOperation.coordinatedWrite, journal: journal, grant: grant,
                           payloads: ["old", "new"]) { host, flow, directory in
            flow.begin()
            let operation = try #require(flow.pendingOperationForTesting)
            let destination = try choose(operation, in: directory)
            try await wait("about to coordinate") { coordinating.withLock { $0 } == 1 }
            // Another writer (a provider sync) holds the document.
            let holding = Reads(), release = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [], error: nil) { _ in
                    holding.count.withLock { $0 = 1 }
                    release.wait()
                }
            }
            try await wait("held by another writer") { holding.count.withLock { $0 } == 1 }
            goAhead.signal()
            time.isInBackground = true
            grant.enterBackground()
            let expire = try #require(time.expiration)
            expire()
            try await wait("the waiting publication stopped") { finished.withLock { $0 } == 1 && !operation.isWriting }
            #expect(writes.withLock { $0 } == 0)
            release.signal()
            time.isInBackground = false
            grant.enterForeground()
            try await wait("written when active") { operation.phase != .writing }
            #expect(writes.withLock { $0 } == 1)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        }
    }

    /// A record that cannot be saved stops the export before it reads or writes anything, with
    /// the destination writable.
    @Test func aRecordThatCannotBeSavedStopsTheExportBeforeAnyReadOrWrite() async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        gate.open()
        try await withFlow(gate: gate, reads: reads, journal: journal) { host, flow, directory in
            flow.begin()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journal.folder.path)
            let destination = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("error shown") { !host.messages.isEmpty }
            #expect(reads.count.withLock { $0 } == 0 && gate.writes.isEmpty)
            #expect(try Data(contentsOf: destination).isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.folder.path)
        }
        // At publication: the payload's record cannot be saved, so nothing is published.
        let folder = journal.folder.path
        try await withFlow(gate: gate, reads: reads, journal: journal, onRead: {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        }) { host, flow, directory in
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory.appendingPathComponent("second", isDirectory: true).creatingDirectory())
            try await wait("error shown") { !host.messages.isEmpty }
            #expect(gate.writes.isEmpty, "Nothing published without its record")
        }
    }

    /// A failure whose dialog is only queued has not been seen: its record stays until the
    /// dialog is on screen.
    @Test func aFailureIsResolvedOnlyOnceItsDialogIsOnScreen() async throws {
        let gate = Gate(), reads = Reads(), (journal, root) = try journal()
        defer { try? FileManager.default.removeItem(at: root) }
        gate.open(failing: "The provider refused the document")
        try await withFlow(gate: gate, reads: reads, journal: journal) { host, flow, directory in
            host.holdsMessages = true
            flow.begin()
            _ = try choose(try #require(flow.pendingOperationForTesting), in: directory)
            try await wait("queued") { !host.messages.isEmpty }
            #expect(try records(journal).count == 1, "Queued, not seen: kept for the next launch")
            host.present(host.messages[0], animated: false)
            try await wait("seen") { (try? records(journal))?.isEmpty == true }
        }
    }

    @Test func publicationReplacesTheDocumentWhereAllowedAndWritesItInPlaceOtherwise() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLExportPublish-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let data = Data((0..<70_000).map { UInt8($0 % 251) })
        func identity(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
        let replaced = directory.appendingPathComponent("replaced.db")
        try Data().write(to: replaced)
        let placeholder = try identity(replaced)
        try await DocumentExportOperation.sizeVerifiedWrite(data, to: replaced)
        #expect(try Data(contentsOf: replaced) == data)
        #expect(try identity(replaced) != placeholder, "Replaced as a whole: never a half-written document")
        // A grant for the document only: its folder cannot take a replacement, so it is written in place.
        let inPlace = directory.appendingPathComponent("in-place.opml")
        try Data().write(to: inPlace)
        let document = try identity(inPlace)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try await DocumentExportOperation.coordinatedWrite(data, to: inPlace)
        #expect(try Data(contentsOf: inPlace) == data && identity(inPlace) == document)
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
}

private extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true); return self
    }
}
