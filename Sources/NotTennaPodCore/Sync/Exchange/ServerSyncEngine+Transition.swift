import Foundation

/// The Keychain items an exchange needs for its installation transitions (PROTOCOL §15.4): the device marker
/// that detects a local copy, and each installation's token and transport nonce, for one library. The app gives the
/// engine the Keychain's (`KeychainServerSecrets`); tests give it memory.
public struct ServerInstallationKeychain: Sendable {
    public let libraryID: String
    public let secrets: any ServerSecretStore
    /// What the successor request tells the server about this device.
    public let device: ServerDevice

    public init(libraryID: String, secrets: any ServerSecretStore, device: ServerDevice) {
        self.libraryID = libraryID; self.secrets = secrets; self.device = device
    }
}

/// Copies, transport conflicts and the installation transition (PROTOCOL §6.10–3; PROTOCOL §6.10). Before anything is
/// sent the library checks that it last ran on this install; a planned transition is issued with the predecessor's
/// token (`POST /v1/installations/successor`) and committed; the predecessor's token goes only after that commit.
extension ServerSyncEngine {
    /// What waits for the installation before anything else of an exchange: local copy detection, a conflict or
    /// recovery a stored pause stands for, the transition, and a recovery up to its catch-up (PROTOCOL §6.11–7). Returns
    /// whether the exchange may go on now; the report says why not.
    func prepareInstallation(_ report: inout ServerExchangeReport) async throws -> Bool {
        guard let keychain = installations else { return true }
        try await detectCopy(keychain)
        if let pause = try await store.serverExchangeState().pause, [.transportConflict, .dependencyLost, .lineageMismatch].contains(pause) {
            _ = try await transitionNeeded(after: pause)
        }
        guard try await runTransition(&report, keychain) else { return false }
        return try await recover(&report, keychain)
    }

    /// Whether an answer moves this library to a new installation or starts a recovery, which is now planned: the
    /// exchange runs again. Without the Keychain items nothing is planned, and the answer pauses as before.
    func transitionNeeded(after error: ServerExchangeError) async throws -> Bool {
        guard installations != nil else { return false }
        switch (error.status, error.code) {
        case (409, "lineage_mismatch"): return try await beginRecovery(.lineageMismatch)
        case (409, "installation_superseded"), (409, "installation_conflict"): return try await beginConflict()
        default: return false
        }
    }

    func transitionNeeded(after pause: ServerPauseReason?) async throws -> Bool {
        guard installations != nil, let pause else { return false }
        switch pause {
        case .transportConflict: return try await beginConflict()
        case .dependencyLost: return try await beginRecovery(.dependencyLost)
        case .lineageMismatch: return try await beginRecovery(.lineageMismatch)
        case .versionUnsupported, .signIn, .lineageUnknown: return false
        }
    }

    /// "Sign in again" answered `installation_superseded` (another library took a successor of this installation, and
    /// this library knew nothing of it, PROTOCOL §6.10): a transition to a fresh installation the person signs in with. A plan
    /// already made is kept.
    public func planNewInstallation() async -> ServerSignInInstallation? {
        do {
            if try await store.serverTransition() == nil {
                try await store.planServerTransition(.conflict, nonce: ContractIdentity.randomUUID(), now: clock())
                log("transition", "this installation was replaced: signing in again continues with a new one")
            }
            try await store.updateServerTransition { $0.signInWithSuccessor = true }
            guard let plan = try await store.serverTransition() else { return nil }
            return ServerSignInInstallation(installID: plan.installID, transportNonce: plan.transportNonce)
        } catch {
            log("error", "planning a new installation: \(ServerLogValue.failure(error))")
            return nil
        }
    }

    // MARK: - Local detection (PROTOCOL §6.10)

    /// A library whose device marker is not this install's is a copy: it forks every author and takes `T'` before it
    /// sends anything (`ServerCopyDetection`). A Keychain that cannot be read (before the first unlock) throws: nothing
    /// is sent then, and facts recorded meanwhile stay valid (PROTOCOL §6.10).
    private func detectCopy(_ keychain: ServerInstallationKeychain) async throws {
        let marker = try keychain.secrets.deviceMarker()
        guard try await store.serverDeviceMarker() != marker else { return }
        let install = try await store.serverExchangeState().installID
        let working = try keychain.secrets.installation(library: keychain.libraryID, install: install)?.usableToken != nil
        let outcome = try await store.detectServerCopy(deviceMarker: marker, hasWorkingToken: working, now: clock())
        try crash("copy.detected")
        try ServerCopyDetection.saveNonce(outcome, libraryID: keychain.libraryID, secrets: keychain.secrets)
        if case .forked(_, _, let committed, let forks) = outcome {
            log("copy", "this library is a copy: \(forks) authors forked, a new installation " + (committed ? "to sign in with" : "planned"))
        }
    }

    // MARK: - Planning (PROTOCOL §6.11, PROTOCOL §6.10)

    /// Another library used this transport (`installation_conflict`, an `installation_superseded` this library did not
    /// cause, or a slot of it holding another library's fact): a new installation with a fresh transport nonce, the
    /// authors kept (the server derives branches, PROTOCOL §6.10). A transition planned already (one this library caused)
    /// simply runs.
    private func beginConflict() async throws -> Bool {
        if try await store.serverTransition() != nil { return true }
        try await store.planServerTransition(.conflict, nonce: ContractIdentity.randomUUID(), now: clock())
        log("transition", "another library uses this installation: a new one with a fresh nonce")
        return true
    }

    /// The server was restored (or lost a node this library holds): a recovery and its transition, planned once with
    /// the installation's own transport nonce, so the successor supersedes its predecessor (PROTOCOL §6.11, PROTOCOL §6.11). A
    /// recovery already running and not caught up asks the server again instead (a second restore resumes, PROTOCOL §6.11).
    private func beginRecovery(_ cause: ServerRecoveryRecord.Cause) async throws -> Bool {
        let planned = try await store.serverTransition()
        if let record = try await store.serverRecovery(), !record.finished, !record.caughtUp, planned == nil { return true }
        let nonce = try await currentCredential()?.transportNonce ?? ContractIdentity.randomUUID()
        try await store.planServerTransition(.recovery, nonce: nonce, recovery: cause, now: clock())
        try crash("recovery.started")
        log("recovery", cause == .lineageMismatch ? "the server was restored from a backup: recovery starts" : "the server lost changes this library holds: recovery starts")
        return true
    }

    private func currentCredential() async throws -> ServerInstallationCredential? {
        guard let keychain = installations else { return nil }
        return try keychain.secrets.installation(library: keychain.libraryID, install: try await store.serverExchangeState().installID)
    }

    // MARK: - Issue and transition (PROTOCOL §6.11–3)

    /// Issues the planned successor with the predecessor's token and commits the transition. Returns false when the
    /// person must sign in again first (the report pauses for it).
    private func runTransition(_ report: inout ServerExchangeReport, _ keychain: ServerInstallationKeychain) async throws -> Bool {
        guard var plan = try await store.serverTransition() else { return true }
        // Signed in with `T'` (an already-superseded predecessor, PROTOCOL §6.10): `T'` holds a token, so it is issued.
        if plan.state == .planned, try keychain.secrets.installation(library: keychain.libraryID, install: plan.installID)?.usableToken != nil {
            try await store.updateServerTransition { $0.state = .issued }
            plan.state = .issued
        }
        if plan.state == .planned {
            if plan.signInWithSuccessor {
                report.pause = .signIn
                log("paused", "sign_in this installation was replaced; signing in again continues with a new one")
                return false
            }
            do {
                let answer = try await gated(.installation) {
                    try await transport.send("POST", "v1/installations/successor", body: [
                        "install_id": .string(plan.installID), "instance_nonce": .string(plan.transportNonce), "device": keychain.device.json])
                }
                guard let token = answer["token"]?.stringValue, !token.isEmpty, answer["install_id"]?.stringValue == plan.installID else {
                    throw ServerExchangeError.notAServer
                }
                // A crash after this repeats the request: the server issues a fresh credential for the same successor.
                try keychain.secrets.saveInstallation(ServerInstallationCredential(transportNonce: plan.transportNonce, token: token, device: keychain.device),
                                                      library: keychain.libraryID, install: plan.installID)
                try crash("transition.token")
                try await store.updateServerTransition { $0.state = .issued }
                try crash("transition.issued")
                log("transition", "\(plan.reason.rawValue): a successor installation was issued")
            } catch let error as ServerExchangeError where error.code == "installation_superseded" || (error.status == 401 && plan.reason != .recovery) {
                // Another library already took a successor of this installation, or its credentials were revoked once
                // that successor was used (PROTOCOL §6.10): this library cannot authorize one any more and signs in with `T'`.
                try await store.updateServerTransition { $0.signInWithSuccessor = true }
                try await store.setServerPause(.signIn)
                report.pause = .signIn
                log("paused", "sign_in this installation was replaced; signing in again continues with a new one")
                return false
            }
            // After a restore every token is gone (PROTOCOL §11): a 401 here pauses for "Sign in again", which resumes the
            // predecessor; the successor is issued after it.
        }
        guard let committed = try await store.commitServerTransition() else { return true }
        try crash("transition.committed")
        log("transition", "\(committed.reason.rawValue): \(committed.renumbered) unconfirmed changes continue on the new installation, \(committed.retained) kept for recovery")
        // Only now does a request use `T'`'s token; the predecessor's goes (the server revokes it once `T'`'s is used).
        for install in (try? keychain.secrets.installIDs(of: keychain.libraryID)) ?? [] where install != committed.successor {
            try? keychain.secrets.removeInstallation(library: keychain.libraryID, install: install)
        }
        pullWatermark = nil; deferredUnit = nil; operationLimit = nil; extraSecrets = []
        // Commits archived on the timeline the server lost are never applied (recovery asks the server again, PROTOCOL §6.11).
        let recovering = try await store.serverRecovery().map { !$0.finished } ?? false
        if committed.reason == .recovery || recovering {
            try archive.dropPendingCommits(through: Int64.max, logID: "")
        }
        return true
    }

    // MARK: - Retained entries of a transition that was not a recovery

    /// Receipted entries an earlier transport left (PROTOCOL §6.11) retire once the live base holds them: the commit that
    /// accepted them (their receipt's position, on this lineage) was applied. A recovery retires its own when it has
    /// caught up (PROTOCOL §6.11).
    func retireAppliedRetained(_ report: inout ServerExchangeReport) async throws {
        if let record = try await store.serverRecovery(), !record.finished { return }
        let retained = try await store.serverRetainedEntries()
        guard !retained.isEmpty, let live = try await store.serverExchangeState().cursor else { return }
        var applied: [String] = []
        for entry in retained where !entry.unrestored && !entry.parked {
            // The archived receipt is the one the server stands by (a recovered original replaces a provisional one).
            let receipt = try archive.receipt(opID: entry.opID) ?? entry.receipt
            guard let epoch = receipt?["epoch"]?.integerValue, let seq = receipt?["seq"]?.integerValue else {
                // No receipt position (`op_id_conflict`): its slot was consumed by another fact, nothing of it returns.
                applied.append(entry.opID)
                continue
            }
            if try archive.contains(node: entry.opID) || receipt?["outcome"]?.stringValue == "rejected",
               epoch == live.epoch, seq <= live.seq { applied.append(entry.opID) }
        }
        guard !applied.isEmpty else { return }
        for chunk in FeedLibraryStore.chunks(applied, size: 50) {
            let result = try await store.retireServerRetained(chunk, deleting: Set(chunk), history: history, now: now())
            record(result, into: &report)
        }
    }
}
