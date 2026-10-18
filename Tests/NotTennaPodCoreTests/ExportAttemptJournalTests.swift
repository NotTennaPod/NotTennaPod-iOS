import Foundation
import Testing
@testable import NotTennaPodCore

/// A manual export's record, killed at every point: before the picked location reached the app (after the
/// picker created the file), while the payload was staged, and while it was published. The next launch reports what
/// may be incomplete once, says when the location is unknown, recognises a document published just before the end, and
/// leaves the exports of the running process alone.
@Suite(.serialized)
struct ExportAttemptJournalTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportAttemptJournal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        return root
    }

    /// The picker created the empty document at the chosen place.
    private func pickedDocument(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent("Documents/\(name)")
        try Data().write(to: url)
        return url
    }

    /// The next launch: returns what it recorded for the person.
    private func relaunch(_ journal: ExportAttemptJournal, _ root: URL) -> [PendingNotice] {
        ExportAttemptJournal.simulateProcessEnd()
        let notices = PendingNotices(root: root), before = Set(((try? notices.all()) ?? []).map(\.id))
        journal.recover(notices: notices)
        return ((try? notices.all()) ?? []).filter { !before.contains($0.id) }
    }

    private func records(_ journal: ExportAttemptJournal) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: journal.folder.path)) ?? []
    }

    @Test func aKillBeforeThePickedLocationReachedTheAppSaysTheLocationIsUnknown() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        _ = try journal.begin(name: "nottennapod-feeds-2026-10-09.opml")
        _ = try pickedDocument(root, "nottennapod-feeds-2026-10-09.opml") // created, but its location never arrived
        #expect(relaunch(ExportAttemptJournal(root: root), root).map(\.kind) == [.exportLocationUnknown])
        #expect(records(journal).isEmpty)
        #expect(relaunch(journal, root).isEmpty, "Recorded once")
        #expect(try PendingNotices(root: root).all().count == 1, "Kept until a person sees it")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents/nottennapod-feeds-2026-10-09.opml").path),
                "A file whose location the app never received is not touched")
    }

    @Test func aKillWhileThePayloadWasStagedReportsThePickedDocument() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        let id = try journal.begin(name: "NotTennaPodBackup-2026-10-09.db")
        try journal.chose(id, destination: try pickedDocument(root, "NotTennaPodBackup-2026-10-09.db"))
        #expect(relaunch(journal, root) == [PendingNotice(id: id, kind: .exportMayBeIncomplete, name: "NotTennaPodBackup-2026-10-09.db")])
        #expect(records(journal).isEmpty && relaunch(journal, root).isEmpty)
    }

    @Test func aKillDuringPublicationIsReportedUnlessTheDocumentHoldsThePayload() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        let payload = Data((0..<4_096).map { UInt8($0 % 251) })
        var urls: [String: URL] = [:]
        for name in ["partial.db", "zeros.db", "whole.db"] {
            let id = try journal.begin(name: name)
            let url = try pickedDocument(root, name)
            try journal.chose(id, destination: url)
            try journal.publishing(id, payload: payload)
            urls[name] = url
        }
        // Written in place, ended halfway; the same size but not the payload (preallocated, or other content); and
        // published just before the end.
        try payload.prefix(2_048).write(to: try #require(urls["partial.db"]))
        try Data(count: 4_096).write(to: try #require(urls["zeros.db"]))
        try payload.write(to: try #require(urls["whole.db"]))
        #expect(Set(relaunch(journal, root).compactMap(\.name)) == ["partial.db", "zeros.db"], "A matching size is no proof")
        #expect(records(journal).isEmpty)
        #expect(try Data(contentsOf: try #require(urls["partial.db"])).count == 2_048, "The document is neither repaired nor deleted")
    }

    /// The provider gave no bookmark: the export's result cannot be checked later, so an interruption is reported even
    /// when the document happens to hold the payload.
    @Test func withoutABookmarkAnInterruptionIsAlwaysReported() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root, makeBookmark: { _ in throw CocoaError(.fileReadNoPermission) })
        let payload = Data("<opml/>".utf8)
        let id = try journal.begin(name: "x.opml"), url = try pickedDocument(root, "x.opml")
        try journal.chose(id, destination: url)
        try journal.publishing(id, payload: payload)
        try payload.write(to: url)
        #expect(relaunch(journal, root).map(\.name) == ["x.opml"])
    }

    /// Saving the record can fail (storage full, not writable): the step reports it, and the record still says what
    /// was saved before.
    @Test func aRecordThatCannotBeSavedFailsItsStep() throws {
        let root = try folder(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(ExportAttemptJournal.folderName).path)
            try? FileManager.default.removeItem(at: root)
        }
        let journal = ExportAttemptJournal(root: root)
        let id = try journal.begin(name: "x.opml"), url = try pickedDocument(root, "x.opml")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journal.folder.path)
        #expect(throws: (any Error).self) { try journal.chose(id, destination: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.folder.path)
        #expect(relaunch(journal, root).map(\.kind) == [.exportLocationUnknown], "Still the record from before the picker")
    }

    @Test func resolvedAttemptsLeaveNothingToReport() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        let cancelled = try journal.begin(name: "a.opml")
        journal.resolve(cancelled)
        let published = try journal.begin(name: "b.opml")
        try journal.chose(published, destination: try pickedDocument(root, "b.opml"))
        try journal.publishing(published, payload: Data("abc".utf8))
        journal.resolve(published)
        #expect(relaunch(journal, root).isEmpty && records(journal).isEmpty)
    }

    /// A background launch recovers the attempt with no screen to show it, and the process ends: the next visible launch
    /// still has it.
    @Test func aWarningSurvivesABackgroundLaunchUntilItIsPresented() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        let id = try journal.begin(name: "x.opml")
        #expect(relaunch(journal, root).map(\.kind) == [.exportLocationUnknown]) // background launch, no screen
        #expect(relaunch(journal, root).isEmpty)                                 // the visible launch
        #expect(try PendingNotices(root: root).all().map(\.id) == [id])
        try PendingNotices(root: root).acknowledge(id)
        #expect(try PendingNotices(root: root).all().isEmpty)
    }

    @Test func aGraphStartInTheSameProcessLeavesRunningExportsAlone() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ExportAttemptJournal(root: root)
        let running = try journal.begin(name: "running.opml")
        journal.recover(notices: PendingNotices(root: root)) // a library switch or restart meanwhile
        #expect(try PendingNotices(root: root).all().isEmpty && records(journal).count == 1)
        journal.resolve(running)
        #expect(records(journal).isEmpty)
    }
}
