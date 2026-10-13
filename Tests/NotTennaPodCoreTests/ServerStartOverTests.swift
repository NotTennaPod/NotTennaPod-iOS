import Foundation
import Testing
@testable import NotTennaPodCore

/// `lineage_unknown` and "Start over with the server's library" (PROTOCOL §6.11, §5 "A server lost
/// without a backup", scenario 21 PROTOCOL §16) on the account service against the real server: the account no longer
/// has this library's history, so sync pauses with the page's explanation; starting over keeps this library,
/// inactive with its unsent changes, and attaches to the server's library as a first attachment, replaying nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(10))) struct ServerStartOverTests {
    typealias World = ServerAccountsTests.World

    @Test func anAccountWithoutThisLibrarysHistoryPausesThenStartsOver() async throws {
        let server = try await NTPServerProcess.start()
        defer { server.stop() }
        let world = try World(server: server, admin: try await ServerAccountsTests.AdminSession(server: server))
        defer { world.cleanUp() }
        var paused: [ServerPauseReason] = []
        world.pauseSync = { paused.append($0) }
        var stopped = 0
        world.stopSync = { stopped += 1 }
        let account = try await world.admin.account("alice", password: "alice-password-1")
        let old = try await world.attachEmpty(username: "alice", password: "alice-password-1")
        let oldInstall = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(old)))
        // A change this library has not sent: kept, never discarded (PROTOCOL §5).
        let store = try FeedLibraryStore(url: world.location(old).database)
        _ = try await store.insert(ServerLibraryFixture.fetched("https://example.test/kept.xml"))
        try await store.close()

        // The account goes, and one is made again under the same name: a new lineage (PROTOCOL §11).
        try await world.admin.send("POST", "v1/admin/accounts/\(account)/delete", ["confirm_username": "alice"])
        _ = try await world.admin.account("alice", password: "alice-password-1")
        await world.accounts.checkAccount(force: true)
        #expect(world.accounts.page(otherProvider: false).condition == .needsSignIn)
        try await world.accounts.signInAgain(password: "alice-password-1")
        #expect(paused == [.lineageUnknown], "the exchange pauses")
        var page = world.accounts.page(otherProvider: false)
        #expect(page.condition == .lineageUnknown && page.subtitle == .paused)
        #expect(page.rows == [.provider, .status, .startOver, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        #expect(try world.secrets.installation(library: old, install: oldInstall)?.usableToken == nil, "the other account's token is not kept")

        // Start over: signing in to the server's library is a first attachment with a fresh installation.
        let info = try await world.accounts.info(world.address)
        let pending = try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1")
        #expect(pending.kind == .firstAttachment && pending.installID != oldInstall)
        try await world.accounts.startOver(pending, scene: "scene-1")
        #expect(stopped == 1, "this library's exchange stops")
        #expect(world.registry.library(old)?.state == .inactive, "kept, inactive")
        page = world.accounts.page(otherProvider: false)
        #expect(page.mode == .attaching, "the server's library is prepared while this one stays open: \(page.mode)")
        try await world.waitFor("the empty-account question") { world.accounts.question != nil }
        guard case .emptyAccount(let new) = world.accounts.question else { Issue.record("no question"); return }
        await world.accounts.confirmEmptyAccount(scene: "scene-1")
        try await world.waitFor("the switch") { world.open == .server(new) }
        #expect(new != old && world.registry.library(new)?.state == .active)
        await world.accounts.refresh()
        page = world.accounts.page(otherProvider: false)
        #expect(page.mode == .server && page.condition == nil)
        // The old library and its unsent changes stay on the device; nothing of the old lineage is replayed.
        #expect(try StoreServerLibraryProvisioning().unsentChanges(of: world.location(old)) >= 1)
        #expect(try StoreServerLibraryProvisioning().unsentChanges(of: world.location(new)) == 0)
        try await world.accounts.logout(.goBack, scene: nil)
        #expect(Set(world.accounts.page(otherProvider: false).keptLibraries.map(\.entry.id)) == [old, new])
    }

    /// After Start over, the person logs out with Go back and logs in again. Both lineages are kept,
    /// the account's old library first in the registry: logging in resumes the new library (the one matching the
    /// authenticated account), with its unsent change; choosing a kept library's own Log in keeps that choice; the old
    /// lineage stays inactive and is never resumed by the other account.
    @Test func loggingBackInAfterStartOverResumesTheNewLibrary() async throws {
        let server = try await NTPServerProcess.start()
        defer { server.stop() }
        let world = try World(server: server, admin: try await ServerAccountsTests.AdminSession(server: server))
        defer { world.cleanUp() }
        let account = try await world.admin.account("alice", password: "alice-password-1")
        let old = try await world.attachEmpty(username: "alice", password: "alice-password-1")
        try await world.admin.send("POST", "v1/admin/accounts/\(account)/delete", ["confirm_username": "alice"])
        _ = try await world.admin.account("alice", password: "alice-password-1")
        await world.accounts.checkAccount(force: true)
        try await world.accounts.signInAgain(password: "alice-password-1")
        let info = try await world.accounts.info(world.address)
        try await world.accounts.startOver(try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1"),
                                           scene: nil)
        try await world.waitFor("the empty-account question") { world.accounts.question != nil }
        guard case .emptyAccount(let new) = world.accounts.question else { Issue.record("no question"); return }
        await world.accounts.confirmEmptyAccount(scene: nil)
        try await world.waitFor("the switch") { world.open == .server(new) }
        let newInstall = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(new)))
        // An unsent change in the new library.
        let store = try FeedLibraryStore(url: world.location(new).database)
        _ = try await store.insert(ServerLibraryFixture.fetched("https://example.test/unsent.xml"))
        try await store.close()
        try await world.accounts.logout(.goBack, scene: nil)
        #expect(world.registry.libraries.filter { $0.state == .inactive }.map(\.id) == [old, new], "both kept, the old one first")

        // Logging in again: the library of the authenticated account resumes, under its own installation.
        let pending = try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1")
        #expect(pending.kind == .resume(libraryID: new), "\(pending.kind)")
        #expect(pending.installID == newInstall)
        await world.accounts.discard(pending)
        // A kept library's own Log in keeps that choice: the new one resumes; the old lineage (another account) never does.
        let chosen = try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1", library: new)
        #expect(chosen.kind == .resume(libraryID: new) && chosen.installID == newInstall)
        await world.accounts.discard(chosen)
        let older = try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1", library: old)
        #expect(older.kind == .firstAttachment, "\(older.kind)")
        await world.accounts.discard(older)
        try await world.accounts.confirmResume(try await world.accounts.signIn(world.address, info: info, username: "alice", password: "alice-password-1"),
                                               scene: nil)
        try await world.waitFor("the switch") { world.open == .server(new) }
        #expect(world.registry.library(old)?.state == .inactive, "the old lineage stays inactive")
        #expect(try StoreServerLibraryProvisioning().unsentChanges(of: world.location(new)) >= 1, "the unsent change is the resumed library's")
    }
}
