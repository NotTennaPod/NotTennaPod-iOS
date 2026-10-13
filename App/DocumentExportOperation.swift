import UIKit
import OSLog
import Synchronization
import NotTennaPodCore

/// One OPML export attempt: a dated empty file handed to the system Save picker, then a
/// coordinated write of a payload read only after the destination was chosen (Android reads
/// `DBReader.getFeedList()` after `ACTION_CREATE_DOCUMENT` returns). The attempt owns its staging
/// file, destination scope and write independently of any UI, so hiding progress or leaving the
/// screen never cancels a begun write, and the user's chosen destination is never deleted.
/// The attempt is recorded durably before the picker is presented (`ExportAttemptJournal`), with the destination
/// and its access added when the picker returns and the payload's size and digest before publication; a step whose
/// record cannot be saved fails the export before it reads or writes anything. The write holds the background grant and
/// starts only when admitted: without time (refused, or this background period's time ran out) it parks at once. When
/// the time ends, the write stops: cancellation reaches the publisher and its file coordination (a coordination still
/// waiting stops and changes nothing; an accessor already running finishes, and its verified result counts). It starts
/// again, with a fresh read, when the app is active, but only after any earlier publication of this attempt has settled,
/// so two writers never write the document. An attempt that is cancelled, published and verified, or whose failure was
/// actually on screen is resolved; any other is reported at the next launch.
@MainActor final class DocumentExportOperation: NSObject, UIDocumentPickerDelegate {
    enum Event { case cancelled, writing, succeeded, failed(any Error) }
    enum Phase: Equatable { case choosing, writing, ready, sharing, finished }
    typealias Writer = @Sendable (Data, URL) async throws -> Void
    enum Failure: Error { case invalidPickerResult }

    let picker: UIDocumentPickerViewController
    let stagedFile: URL
    private(set) var phase = Phase.choosing
    private(set) var destination: URL?
    var onEvent: ((Event) -> Void)?
    private let payload: @Sendable () async throws -> Data
    private let write: Writer
    private let stageDirectory: URL
    private var scope: SecurityScope?
    private let journal: ExportAttemptJournal?
    private let grant: BackgroundWorkGrant?
    /// This attempt's record, until it is resolved.
    private(set) var attempt: UUID?
    private var membership: BackgroundWorkGrant.Membership?
    private var work: Task<Void, Never>?
    /// The write stopped because background time ended; it starts again when the app is active.
    private(set) var isParked = false
    /// A read or publication of this attempt is running (including one winding down after it was parked).
    private(set) var isWriting = false
    /// Waiting for an earlier publication to settle before writing again.
    private var resuming = false
    private var generation = 0

    /// Source `dateStampFilename`: US-locale yyyy-MM-dd at picker launch, independent of the
    /// later document `dateCreated` clock.
    static func suggestedName(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "nottennapod-feeds-\(formatter.string(from: now)).opml"
    }

    /// `name` overrides the OPML file name for other source exports sharing this flow (database backup).
    init(stagingRoot: URL, now: Date = Date(), timeZone: TimeZone = .current, name: String? = nil,
         payload: @escaping @Sendable () async throws -> Data, write: @escaping Writer = DocumentExportOperation.coordinatedWrite,
         journal: ExportAttemptJournal? = nil, grant: BackgroundWorkGrant? = nil) throws {
        self.payload = payload; self.write = write; self.journal = journal; self.grant = grant
        stageDirectory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        stagedFile = stageDirectory.appendingPathComponent(name ?? Self.suggestedName(now: now, timeZone: timeZone))
        do {
            try Data().write(to: stagedFile, options: .withoutOverwriting)
            // Recorded before the picker is presented: should the app end before the picked location reaches it, the
            // next launch says an export may be incomplete.
            attempt = try journal?.begin(name: stagedFile.lastPathComponent)
        } catch { try? FileManager.default.removeItem(at: stageDirectory); throw error }
        // No library read or payload exists before destination selection.
        picker = UIDocumentPickerViewController(forExporting: [stagedFile], asCopy: false)
        super.init()
        picker.delegate = self
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }
        cancel()
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker else { return }
        picked(urls)
    }

    /// Picker cancel: no read, no write, no feedback. Only the owned empty staging file is removed.
    func cancel() {
        guard phase == .choosing else { return }
        phase = .finished; removeStage(); resolveRecord(); onEvent?(.cancelled)
    }

    func picked(_ urls: [URL]) {
        guard phase == .choosing else { return }
        guard urls.count == 1, let destination = urls.first else {
            phase = .finished; removeStage(); onEvent?(.failed(Failure.invalidPickerResult)); return
        }
        phase = .writing; self.destination = destination
        let scope = SecurityScope(url: destination); self.scope = scope
        onEvent?(.writing)
        // The destination and its access are durable before any payload work; without them the export does not start.
        if let attempt, let journal {
            do { try journal.chose(attempt, destination: destination) }
            catch { fail(error); return }
        }
        // Only with background time (or in the foreground); otherwise it waits, parked, for the app to be active.
        if admitted() { startWriting(to: destination) }
    }

    /// Joins (or rejoins) the background grant for a write about to start: false when it parked at once (time refused,
    /// or this background period's time ran out).
    private func admitted() -> Bool {
        isParked = false
        guard let grant else { return true }
        if membership == nil {
            membership = grant.join(.init(hasWork: { [weak self] in self?.phase == .writing && self?.isParked == false },
                                          park: { [weak self] in self?.park() },
                                          changed: { [weak self] background in if !background { self?.resumeIfParked() } }))
        } else {
            grant.workStarted()
        }
        return !isParked
    }

    private func startWriting(to destination: URL) {
        generation += 1
        let current = generation
        isWriting = true
        work = Task { [self, payload, write] in
            defer { if current == generation { isWriting = false } }
            do {
                let data = try await payload()
                try Task.checkCancellation()
                // The payload's size and digest are durable before anything is published, or nothing is.
                if let attempt, let journal { try journal.publishing(attempt, payload: data) }
                // Cancellation reaches the publisher; once its accessor runs, the outcome counts whatever happens
                // meanwhile: a write that finished and verified is a published export, not a retracted one.
                try await write(data, destination)
                guard current == generation else { return }
                removeStage()
                phase = .ready
                resolveRecord()
                leaveGrant()
                onEvent?(.succeeded)
            } catch {
                guard current == generation, !isParked else { return }
                fail(error)
            }
        }
    }

    /// Source offers no rollback of a partially written destination; never delete it. The record stays until the
    /// failure is on screen (`failureShown`), or for the next launch.
    private func fail(_ error: any Error) {
        removeStage(); release(); leaveGrant()
        onEvent?(.failed(error))
    }

    /// Background time ended (or was refused): the write stops; it keeps its destination, access and record.
    private func park() {
        guard phase == .writing, !isParked else { return }
        isParked = true
        work?.cancel()
        Logger(subsystem: "org.nottennapod.app", category: "Export").notice("Export stopped by the end of background time; it continues when the app is active")
    }

    /// A scene is active again: once an earlier publication of this attempt has settled (its verified result counts),
    /// a parked write starts again with a fresh read.
    private func resumeIfParked() {
        guard phase == .writing, isParked, !resuming, let destination else { return }
        resuming = true
        let previous = work
        Task { [weak self] in
            await previous?.value
            guard let self else { return }
            resuming = false
            guard phase == .writing, isParked else { return }
            if admitted() { startWriting(to: destination) }
        }
    }

    /// This attempt's failure is on screen: nothing is left to report at the next launch.
    func failureShown() { resolveRecord() }

    private func resolveRecord() {
        guard let attempt else { return }
        self.attempt = nil
        journal?.resolve(attempt)
    }

    private func leaveGrant() { membership?.leave(); membership = nil }

    /// Shares the saved document itself (source ShareCompat stream), keeping destination access
    /// until the system sheet completes.
    func makeShare() -> UIActivityViewController? {
        guard phase == .ready, let destination else { return nil }
        phase = .sharing
        let activity = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
        // The sheet keeps this attempt (and destination access) alive until it completes.
        activity.completionWithItemsHandler = { [self] _, _, _, _ in
            Task { @MainActor in self.release() }
        }
        return activity
    }

    /// Ends this attempt's claim on the destination (success feedback dismissed, share finished,
    /// failure, or UI detached). Idempotent; never removes the user's file.
    func release() {
        scope?.release(); scope = nil
        if phase != .writing { phase = .finished }
    }

    private func removeStage() { try? FileManager.default.removeItem(at: stageDirectory) }

    /// Publishes to the provider-created file (not a second Save As): see `publish`. A size that differs afterwards is
    /// a failed write.
    nonisolated static func coordinatedWrite(_ data: Data, to destination: URL) async throws {
        guard try await publish(data, to: destination) == Int64(data.count) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Source `DatabaseExporter.exportToDocument`: after writing, the destination's size must equal the
    /// bytes written; otherwise the export fails with the source message instead of claiming success.
    nonisolated static func sizeVerifiedWrite(_ data: Data, to destination: URL) async throws {
        try verifyWrittenSize(expected: Int64(data.count), actual: try await publish(data, to: destination))
    }

    /// The payload is staged in this app's storage and verified (read back), then published to the picked
    /// document in one coordinated step: replaced as a whole where the provider allows it within the document's scope,
    /// otherwise (the grant covers the document, not its folder) written in place, which the export's record makes
    /// detectable if it is interrupted. Returns the document's size afterwards. Cancellation stops a coordination still
    /// waiting; one already running finishes and its result counts.
    nonisolated static func publish(_ data: Data, to destination: URL) async throws -> Int64 {
        let worker = Task.detached(priority: .userInitiated) { () throws -> Int64 in
            defer { probe(.finished) }
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            let staged = stage.appendingPathComponent(destination.lastPathComponent)
            try data.write(to: staged)
            guard try Data(contentsOf: staged) == data else { throw CocoaError(.fileWriteUnknown) }
            probe(.staged)
            try Task.checkCancellation()
            let coordinator = CancellableCoordinator()
            return try await withTaskCancellationHandler {
                var coordinationError: NSError?
                var outcome: Result<Int64, any Error>?
                probe(.coordinating)
                coordinator.value.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
                    // Admission before any change: a publication cancelled while it waited writes nothing.
                    guard !Task.isCancelled else { outcome = .failure(CancellationError()); return }
                    probe(.writing)
                    outcome = Result {
                        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged, backupItemName: nil, options: []) }
                        catch { try data.write(to: url, options: []) }
                        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
                    }
                }
                if let coordinationError {
                    if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == NSUserCancelledError { throw CancellationError() }
                    throw coordinationError
                }
                guard let outcome else { throw CancellationError() }
                return try outcome.get()
            } onCancel: { coordinator.value.cancel() }
        }
        // The caller's cancellation (background time ended) reaches the worker and its coordination.
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Where a test holds or observes the publisher (DEBUG): staged, about to coordinate, the accessor writing, done.
    enum PublicationStep: Sendable { case staged, coordinating, writing, finished }
#if DEBUG
    nonisolated static let publicationProbe = Mutex<(@Sendable (PublicationStep) -> Void)?>(nil)
    nonisolated private static func probe(_ step: PublicationStep) { publicationProbe.withLock { $0 }?(step) }
#else
    @inline(__always) nonisolated private static func probe(_ step: PublicationStep) {}
#endif

    struct IncompleteWrite: LocalizedError, Equatable {
        let expected: Int64, actual: Int64
        var errorDescription: String? {
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Unable to write entire database. Expected to write \(format(expected)), but wrote \(format(max(0, actual)))."
        }
    }
    nonisolated static func verifyWrittenSize(expected: Int64, actual: Int64) throws {
        guard expected == actual else { throw IncompleteWrite(expected: expected, actual: actual) }
    }
}

/// `NSFileCoordinator.cancel()` may be called from any thread.
private final class CancellableCoordinator: @unchecked Sendable {
    let value = NSFileCoordinator(filePresenter: nil)
}

@MainActor private final class SecurityScope {
    private let url: URL
    private var acquired: Bool
    init(url: URL) {
        self.url = url
        // False is not an error: own-container destinations need no grant. The write still must succeed.
        acquired = url.startAccessingSecurityScopedResource()
    }
    func release() {
        guard acquired else { return }
        acquired = false; url.stopAccessingSecurityScopedResource()
    }
    isolated deinit { release() }
}
