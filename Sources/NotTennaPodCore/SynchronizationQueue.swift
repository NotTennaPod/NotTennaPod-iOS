import Foundation

extension FeedLibraryStore {
    public func synchronizationState() throws -> SynchronizationState {
        guard let data = try database.rows("SELECT record FROM synchronization_state WHERE id = 1").first?.first?.data else {
            return SynchronizationState()
        }
        return try JSONDecoder().decode(SynchronizationState.self, from: data)
    }

    func saveSynchronizationState(_ state: SynchronizationState) throws {
        try database.execute("INSERT INTO synchronization_state(id, record) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
            [.blob(try JSONEncoder().encode(state))])
        // Wake hints carry no uncommitted data. This actor cannot serve the
        // observer's read until the enclosing transaction commits or rolls back.
        for listener in synchronizationListeners.values { listener.yield(()) }
    }

    public func synchronizationChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            synchronizationListeners[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSynchronizationListener(id) }
            }
        }
    }
    private func removeSynchronizationListener(_ id: UUID) { synchronizationListeners[id] = nil }

    public func selectSynchronizationAccount(_ accountID: UUID?, expectedAccountID: UUID? = nil) throws {
        try Task.checkCancellation()
        let changed = try database.transaction {
            var state = try synchronizationState()
            if let expectedAccountID, state.accountID != expectedAccountID { throw CancellationError() }
            guard state.accountID != accountID else { return false }
            let mobile = state.allowMobile, host = state.lastHost, previousSuccess = state.lastAttemptSuccessful
            var retired = state.credentialCleanup ?? []
            if let credential = state.account?.credentialID { retired.append(credential) }
            state = SynchronizationState(); state.accountID = accountID; state.epoch = UUID(); state.allowMobile = mobile
            state.lastHost = host; state.credentialCleanup = retired; state.lastAttemptSuccessful = previousSuccess
            try database.execute("DELETE FROM synchronization_outbox")
            try saveSynchronizationState(state)
            try Task.checkCancellation()
            return true
        }
        if changed { synchronizationExecution = nil }
    }

    public func setSynchronizationMobileAllowed(_ value: Bool) throws {
        try database.transaction {
            var state = try synchronizationState(); state.allowMobile = value
            try saveSynchronizationState(state)
        }
    }

    public func synchronizationQueue() throws -> [SynchronizationQueuedChange] {
        try database.rows("SELECT id, record FROM synchronization_outbox ORDER BY id").map { row in
            guard let id = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
            return .init(id: id, value: try JSONDecoder().decode(SynchronizationQueuedChange.Value.self, from: data))
        }
    }

    @discardableResult
    public func requestSynchronization(immediately: Bool = false, ifNotRecent: Bool = false,
                                       full: Bool = false, now: Date = Date(),
                                       manualRequestID: UUID? = nil, allowMobile: Bool? = nil,
                                       expectedEpoch: UUID? = nil) throws -> SynchronizationRequest? {
        try Task.checkCancellation()
        return try database.transaction {
            try requireManualRefresh(manualRequestID)
            var state = try synchronizationState()
            if let expectedEpoch, state.epoch != expectedEpoch { throw CancellationError() }
            if let allowMobile { state.allowMobile = allowMobile }
            if ifNotRecent, now.timeIntervalSince(state.lastAttempt ?? Date(timeIntervalSince1970: 0)) <= 600 { return nil }
            if full {
                state.epoch = UUID(); state.subscriptionTimestamp = 0; state.episodeTimestamp = 0; state.lastAttempt = nil
            }
            let request = SynchronizationRequest(notBefore: now.addingTimeInterval(immediately || full ? 0 : (synchronizationExecution == nil ? 20 : 120)), allowMobile: state.allowMobile,
                announcesStart: synchronizationExecution == nil)
            state.request = request
            try saveSynchronizationState(state)
            try Task.checkCancellation()
            return request
        }
    }

    public func beginSynchronization(_ request: SynchronizationRequest, now: Date = Date()) throws -> SynchronizationState {
        try Task.checkCancellation()
        let state = try database.transaction {
            var state = try synchronizationState()
            guard state.request == request, synchronizationExecution == nil else { throw CancellationError() }
            if state.accountID != nil { state.lastAttempt = now }
            try saveSynchronizationState(state)
            return state
        }
        synchronizationExecution = request.id
        return state
    }

    /// Ack only the uploaded rows and cursor from this account epoch. Entries
    /// appended while the network was suspended must remain for another pass.
    public func acknowledgeSynchronization(epoch: UUID, phase: SynchronizationPhase,
                                           ids: [Int64], timestamp: Int64) throws {
        try Task.checkCancellation()
        try database.transaction {
            var state = try requireSynchronization(epoch)
            for id in ids {
                try database.execute("DELETE FROM synchronization_outbox WHERE id = ? AND phase = ?", [.integer(id), .text(phase.rawValue)])
            }
            switch phase {
            case .subscriptions: state.subscriptionTimestamp = timestamp
            case .episodes: state.episodeTimestamp = timestamp
            }
            try saveSynchronizationState(state)
            try Task.checkCancellation()
        }
    }

    public func finishSynchronization(_ request: SynchronizationRequest, epoch: UUID,
                                       successful: Bool?, retry: Bool = false, now: Date = Date(),
                                       releaseExecution: Bool = true) throws {
        defer { if releaseExecution && synchronizationExecution == request.id { synchronizationExecution = nil } }
        try Task.checkCancellation()
        try database.transaction {
            var state = try requireSynchronization(epoch)
            if let successful { state.lastAttemptSuccessful = successful }
            if state.request?.id == request.id {
                if retry {
                    var next = request
                    next.attempts = min(request.attempts + 1, 30)
                    next.notBefore = now.addingTimeInterval(min(18_000, 600 * pow(2, Double(next.attempts - 1))))
                    state.request = next
                } else { state.request = nil }
            }
            try saveSynchronizationState(state)
        }
    }

    public func releaseSynchronizationExecution(_ request: SynchronizationRequest) {
        if synchronizationExecution == request.id { synchronizationExecution = nil }
    }

    func requireSynchronization(_ epoch: UUID) throws -> SynchronizationState {
        let state = try synchronizationState()
        guard state.epoch == epoch else { throw CancellationError() }
        return state
    }

    /// Invoked inside the library mutation transaction, never as a later scan of
    /// historical effects from before an account was connected.
    func queueSynchronizationEffect(_ effect: FeedLibraryEffect) throws {
        var state = try synchronizationState()
        guard state.accountID != nil else { return }
        func action(_ episode: LibraryEpisode, _ source: String, _ kind: SynchronizationEpisodeAction.Kind,
                    started: Int32 = -1, completed: Bool = false) -> SynchronizationQueuedChange.Value? {
            guard !source.isLocalFeedSource, let media = episode.details.media, let url = media.url else { return nil }
            return .episode(.init(podcast: source, episode: url, guid: episode.details.identifier, action: kind,
                timestamp: effect.date, started: started / (started < 0 ? 1 : 1_000),
                position: (completed ? media.durationMilliseconds : episode.userState.positionMilliseconds) / 1_000,
                total: media.durationMilliseconds / 1_000))
        }
        let values: [SynchronizationQueuedChange.Value]
        switch effect.kind {
        case .feedAdded(let source): values = source.isLocalFeedSource ? [] : [.added(source)]
        case .feedRemoved(let source): values = source.isLocalFeedSource ? [] : [.removed(source)]
        case .episodeStateChanged(let event):
            values = event.episode.map { [.episode(.init(podcast: event.podcast, episode: $0, guid: event.guid,
                action: event.kind == .play ? .play : .new, timestamp: effect.date,
                started: event.started, position: event.position, total: event.total))] } ?? []
        case .episodePlayed(let episode, let source, let start, let completed):
            values = start >= 0 && (completed || start < episode.userState.positionMilliseconds)
                ? action(episode, source, .play, started: start, completed: completed).map { [$0] } ?? [] : []
        case .downloadCompleted(let source, let episode, let synchronize):
            values = synchronize ? action(episode, source, .download).map { [$0] } ?? [] : []
        case .downloadFileDeleted(let episode, let source, let synchronize):
            values = synchronize ? action(episode, source, .delete).map { [$0] } ?? [] : []
        case .syncCompletedEpisodes(let source, let episodes):
            values = source.isLocalFeedSource ? [] : episodes.compactMap { episode in
                episode.mediaURL.map { .episode(.init(podcast: source, episode: $0, guid: episode.identifier, action: .play,
                    timestamp: effect.date, started: episode.totalSeconds, position: episode.totalSeconds, total: episode.totalSeconds)) }
            }
        default: values = []
        }
        guard !values.isEmpty else { return }
        for value in values {
            let opposite: SynchronizationQueuedChange.Value?
            switch value {
            case .added(let url): opposite = .removed(url)
            case .removed(let url): opposite = .added(url)
            default: opposite = nil
            }
            if let opposite, let old = try synchronizationQueue().first(where: { change in
                switch (change.value, opposite) {
                case (.added(let first), .added(let second)), (.removed(let first), .removed(let second)):
                    first.utf16.elementsEqual(second.utf16)
                default: false
                }
            }) {
                try database.execute("DELETE FROM synchronization_outbox WHERE id = ?", [.integer(old.id)])
            }
            try database.execute("INSERT INTO synchronization_outbox(phase, record) VALUES (?, ?)",
                [.text(value.phase.rawValue), .blob(try JSONEncoder().encode(value))])
        }
        state.request = SynchronizationRequest(notBefore: synchronizationClock().addingTimeInterval(synchronizationExecution == nil ? 20 : 120), allowMobile: state.allowMobile,
            announcesStart: synchronizationExecution == nil)
        try saveSynchronizationState(state)
    }
}
