import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The reference phones (the local-only fields at every step): what each phone must show, computed from
/// the generated actions alone — which phone did what, in which order, and what each exchange delivered — never from the
/// projector, the overlays or the phone's own rows.
///
/// Registers (an episode's favorite and play state, PROTOCOL §7: the last explicit write in fact order wins; facts are
/// ordered by their normalized time, here the order the steps made them). An action that changes nothing a person sees
/// makes no fact and is no write. A dismissal (NEW to unplayed: Remove from inbox, a queue add) is a conditional effect,
/// not an unplayed write: in fact order it turns NEW into unplayed and leaves any other state (PROTOCOL §7.4). A phone
/// shows its pulled base folded in fact order, then its own unretired effects in order on top (PROTOCOL §6.8). An effect
/// the reference cannot value (a player action) is unknown: a register whose shown value depends on it is not compared
/// until a later known write decides it.
///
/// Delivery: an author's effects are retired (in its base, and on the server) once its outbox is seen empty — every
/// effect the reference holds is a fact the phone made (each write is checked against the phone's outbox when it is
/// made); an exchange that may have pushed leaves them possibly retired. Another phone's effect reaches a phone's base
/// certainly when that phone stands at the server's head after the effect was on the server, possibly when it pulled at
/// all. Every placement the uncertain effects allow is folded; a register is compared only when they all agree.
///
/// Downloads (local only): an episode's finished download and its active transfer, from the requests, cancels, finishes and
/// deletions made on that phone.
final class ReferencePhones: @unchecked Sendable {
    enum Register: Hashable {
        case favorite(String)
        case playState(String)
        /// Queue membership (PROTOCOL §7.6: explicit adds, removals and clears, the last in order wins; a filing's
        /// automatic add is unknown here).
        case queued(String)
    }

    enum Effect: Equatable {
        /// A register write (nil: a value the reference cannot know).
        case set(Int?)
        /// A dismissal: NEW becomes unplayed, any other state stays.
        case dismiss
    }

    struct Write {
        var order: Int
        var side: String
        var effect: Effect
        var retired = false
        var maybeRetired = false
    }

    private var tick = 0
    private var writes: [Register: [Int]] = [:]
    private var all: [Write] = []
    private var onServer: Set<Int> = [], maybeOnServer: Set<Int> = []
    private var seen: [String: Set<Int>] = [:], maybeSeen: [String: Set<Int>] = [:]
    /// The value before any write (an imported episode's state); a favorite is otherwise false, a play state unknown.
    var initial: [Register: Int] = [:]
    /// Episodes the reference stops following (an unsubscribed podcast's, an item whose GUID changed), by wire or identifier.
    private(set) var excludedWires: Set<String> = []
    private(set) var excludedIdentifiers: Set<String> = []
    private var downloaded: [String: Set<String>] = [:], transfers: [String: Set<String>] = [:]
    /// Comparisons made, and registers not compared because their shown value depends on an uncertain delivery or an
    /// unknown write.
    private(set) var compared = 0, undecided = 0, downloadsCompared = 0

    // MARK: Actions

    func record(_ register: Register, _ effect: Effect, side: String) {
        tick += 1
        writes[register, default: []].append(all.count)
        all.append(Write(order: tick, side: side, effect: effect))
    }

    func write(_ register: Register, _ value: Int?, side: String) { record(register, .set(value), side: side) }
    func favorite(_ wire: String, _ value: Bool, side: String) { write(.favorite(wire), value ? 1 : 0, side: side) }
    func playState(_ wire: String, _ value: EpisodePlayState?, side: String) { write(.playState(wire), value?.rawValue, side: side) }
    func dismiss(_ wire: String, side: String) { record(.playState(wire), .dismiss, side: side) }
    func queued(_ wire: String, _ member: Bool?, side: String) { write(.queued(wire), member.map { $0 ? 1 : 0 }, side: side) }

    func exclude(wires: some Sequence<String>) { excludedWires.formUnion(wires) }
    func exclude(identifiers: some Sequence<String>) { excludedIdentifiers.formUnion(identifiers) }

    func requestDownload(_ wire: String, side: String) {
        if !(downloaded[side]?.contains(wire) ?? false) { transfers[side, default: []].insert(wire) }
    }
    func cancelTransfer(_ wire: String, side: String) { transfers[side]?.remove(wire) }
    func finishDownload(_ wire: String, side: String) { transfers[side]?.remove(wire); downloaded[side, default: []].insert(wire) }
    func deleteDownload(_ wire: String, side: String) { downloaded[side]?.remove(wire) }

    /// What an engine run on `side` delivered: `outboxEmpty` (every fact of the phone retired), `pushed` (it may have sent),
    /// `atHead` (it stands at the server's head).
    func observe(side: String, outboxEmpty: Bool, pushed: Bool, atHead: Bool) {
        for index in all.indices where all[index].side == side && !all[index].retired {
            if outboxEmpty {
                all[index].retired = true; all[index].maybeRetired = false
                onServer.insert(index); maybeOnServer.remove(index); seen[side, default: []].insert(index)
            } else if pushed {
                all[index].maybeRetired = true
                maybeOnServer.insert(index)
            }
        }
        if atHead {
            seen[side, default: []].formUnion(onServer)
            maybeSeen[side, default: []].formUnion(maybeOnServer)
        } else {
            maybeSeen[side, default: []].formUnion(onServer.union(maybeOnServer))
        }
    }

    // MARK: Expectations

    /// `start` with `effects` applied in fact order.
    private func fold(_ start: Int?, _ effects: [Int]) -> Int? {
        var value = start
        for index in effects.sorted(by: { all[$0].order < all[$1].order }) {
            switch all[index].effect {
            case .set(let written): value = written
            case .dismiss: if value == EpisodePlayState.new.rawValue { value = EpisodePlayState.unplayed.rawValue }
            }
        }
        return value
    }

    /// The value `side` must show for `register`, or nil when the actions do not decide it.
    func expected(_ register: Register, side: String) -> Int?? {
        let known = seen[side] ?? [], possible = maybeSeen[side] ?? []
        var base: [Int] = [], pending: [Int] = [], uncertain: [Int] = []
        for index in writes[register] ?? [] {
            let write = all[index]
            if known.contains(index) || (write.side == side && write.retired) { base.append(index) }
            else if write.side == side { if write.maybeRetired { uncertain.append(index) } else { pending.append(index) } }
            else if possible.contains(index) { uncertain.append(index) }
        }
        guard uncertain.count <= 8 else { return nil }
        let start = initial[register] ?? Self.defaultValue(register)
        var shown = Set<Int?>()
        // Each uncertain effect is in the base, or not: this phone's own then still masks it as an overlay.
        for placement in 0..<(1 << uncertain.count) {
            var inBase = base, overlay = pending
            for (bit, index) in uncertain.enumerated() {
                if placement & (1 << bit) != 0 { inBase.append(index) } else if all[index].side == side { overlay.append(index) }
            }
            shown.insert(fold(fold(start, inBase), overlay))
            if shown.count > 1 { return nil }
        }
        guard let only = shown.first else { return nil }
        return .some(only)
    }

    static func defaultValue(_ register: Register) -> Int? {
        if case .favorite = register { return 0 }
        return nil
    }

    private(set) var queueCompared = 0

    /// The differences between the reference and what `side` shows now.
    func differences(side: String, episodes: [(wire: String, identifier: String, state: EpisodeUserState)], activeTransfers: Set<String>,
                     queue: Set<String>) -> [String] {
        var found: [String] = []
        var shown = Set<String>()
        for episode in episodes where !excludedWires.contains(episode.wire) && !excludedIdentifiers.contains(episode.identifier) {
            shown.insert(episode.wire)
            if let value = expected(.queued(episode.wire), side: side), let value {
                queueCompared += 1
                if value != (queue.contains(episode.wire) ? 1 : 0) {
                    found.append("\(side) \(episode.wire) queued: shows \(queue.contains(episode.wire)), the reference \(value == 1)")
                }
            }
            for (register, actual) in [(Register.favorite(episode.wire), episode.state.isFavorite ? 1 : 0),
                                       (Register.playState(episode.wire), episode.state.playState.rawValue)] {
                guard let value = expected(register, side: side), let value else { undecided += 1; continue }
                compared += 1
                if value != actual { found.append("\(side) \(register): shows \(actual), the reference \(value)") }
            }
            downloadsCompared += 1
            let isDownloaded = downloaded[side]?.contains(episode.wire) ?? false
            if episode.state.isDownloaded != isDownloaded {
                found.append("\(side) \(episode.wire) downloaded: shows \(episode.state.isDownloaded), the reference \(isDownloaded)")
            }
            let transferring = transfers[side]?.contains(episode.wire) ?? false
            if activeTransfers.contains(episode.wire) != transferring {
                found.append("\(side) \(episode.wire) transfer: shows \(activeTransfers.contains(episode.wire)), the reference \(transferring)")
            }
        }
        for wire in (downloaded[side] ?? []).union(transfers[side] ?? []) where !shown.contains(wire) && !excludedWires.contains(wire) {
            found.append("\(side) \(wire): the reference's download or transfer is not shown")
        }
        return found
    }
}

extension ServerChangeSetCaptureTests.Run {
    typealias Side = ServerChangeSetCaptureTests.Side

    func wire(_ side: Side, _ episode: Int64) async throws -> String? { try await side.store.wireEpisodeForTesting(episode) }

    /// Whether `side` stands at the server's head (the read API's).
    func atHead(_ side: Side) async throws -> Bool {
        guard let reader else { return false }
        let head = try await reader.send("GET", "v1/read/summary")["head"]?["seq"]?.integerValue
        let cursor = try side.phone.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first.flatMap { $0 }.flatMap { try? SyncCursor(encoded: $0) }
        return head != nil && cursor?.seq == head
    }

    /// Tells the reference what an engine run on `side` delivered.
    func observe(_ side: Side, pushed: Bool = true) async throws {
        let empty = try side.phone.rows("SELECT count(*) FROM ntp_outbox") == [["0"]]
        reference.observe(side: side.name, outboxEmpty: empty, pushed: pushed, atHead: try await atHead(side))
    }

    /// Each local episode's wire: its root, not an alias a GUID change or a merge redirects (PROTOCOL §9.7).
    func wires(_ side: Side) throws -> [Int64: String] {
        var wires: [Int64: String] = [:]
        for row in try side.phone.rows("SELECT local_id, episode_id FROM ntp_episodes WHERE local_id IS NOT NULL ORDER BY merged_into IS NOT NULL, episode_id") {
            if let local = row[0].flatMap(Int64.init), let wire = row[1], wires[local] == nil { wires[local] = wire }
        }
        return wires
    }

    /// What `side` shows that the reference does not expect.
    func referenceDifferences(_ side: Side) async throws -> [String] {
        let wires = try wires(side)
        // An episode merged into another (PROTOCOL §7.7) takes the survivor's merged state: both leave the reference.
        for row in try side.phone.rows("SELECT episode_id, merged_into FROM ntp_episodes WHERE merged_into IS NOT NULL") {
            reference.exclude(wires: row.compactMap { $0 })
        }
        let episodes = try await side.store.feeds().flatMap(\.episodes).compactMap { episode in
            wires[episode.id].map { (wire: $0, identifier: episode.details.identifier ?? "", state: episode.userState) }
        }
        let transfers = Set(try await side.store.downloadJobs().filter { $0.state.isActive }.compactMap { wires[$0.episodeID] })
        let queue = Set(try await side.store.queue().compactMap { wires[$0.id] })
        return reference.differences(side: side.name, episodes: episodes, activeTransfers: transfers, queue: queue)
    }

    /// The reference's starting queue: every episode the phones show now is out of the queue, except what the imported
    /// file queued.
    func startQueue(imported: Set<String>) async throws {
        for side in sides {
            let wires = try wires(side)
            for episode in try await side.store.feeds().flatMap(\.episodes) {
                if let wire = wires[episode.id] { reference.initial[.queued(wire)] = imported.contains(episode.details.identifier ?? "") ? 1 : 0 }
            }
        }
    }

    /// The imported podcast on both phones; the reference starts from what the imported file held.
    func adoptImport() async throws {
        for side in sides {
            guard let feed = try await side.store.feeds().first(where: { $0.source.hasSuffix("/four.xml") }) else {
                problems.append("\(side.name): the imported podcast is not shown")
                throw ServerChangeSetCaptureTests.CaptureFailure()
            }
            for episode in feed.episodes {
                guard let wire = try await wire(side, episode.id) else { continue }
                switch episode.details.identifier {
                case "four-1": reference.initial[.favorite(wire)] = 1
                case "four-2": reference.initial[.playState(wire)] = EpisodePlayState.played.rawValue
                default: break
                }
            }
        }
        note("family import")
        if let local = try await a.store.feeds().first(where: { $0.source.hasSuffix("/four.xml") }) {
            try await ServerChangeSetCaptureTests.Agreement.waitForCatalog(a.phone, feedID: local.id)
        }
    }

    /// A named crash point (PROTOCOL §16 scenarios 2 and 29): with work for each step (a change here to push, one from the
    /// other phone to pull and apply), the exchange dies at the point; the phone is relaunched and goes on.
    func crash(on side: Side, episode: Int64) async throws {
        let point = crashQueue.isEmpty ? random.pick(ServerExchangeCrashTests.points)! : crashQueue.removeFirst()
        let other = side === a ? b : a
        // Each change toggles a favorite, so it is a change (a fact) whatever the episode showed.
        func toggled(_ side: Side, _ episode: Int64) async throws -> Bool { !(try await side.store.episode(id: episode)?.userState.isFavorite ?? false) }
        if let target = random.pick(try await episodes(other)) {
            try await favorite(other, target, try await toggled(other, target))
            await other.phone.exchange()
            try await observe(other)
        }
        try await favorite(side, episode, try await toggled(side, episode))
        if ServerExchangeCrashTests.shadowed(point) { await side.phone.engine.setBudgets(direct: 1) }
        await side.phone.engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: point))
        let crashed = await side.phone.engine.exchange()
        await side.phone.engine.setCrashPoint(nil)
        if crashed.error == "InjectedCrash()" { note("crash \(point)") }
        trace.append("crash at \(point): \(crashed.error ?? "not reached")")
        try await observe(side)
        ChangeOracleRegistry.verify(side.store, side.name)
        try check(side, "before the relaunch after a crash")
        try await side.phone.relaunch()
        side.player = try await StorePlayer.restored(side.phone.store)
        await side.install()
    }

    /// The enclosure family (PROTOCOL §9.7): the publisher changes one item's GUID, keeping its title, date and enclosure; the
    /// server's next fetch matches it to the episode it had (a GUID change, merging a new item's episode into it).
    func changeGUID(_ side: Side) async throws -> Bool {
        let subscribed = try await side.store.feeds().filter { $0.subscriptionState != .notSubscribed }
        guard let local = random.pick(subscribed), let path = feeds.keys.sorted().first(where: { local.source.hasSuffix($0) }),
              let feed = feeds[path] else { return false }
        let number = 1 + random.below(feed.count)
        guard movedItems[path, default: []].insert(number).inserted else { return false }
        // The reference follows the changed item: matched, it stays the episode it was (its root wire, its state); a new
        // item is a new episode; a merge takes both out (`referenceDifferences`).
        serve(path)
        guard let podcast = try await side.store.podcastOfFeedForTesting(local.id) else { return true }
        _ = try? await side.phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
        note("guid change requested")
        return true
    }

    /// Serves `path` with its changed GUIDs, or the plain fixture when none changed.
    func serve(_ path: String) {
        guard let moved = movedItems[path], !moved.isEmpty, let feed = feeds[path] else { world.setResponse(path, nil); return }
        var document = ServerAgreementTests.rss(title: feed.title, prefix: feed.prefix, count: feed.count)
        for number in moved { document = document.replacingOccurrences(of: "<guid>\(feed.prefix)-\(number)</guid>", with: "<guid>\(feed.prefix)-\(number)-r</guid>") }
        world.setResponse(path, .init(headers: ["Content-Type": "application/rss+xml"], body: Data(document.utf8)))
    }
}

extension ServerChangeSetCaptureTests {
    /// The imported file: an Android database exported from a phone without a server, holding one podcast with a favorite,
    /// a played episode and a queued one.
    static func importedLibrary(_ world: ExchangeWorld) async throws -> Data {
        let url = world.root.appendingPathComponent("import-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            let feed = Self.feeds["/four.xml"]!
            let local = try await store.insert(Agreement.fetched(world.url("four.xml"), title: feed.title, prefix: feed.prefix, count: feed.count))
            let byIdentifier = Dictionary(local.episodes.map { ($0.details.identifier ?? "", $0.id) }, uniquingKeysWith: { first, _ in first })
            if let id = byIdentifier["four-1"] { try await store.setFavorite(episodeID: id, favorite: true) }
            if let id = byIdentifier["four-2"] { try await store.markEpisodePlayed(episodeID: id, played: true) }
            if let id = byIdentifier["four-3"] { _ = try await store.enqueue([id]) }
            let contents = try await store.exportContents()
            let data = try LibraryExportSource(contents: contents, speeds: PlaybackSpeedPreferences(), credentials: [:]).databaseData()
            try await store.close()
            return data
        } catch { try? await store.close(); throw error }
    }
}

extension ServerReadOracle {
    /// The library import (PROTOCOL §11.5) of an Android database into the account, which must be empty, followed until it
    /// is published.
    func importLibrary(_ file: Data) async throws {
        let fingerprint = ContractIdentity.sha256Hex([UInt8](file))
        let reserved = try await send("POST", "v1/import", ["kind": "android_db", "fingerprint": .string(fingerprint),
                                                            "size": .integer(Int64(file.count)), "file_name": "AntennaPodBackup.db"])
        guard let id = reserved["import_id"]?.stringValue else { throw HarnessError.server("no import: \(reserved)") }
        _ = try? await send("PUT", "v1/import/\(id)/chunks/0", ["data": .string(file.base64EncodedString())])
        _ = try? await send("POST", "v1/import/\(id)/finish", .object([:]))
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            let state = try await send("GET", "v1/import/\(id)")
            switch state["status"]?.stringValue {
            case "published": return
            case "failed": throw HarnessError.server("the import failed: \(state)")
            default:
                guard ContinuousClock.now < deadline else { throw HarnessError.server("the import is still \(state)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

extension ServerChangeSetCaptureTests.Run {
    /// The restore family (PROTOCOL §6.11, scenario 20): the server returns to its backup; both phones sign in again and
    /// recover, uploading what it lacks with the original receipts under successor installations. Before the restore, B's
    /// change is accepted but B dies before recording its receipt, and A pulls it: B then pushes it again after the restore
    /// (a provisional receipt), and A's recovery uploads the original, which replaces it. A's recovery first dies at its
    /// finish (a failed finish) and resumes after a relaunch. Both finish complete; nothing a person sees changes.
    func restoreAndRecover() async throws -> Bool {
        guard let backup else { return false }
        func relaunch(_ side: Side, _ label: String) async throws {
            ChangeOracleRegistry.verify(side.store, side.name)
            try check(side, label)
            try await side.phone.relaunch()
            side.player = try await StorePlayer.restored(side.phone.store)
            await side.install()
        }
        if let target = random.pick(try await episodes(b)) {
            try await favorite(b, target, !(try await b.store.episode(id: target)?.userState.isFavorite ?? false))
            await b.phone.engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "push.response"))
            let crashed = await b.phone.engine.exchange()
            await b.phone.engine.setCrashPoint(nil)
            trace.append("push response before the restore: \(crashed.error ?? "not reached")")
            try await observe(b)
            try await relaunch(b, "before the relaunch after a push crash")
            await a.phone.exchange(); try await observe(a)
        }
        try await world.restore(backup)
        // The restore removed every token, the read API's session too.
        reader = try await ServerReadOracle(world.server)
        for side in sides {
            let first = await side.phone.engine.exchange()
            guard first.pause == .signIn else {
                problems.append("\(side.name) after the restore: \(String(describing: first.pause)) \(first.error ?? "")")
                throw ServerChangeSetCaptureTests.CaptureFailure()
            }
            try await side.phone.signInAgainOnDevice(world.server)
        }
        func recover(_ side: Side) async throws {
            var report = await side.phone.engine.exchange()
            for _ in 0..<3 where report.recovery != nil || report.error != nil || report.pause != nil { report = await side.phone.engine.exchange() }
            let recovery = try await side.store.serverRecovery()
            guard recovery?.finished == true, recovery?.complete == true else {
                problems.append("\(side.name) did not recover completely: \(String(describing: recovery)) \(report.error ?? "") \(String(describing: report.pause))")
                throw ServerChangeSetCaptureTests.CaptureFailure()
            }
            try await observe(side)
        }
        try await recover(b)
        await a.phone.engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "recovery.finish"))
        let failed = await a.phone.engine.exchange()
        await a.phone.engine.setCrashPoint(nil)
        if failed.error == "InjectedCrash()" { note("family failed finish") }
        trace.append("recovery finish: \(failed.error ?? "not reached")")
        try await relaunch(a, "before the relaunch after a failed recovery finish")
        try await recover(a)
        await b.phone.exchange(); try await observe(b)
        note("family restore recovery")
        // The original receipt replaced B's provisional one: B keeps the replaced receipt (PROTOCOL §6.11).
        if let url = b.phone.location.syncDatabase {
            let archive = try SyncSQLite(url: url)
            defer { try? archive.close() }
            if try archive.scalar("SELECT count(*) FROM superseded_receipts") > 0 { note("family receipt replacement") }
        }
        return true
    }
}

/// The generator's register actions, each told to the reference as what it does: the phone's state before it decides
/// whether it is a change (a fact) at all, and which effect it has. Each is checked against the phone's outbox: a fact
/// exactly when the reference records one.
extension ServerChangeSetCaptureTests.Run {
    static let playStateFacts = ["episode.mark_played", "episode.mark_unplayed", "inbox.dismiss", "inbox.dismiss_all", "episode.restore_state",
                                 "episode.reset_position"]

    /// The facts of `types` this phone's outbox holds that name `wire`.
    func facts(_ side: Side, _ wire: String, _ types: [String]) throws -> Int {
        let list = types.map { "'\($0)'" }.joined(separator: ", ")
        let count = try side.phone.rows("SELECT count(*) FROM ntp_outbox WHERE type IN (\(list)) AND instr(CAST(fact AS TEXT), '\(wire)') > 0")
        return Int(count.first?.first.flatMap { $0 } ?? "0") ?? 0
    }

    func expectFact(_ side: Side, _ wire: String, _ types: [String], before: Int, made: Bool, _ label: String) throws {
        let after = try facts(side, wire, types)
        guard made != (after > before) else { return }
        problems.append("\(side.name) \(label) at step \(steps): the reference \(made ? "recorded a fact the phone did not make" : "recorded no fact, but the phone made one") (\(before) → \(after))\ntrace: \(trace.suffix(20).joined(separator: ", "))")
        throw ServerChangeSetCaptureTests.CaptureFailure()
    }

    func shown(_ side: Side, _ episode: Int64) async throws -> EpisodeUserState? { try await side.store.episode(id: episode)?.userState }

    /// Mark played or unplayed: an explicit write whatever the episode showed (Android's `markItemPlayed`).
    func mark(_ side: Side, _ episode: Int64, played: Bool) async throws {
        guard let wire = try await wire(side, episode) else { return try await side.store.markEpisodePlayed(episodeID: episode, played: played) }
        let before = try facts(side, wire, Self.playStateFacts)
        try await side.store.markEpisodePlayed(episodeID: episode, played: played)
        reference.playState(wire, played ? .played : .unplayed, side: side.name)
        try expectFact(side, wire, Self.playStateFacts, before: before, made: true, "a mark")
    }

    /// A favorite set to what the episode shows already is no change and no fact.
    func favorite(_ side: Side, _ episode: Int64, _ value: Bool) async throws {
        guard let wire = try await wire(side, episode) else { return try await side.store.setFavorite(episodeID: episode, favorite: value) }
        let shownBefore = try await shown(side, episode)?.isFavorite
        let before = try facts(side, wire, ["favorite.set"])
        try await side.store.setFavorite(episodeID: episode, favorite: value)
        let made = shownBefore != value
        if made { reference.favorite(wire, value, side: side.name) }
        try expectFact(side, wire, ["favorite.set"], before: before, made: made, "a favorite")
    }

    /// Toggle played (a swipe, Android's `TogglePlaybackStateSwipeAction`): unplayed becomes played (a write), played becomes
    /// unplayed (a write), NEW becomes unplayed (a dismissal); its Undo restores what it showed.
    func swipe(_ side: Side, _ episode: Int64) async throws {
        guard let wire = try await wire(side, episode), let state = try await shown(side, episode)?.playState else { return }
        let before = try facts(side, wire, Self.playStateFacts)
        side.swipe = try await side.store.applySwipeMark(episodeID: episode, action: .togglePlayed)
        switch state {
        case .unplayed: reference.playState(wire, .played, side: side.name)
        case .played: reference.playState(wire, .unplayed, side: side.name)
        case .new: reference.dismiss(wire, side: side.name)
        }
        side.swiped = (wire, state.rawValue)
        try expectFact(side, wire, Self.playStateFacts, before: before, made: true, "a swipe")
    }

    /// The swipe's Undo: when it restores, it writes the state before the swipe again (no fact if it shows that already).
    func undoSwipe(_ side: Side) async throws -> Bool {
        guard let receipt = side.swipe else { return false }
        side.swipe = nil
        defer { side.swiped = nil }
        guard let swiped = side.swiped, let state = try await shown(side, receipt.episodeID)?.playState else {
            _ = try await side.store.undoSwipeMark(receipt); return true
        }
        let before = try facts(side, swiped.wire, Self.playStateFacts)
        let restored = try await side.store.undoSwipeMark(receipt) == .restored
        let made = restored && state.rawValue != swiped.previous
        if made { reference.write(.playState(swiped.wire), swiped.previous, side: side.name) }
        try expectFact(side, swiped.wire, Self.playStateFacts, before: before, made: made, "a swipe's Undo")
        return true
    }

    /// Remove from inbox: a NEW episode is dismissed (a conditional effect, not an unplayed write); a played one is marked
    /// unplayed; an unplayed one is left as it is, with no fact (PROTOCOL §7.4, `mapDismiss`).
    func dismiss(_ side: Side, _ episode: Int64) async throws {
        guard let wire = try await wire(side, episode), let state = try await shown(side, episode)?.playState else {
            return try await side.store.removeEpisodeFromInbox(episodeID: episode)
        }
        let before = try facts(side, wire, Self.playStateFacts)
        try await side.store.removeEpisodeFromInbox(episodeID: episode)
        switch state {
        case .new: reference.dismiss(wire, side: side.name)
        case .played: reference.playState(wire, .unplayed, side: side.name)
        case .unplayed: break
        }
        try expectFact(side, wire, Self.playStateFacts, before: before, made: state != .unplayed, "a dismissal")
    }

    /// A queue add: each episode not queued yet is added (an explicit membership write), with the add's fixed effect
    /// (NEW becomes unplayed); one queued already is no change.
    func enqueue(_ side: Side, _ episodes: [Int64], location: EnqueueLocation) async throws {
        let queued = Set(try await side.store.queue().map(\.id))
        let before = try facts(side, ["queue.add"])
        _ = try await side.store.enqueue(episodes, location: location)
        let added = episodes.filter { !queued.contains($0) }
        for episode in added {
            if let wire = try await wire(side, episode) { reference.dismiss(wire, side: side.name); reference.queued(wire, true, side: side.name) }
        }
        try expectFacts(side, ["queue.add"], before: before, made: !added.isEmpty, "a queue add")
    }

    /// A queue removal of a queued episode: an explicit removal.
    func dequeue(_ side: Side, _ episode: Int64) async throws {
        let before = try facts(side, ["queue.remove"])
        _ = try await side.store.removeFromQueue([episode])
        if let wire = try await wire(side, episode) { reference.queued(wire, false, side: side.name) }
        try expectFacts(side, ["queue.remove"], before: before, made: true, "a queue removal")
    }

    /// Clear the queue: a removal of exactly the members it observed (a concurrent add of another episode stays).
    func clearQueue(_ side: Side) async throws {
        let members = try await side.store.queue().map(\.id)
        let before = try facts(side, ["queue.clear", "queue.remove"])
        _ = try await side.store.clearQueue()
        for episode in members { if let wire = try await wire(side, episode) { reference.queued(wire, false, side: side.name) } }
        try expectFacts(side, ["queue.clear", "queue.remove"], before: before, made: !members.isEmpty, "a clear")
    }

    /// The facts of `types` this phone's outbox holds.
    func facts(_ side: Side, _ types: [String]) throws -> Int {
        let list = types.map { "'\($0)'" }.joined(separator: ", ")
        return Int(try side.phone.rows("SELECT count(*) FROM ntp_outbox WHERE type IN (\(list))").first?.first.flatMap { $0 } ?? "0") ?? 0
    }

    func expectFacts(_ side: Side, _ types: [String], before: Int, made: Bool, _ label: String) throws {
        let after = try facts(side, types)
        guard made != (after > before) else { return }
        problems.append("\(side.name) \(label) at step \(steps): the reference \(made ? "recorded a fact the phone did not make" : "recorded no fact, but the phone made one") (\(before) → \(after))\ntrace: \(trace.suffix(20).joined(separator: ", "))")
        throw ServerChangeSetCaptureTests.CaptureFailure()
    }

    /// Reset position (closing the player's episode at the end of a run): whether it is a change depends on the
    /// episode's sessions as well as what it shows (a no-op without either), which the reference does not model; its play
    /// state becomes unknown.
    func resetPosition(_ side: Side, _ episode: Int64) async throws {
        try await side.store.resetPlaybackPosition(episodeID: episode)
        if let wire = try await wire(side, episode) { reference.playState(wire, nil, side: side.name) }
    }

    /// A pin release, as the app's scheduler runs it when the player leaves an episode. A release never changes the queue:
    /// one that removes queued episodes is the queue-recompute marker written as an empty queue (a defect that once
    /// emptied the queue), a failure.
    func releasePins(_ side: Side, _ label: String) async throws {
        let queued = try await side.store.queue().map(\.id)
        await side.phone.engine.releasePins()
        let after = Set(try await side.store.queue().map(\.id))
        let lost = queued.filter { !after.contains($0) }
        guard lost.isEmpty else {
            problems.append("\(side.name) after step \(steps), \(label): a pin release removed \(lost.count) of \(queued.count) queued episodes\ntrace: \(trace.suffix(30).joined(separator: ", "))")
            throw ServerChangeSetCaptureTests.CaptureFailure()
        }
    }

    /// Every check after a step or an exchange: the capture oracle and the engine's told sets, a clean full reprojection of
    /// each phone, and the reference phones.
    func verify(_ label: String) async throws {
        for side in sides { try check(side, label) }
        for side in sides { await checkPublication(side, label) }
        for side in sides {
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(side.phone)
            note("rebuild")
            if !differences.isEmpty {
                problems.append("\(side.name) rebuild after \(label) (step \(steps)): \(differences.joined(separator: "; "))\ntrace: \(trace.suffix(30).joined(separator: ", "))")
                throw ServerChangeSetCaptureTests.CaptureFailure()
            }
        }
        for side in sides {
            let found = try await referenceDifferences(side)
            note("reference")
            if !found.isEmpty {
                problems.append("\(side.name) differs from the reference after \(label) (step \(steps)): \(found.prefix(6).joined(separator: "; "))\ntrace: \(trace.suffix(30).joined(separator: ", "))")
                throw ServerChangeSetCaptureTests.CaptureFailure()
            }
        }
    }
}

extension ServerChangeSetCaptureTests.Run {
    /// The phone's visible model, read on a connection of its own (as a screen reads it).
    func image(_ side: Side) throws -> ChangeSetOracle.Model {
        let reader = try LibrarySQLite(readingOnly: side.phone.location.database)
        defer { try? reader.close() }
        var cache: [Data: Data] = [:]
        return try ChangeSetOracle.read(reader, cache: &cache).semantic
    }

    /// Staging, shown ahead and hidden removal (PROTOCOL §6.8): A subscribes a large podcast (more episodes than a removal
    /// batch) and the publisher renames a podcast B shows. B takes both in a shadow publication: its new podcast staged and
    /// the renamed rows shown ahead in bounded transactions. Before each batch, every row B shows is either what it showed
    /// before or exactly the commit's result (only the shown rows' content replaced). A then unsubscribes the large podcast:
    /// B's unit hides it at once and deletes its rows in bounded transactions.
    func stagingAndRemoval() async throws -> Bool {
        let count = FeedLibraryStore.removalBatch + 10
        world.setFeed("/five.xml", ("Five", "five", count))
        let large = try await a.store.subscribeForTesting(ServerChangeSetCaptureTests.Agreement.fetched(world.url("five.xml"), title: "Five", prefix: "five", count: count))
        try await ServerChangeSetCaptureTests.Agreement.waitForCatalog(a.phone, feedID: large.id)
        try await observe(a)
        // A rename of a podcast B shows, fetched by the server.
        let shown = try await b.store.feeds().filter { $0.subscriptionState != .notSubscribed }
        guard let local = shown.first(where: { feed in feeds.keys.contains { feed.source.hasSuffix($0) } }),
              let path = feeds.keys.sorted().first(where: { local.source.hasSuffix($0) }), var feed = feeds[path],
              let podcast = try await b.store.podcastOfFeedForTesting(local.id), let reader else { return false }
        feed.title += " renamed"
        feeds[path] = feed
        world.setFeed(path, feed)
        serve(path)
        _ = try? await b.phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline,
              try await reader.send("GET", "v1/read/podcasts/\(podcast)")["podcast"]?["title"]?.stringValue != feed.title {
            try await Task.sleep(for: .milliseconds(100))
        }
        // B's shadow publication, each batch's state kept.
        let before = try image(b)
        let states = Mutex<[ChangeSetOracle.Model]>([]), hidden = Mutex<[String]>([])
        let location = b.phone.location.database
        await b.phone.engine.setBudgets(direct: 0)
        await b.phone.engine.setBeforeStagingBatch {
            let reader = try LibrarySQLite(readingOnly: location)
            defer { try? reader.close() }
            var cache: [Data: Data] = [:]
            let model = try ChangeSetOracle.read(reader, cache: &cache).semantic
            let rows = try reader.rows("SELECT feed_id, state FROM ntp_hidden_feeds").map { "\($0[0].integer ?? -1) \($0[1].text ?? "-")" }
            states.withLock { $0.append(model) }
            hidden.withLock { $0.append(rows.joined(separator: ",")) }
        }
        let report = await b.phone.exchange()
        await b.phone.engine.setBeforeStagingBatch(nil)
        await b.phone.engine.setBudgets(direct: 250)
        notePaths(report)
        try await observe(b)
        let after = try image(b)
        var shownAhead = 0
        // A state that is neither is reported as a finding (the seed goes on): a podcast row shown before its staging, for
        // example, would be one a person sees half-made.
        for (index, state) in states.withLock({ $0 }).enumerated() {
            for id in Set(state.episodes.keys).union(before.episodes.keys) {
                let now = state.episodes[id]
                if now == before.episodes[id] { continue }
                if now == after.episodes[id] { shownAhead += 1; continue }
                stagingFindings.append("B before staging batch \(index) at step \(steps): episode \(id) shows neither its earlier state nor the commit's")
            }
            for id in Set(state.feeds.keys).union(before.feeds.keys) where state.feeds[id] != before.feeds[id] && state.feeds[id] != after.feeds[id] {
                func keys(_ data: Data?) -> NSDictionary { data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? NSDictionary } ?? [:] }
                let now = keys(state.feedRows[id]?.record), final = keys(after.feedRows[id]?.record)
                let differing = Set((now.allKeys + final.allKeys).compactMap { $0 as? String }).filter { !((now[$0] as AnyObject?)?.isEqual(final[$0]) ?? (final[$0] == nil)) }.sorted()
                stagingFindings.append("B before staging batch \(index) at step \(steps) (hidden feeds: \(hidden.withLock { $0[index] }.isEmpty ? "none" : hidden.withLock { $0[index] })): feed \(id) shows neither its earlier state (\(before.feeds[id] == nil ? "none" : "one")) nor the commit's; title \(String(describing: state.feedRows[id]?.title)) vs \(String(describing: after.feedRows[id]?.title)); record differs in \(differing)")
            }
        }
        if shownAhead > 0 { note("shown ahead checked") }
        trace.append("staging \(report.stagingBatches) batches, \(report.shownAhead) shown ahead, \(states.withLock { $0.count }) states checked")
        // A unsubscribes the large podcast; B's unit hides it and deletes its rows afterwards.
        for phone in sides {
            for episode in try await phone.store.feeds().flatMap(\.episodes) where (episode.details.identifier ?? "").hasPrefix("five-") {
                if let wire = try await wire(phone, episode.id) { reference.exclude(wires: [wire]) }
            }
        }
        _ = try await a.store.requestFeedDeletion(feedID: large.id)
        notePaths(await a.phone.exchange()); try await observe(a)
        notePaths(await b.phone.exchange()); try await observe(b)
        return true
    }
}
