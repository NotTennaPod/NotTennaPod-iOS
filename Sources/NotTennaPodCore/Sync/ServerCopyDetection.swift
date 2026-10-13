import Foundation

/// Local copy detection (PROTOCOL §6.10): a server library whose stored device marker
/// is not this install's (a backup restored onto another device, or onto this one after its marker was lost) is a
/// copy. Before it writes or sends anything, in one live transaction that needs no network, it forks every author it
/// would write again and moves to a new transport installation `T'` with a fresh transport nonce, so neither its
/// author positions nor its transport slots collide with the library it was copied from; both keep working.
///
/// - The main author `A` forks to `F_A = T'`; a registration's current author `X` (pending or resolved) forks to a
///   fresh `F_X` and the registration's new drafts go on it. Each fork's first fact is
///   `installation.fork {author: X, head: X's writing tip}`, depending on the copied frontier and the tip; a pending
///   registration's fork is a draft of it, materialized after `X`'s drafts. The writing tip counts pending, drafted
///   and rejected facts; pulled facts never move it. An author whose tip nobody can know (a refused registration's
///   dropped drafts) has no history to name and is not forked. `X` is never written again by this library.
/// - Existing drafts keep their op IDs and authors; overlays are keyed by op ID and are untouched.
/// - Without a working token (the normal copy: tokens are `ThisDeviceOnly`) the transition commits here: the
///   unreceipted outbox moves to `T'` from slot 1 and receipted, unretired entries to `ntp_retained`; `T'` is registered
///   later by signing in. With one, the transition is planned and the exchange issues it with that token (PROTOCOL §6.11); the
///   other nonce leaves the original installation untouched.
/// - Sessions (PROTOCOL §6.10 "Sessions", "Pending transitions"): an open sync session's unexported saves are
/// exported
///   passively by the fork of the session's author and the session is sealed locally; a copied pending transition
///   keeps its exact reference and is performed by the fork.
enum ServerCopyDetection {
    enum Outcome: Equatable, Sendable {
        /// The library last ran on this install.
        case same
        /// A copy: the forks written, and the transition onto `installID` with `nonce` committed (no token) or planned.
        case forked(installID: String, nonce: String, committed: Bool, forks: Int)
    }

    /// Detection in one transaction of `database` (already a server library).
    static func run(_ database: LibrarySQLite, deviceMarker: String, hasWorkingToken: Bool, now: Int64) throws -> Outcome {
        try database.transaction {
            guard let row = try database.rows("SELECT library_id, account_id, namespace, install_id, main_author, device_marker FROM ntp_library WHERE id = 1").first,
                  let library = row[0].text, let account = row[1].text, let namespace = row[2].text, let install = row[3].text,
                  let main = row[4].text else { throw ServerRecordingError.corruptState("ntp_library") }
            if row[5].text == deviceMarker { return .same }
            let successor = ContractIdentity.randomUUID(), nonce = ContractIdentity.randomUUID()
            func writer(author: String) -> ServerOutboxWriter {
                ServerOutboxWriter(database: database, context: ServerLibraryContext(libraryID: library, accountID: account, namespace: namespace,
                                                                                    installID: install, mainAuthor: author), failAfter: nil)
            }
            let copied = try writer(author: successor).frontier()
            var forks = 0
            // The main author: `F_A = T'` (PROTOCOL §6.10).
            try database.execute("INSERT INTO ntp_authors(author_id, role, next_seq, forked_from, created_at) VALUES (?, 'main', 1, ?, ?)",
                                 [.text(successor), .text(main), .integer(now)])
            if let tip = try writingTip(of: main, database) {
                try writer(author: successor).appendFact(type: "installation.fork", targets: [], payload: fork(of: main, head: tip),
                                                         dependencies: copied + [tip], clientTime: now, now: now)
                forks += 1
            }
            try database.execute("UPDATE ntp_library SET main_author = ?, device_marker = ? WHERE id = 1", [.text(successor), .text(deviceMarker)])
            // Each registration's current author (PROTOCOL §15.2): a pending one's fork is a draft of it.
            for registration in try database.rows("SELECT op_id, author_id, state FROM ntp_registrations ORDER BY created_at, rowid") {
                guard let op = registration[0].text, let author = registration[1].text,
                      let tip = try writingTip(of: author, database) else { continue }
                let forked = ContractIdentity.randomUUID()
                try database.execute("INSERT INTO ntp_authors(author_id, role, next_seq, registration_op, forked_from, created_at) VALUES (?, 'registration', 1, ?, ?, ?)",
                                     [.text(forked), .text(op), .text(author), .integer(now)])
                if registration[2].text == "pending" {
                    let template: ContractJSON = ["type": "installation.fork", "targets": [], "payload": .object(fork(of: author, head: tip)), "secret_ids": []]
                    try writer(author: successor).appendDraft(registrationOp: op, authorID: forked, type: "installation.fork", template: template,
                                                              dependencies: copied + [tip], clientTime: now, now: now)
                } else {
                    try writer(author: forked).appendFact(type: "installation.fork", targets: [], payload: fork(of: author, head: tip),
                                                          dependencies: copied + [tip], clientTime: now, now: now)
                }
                try database.execute("UPDATE ntp_registrations SET author_id = ? WHERE op_id = ?", [.text(forked), .text(op)])
                forks += 1
            }
            // A plan or recovery copied with the library belonged to the original's installation: this copy plans its
            // own, and its recovery's phases start again on it.
            if var recovery = try FeedLibraryStore.recovery(database), !recovery.finished {
                recovery.restartPhases()
                try FeedLibraryStore.storeRecovery(recovery, database)
            }
            if hasWorkingToken {
                try FeedLibraryStore.storeTransition(ServerInstallationTransition(installID: successor, transportNonce: nonce, reason: .copy, predecessor: install), database)
            } else {
                try FeedLibraryStore.storeTransition(nil, database)
                _ = try FeedLibraryStore.moveOutbox(database, onto: successor)
            }
            // A pause that stood for another library's use of this transport is this transition's (PROTOCOL §6.10).
            try database.execute("UPDATE ntp_library SET pause_reason = NULL WHERE id = 1 AND pause_reason = ?", [.text(ServerPauseReason.transportConflict.rawValue)])
            return .forked(installID: successor, nonce: nonce, committed: !hasWorkingToken, forks: forks)
        }
    }

    private static func fork(of author: String, head: String) -> ContractObject {
        ["author": .string(author), "head": .string(head)]
    }

    /// The fact an author's next fact would name as its `previous_op_id`, when something can know it: a fact or draft
    /// this library holds (a refused registration's dropped drafts are gone).
    static func writingTip(of author: String, _ database: LibrarySQLite) throws -> String? {
        guard let tip = try database.rows("SELECT last_op_id FROM ntp_authors WHERE author_id = ?", [.text(author)]).first?.first?.text else { return nil }
        let known = try database.scalar("SELECT (SELECT count(*) FROM ntp_nodes WHERE node_id = ? AND kind != 'draft') + (SELECT count(*) FROM ntp_drafts WHERE op_id = ?) + (SELECT count(*) FROM ntp_retained WHERE op_id = ?)",
                                        [.text(tip), .text(tip), .text(tip)])
        return known > 0 ? tip : nil
    }

    /// Detection for a library on the device at a graph start, before it opens (PROTOCOL §6.10: after an unfinished Keep's
    /// recovery; a `keeping` library is skipped by the caller). Opens its database with a connection of its own; a
    /// standalone or converted database (no `ntp_library` row) is left alone. Throws when the Keychain cannot be read
    /// (before the first unlock): detection waits, and facts recorded meanwhile stay valid (PROTOCOL §6.10).
    static func detect(_ location: LibraryLocation, libraryID: String, secrets: any ServerSecretStore, now: Date = Date()) throws -> Outcome {
        guard !LibraryLocation.isAbsent(location.database) else { return .same }
        let marker = try secrets.deviceMarker()
        // Read first: a library that last ran here (every launch, normally) is not opened for writing.
        let reader = try LibrarySQLite(readingOnly: location.database)
        let stored = try reader.transaction(write: false) { () throws -> [LibrarySQLValue]? in
            guard try reader.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_library'") == 1 else { return nil }
            return try reader.rows("SELECT install_id, device_marker FROM ntp_library WHERE id = 1").first
        }
        try? reader.close()
        guard let stored, stored[1].text != marker else { return .same }
        let database = try LibrarySQLite(url: location.database, ownedRoot: location.ownedRoot)
        defer { try? database.close() }
        guard let row = try database.rows("SELECT install_id, device_marker FROM ntp_library WHERE id = 1").first,
              let install = row[0].text else { return .same }
        if row[1].text == marker { return .same }
        let working = try secrets.installation(library: libraryID, install: install)?.usableToken != nil
        let outcome = try run(database, deviceMarker: marker, hasWorkingToken: working,
                              now: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)))
        try saveNonce(outcome, libraryID: libraryID, secrets: secrets)
        return outcome
    }

    /// A committed copy's `T'` keeps its fresh nonce beside the token signing in will add (PROTOCOL §15.4). Best effort: signing
    /// in again without it takes another fresh one, which serves `T'` as well (the server has never seen `T'`).
    static func saveNonce(_ outcome: Outcome, libraryID: String, secrets: any ServerSecretStore) throws {
        guard case .forked(let install, let nonce, true, _) = outcome,
              try secrets.installation(library: libraryID, install: install) == nil else { return }
        try secrets.saveInstallation(ServerInstallationCredential(transportNonce: nonce), library: libraryID, install: install)
    }
}

extension FeedLibraryStore {
    /// Local copy detection on the open library (PROTOCOL §6.10), before the exchange sends anything: a library opened while the
    /// Keychain could not be read is detected once it can.
    func detectServerCopy(deviceMarker: String, hasWorkingToken: Bool, now: Date = Date()) throws -> ServerCopyDetection.Outcome {
        guard serverContext != nil else { return .same }
        let outcome = try ServerCopyDetection.run(database, deviceMarker: deviceMarker, hasWorkingToken: hasWorkingToken, now: try milliseconds(now))
        if case .forked = outcome { serverContext = try Self.loadServerContext(database) }
        return outcome
    }

    /// The device marker the library last ran under (`ntp_library.device_marker`).
    func serverDeviceMarker() throws -> String? {
        guard serverContext != nil else { return nil }
        return try database.rows("SELECT device_marker FROM ntp_library WHERE id = 1").first?.first?.text
    }
}
