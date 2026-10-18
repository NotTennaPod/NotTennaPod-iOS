import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct LibrarySearchTests {
    private func run(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try await body(store); try await store.close()
    }
    private func insert(_ store: FeedLibraryStore, name: String, titles: [String], description: String = "") async throws -> LibraryFeed {
        try await store.insert(.init(feed: .init(format: .rss, title: name, description: description, author: "Search Author",
            episodes: titles.enumerated().map { index, title in .init(identifier: "\(index)", title: title,
                description: index == 0 ? "Second word <b>body</b>" : nil, publicationDate: Date(timeIntervalSince1970: Double(index + 1))) }),
            source: "https://example.org/\(name)", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
    }
    @Test func matchingUsesAllWordsRawDescriptionAndSQLiteWildcards() async throws {
        try await run { store in
            let feed = try await insert(store, name: "one", titles: ["First", "FIRST second", "first other", "Éclair", "éclair", "O'Brien", "a_b", "a%b"])
            #expect(try await store.search(query: "first second", feedID: feed.id).episodes.map(\.episode.details.title) == ["FIRST second", "First"])
            #expect(try await store.search(query: "<b>body</b>", feedID: feed.id).episodes.map(\.episode.details.title) == ["First"])
            #expect(try await store.search(query: "éclair", feedID: feed.id).episodes.map(\.episode.details.title) == ["éclair"])
            #expect(try await store.search(query: "O'Brien", feedID: feed.id).episodes.count == 1)
            #expect(try await store.search(query: "a_b", feedID: feed.id).episodes.map(\.episode.details.title) == ["a%b", "a_b"])
            #expect(try await store.search(query: "a%b", feedID: feed.id).episodes.count == 2)
            #expect(try await store.search(query: "' OR 1=1 --", feedID: feed.id).episodes.isEmpty)
            #expect(try await store.search(query: " \t\r\n ", feedID: feed.id) == .init())
            #expect(try await store.search(query: "first\u{a0}second", feedID: feed.id).episodes.isEmpty)
        }
    }
    @Test func scopeIncludesArchivedFeedButGlobalIncludesOnlySubscriptionsAndBothKindsOfResults() async throws {
        try await run { store in
            let one = try await insert(store, name: "Zulu", titles: ["shared item"], description: "shared podcast")
            let two = try await insert(store, name: "Alpha", titles: ["shared item"], description: "shared podcast")
            try await store.updatePreferences(feedID: two.id) { $0.subscriptionState = .archived }
            #expect(try await store.search(query: "shared", feedID: two.id).episodes.count == 1)
            #expect(try await store.search(query: "shared", feedID: two.id).feeds.isEmpty)
            let global = try await store.search(query: "shared")
            #expect(global.feeds.map(\.id) == [one.id]); #expect(global.episodes.map(\.feedID) == [one.id])
            try await store.updatePreferences(feedID: two.id) { $0.subscriptionState = .subscribed; $0.customTitle = "Custom alias" }
            #expect(try await store.search(query: "shared").feeds.map(\.id) == [two.id, one.id])
            #expect(try await store.search(query: "custom author").feeds.map(\.id) == [two.id])
            #expect(try await store.search(query: "shared", feedID: 999).episodes.isEmpty)
        }
    }
    @Test func resultCapUsesNewestFirstAndFreshStoredState() async throws {
        try await run { store in
            let feed = try await insert(store, name: "many", titles: (0..<310).map { "match \($0)" })
            let result = try await store.search(query: "match", feedID: feed.id)
            #expect(result.episodes.count == 300)
            #expect(result.episodes.first?.episode.details.title == "match 309")
            #expect(result.episodes.last?.episode.details.title == "match 10")
            let id = try #require(result.episodes.first?.episode.id)
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true }
            #expect(try await store.search(query: "match 309", feedID: feed.id).episodes.first?.episode.userState.isFavorite == true)
        }
    }
    /// The in-memory search over a loaded snapshot gives exactly the store's results.
    @Test func loadedLibrarySearchMatchesTheStoreExactly() async throws {
        try await run { store in
            let one = try await insert(store, name: "one", titles: ["First", "FIRST second", "first other", "Éclair", "éclair",
                "e\u{301}clair", "O'Brien", "a_b", "a%b", "🎙 mic", "x🎙y", "ÀÉÎ", "tab\tthere", "same", "same"], description: "shared podcast")
            let two = try await insert(store, name: "Alpha", titles: ["shared item", "Second shared"], description: "shared podcast")
            let three = try await insert(store, name: "zeta", titles: (0..<320).map { "match \($0 % 7) item" })
            try await store.updatePreferences(feedID: two.id) { $0.subscriptionState = .archived }
            try await store.updatePreferences(feedID: three.id) { $0.customTitle = "Custom alias" }
            let snapshot = try await store.snapshot()
            let queries = ["first second", "<b>body</b>", "éclair", "Éclair", "ÉCLAIR", "e\u{301}", "O'Brien", "a_b", "a%b", "_", "%", "%%",
                           "first\u{a0}second", "shared", "match", "match 3", "custom author", "custom", "e", "É_lair", "_clair", "x_y",
                           "🎙", "_🎙", "x%y", "àéî", "ÀÉÎ", "tab", "same", "SECOND", "b%y", "item 6", "search author", "zzz", "' OR 1=1 --", " \t "]
            for query in queries {
                for (feedID, archived) in [(nil, false), (nil, true), (one.id, false), (two.id, false), (three.id, false), (Int64(999), false)] as [(Int64?, Bool)] {
                    let expected = try await store.search(query: query, feedID: feedID, archived: archived)
                    let actual = try LibrarySearchResult.search(query: query, feeds: snapshot.feeds, deletionTargets: snapshot.deletionTargets,
                                                                feedID: feedID, archived: archived)
                    #expect(actual == expected, "query \(query) feed \(String(describing: feedID)) archived \(archived)")
                }
            }
        }
    }
}

private actor SearchReadGate {
    var pending: [String: CheckedContinuation<LibrarySearchResult, Never>] = [:]
    func read(_ query: String) async -> LibrarySearchResult {
        await withCheckedContinuation { pending[query] = $0 }
    }
    func contains(_ query: String) -> Bool { pending[query] != nil }
    func release(_ query: String) {
        var result = LibrarySearchResult()
        result.feeds = [.init(id: 1, source: query, metadata: .init(format: .rss, title: query), episodes: [])]
        pending.removeValue(forKey: query)?.resume(returning: result)
    }
}

@MainActor @Suite struct LibrarySearchSessionTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await predicate())
    }
    @Test func oldReadCannotReplaceNewQueryAndEmptyClearRetiresWork() async throws {
        let gate = SearchReadGate()
        let session = LibrarySearchSession(feedID: 7, feedTitle: "Podcast", delay: {}, read: { query, _ in await gate.read(query) })
        session.change("old"); try await wait { await gate.contains("old") }
        session.change("new"); try await wait { await gate.contains("new") }
        await gate.release("new"); try await wait { session.result.feeds.first?.title == "new" }
        await gate.release("old")
        session.change("pending"); try await wait { await gate.contains("pending") }
        session.change(""); await gate.release("pending")
        #expect(session.result.feeds.first?.title == "new"); #expect(!session.loading)
        session.clearScope(); #expect(session.feedID == nil)
    }
    @Test func submitSkipsDelayAndScopeChangeRerunsSameQuery() async throws {
        let gate = SearchReadGate()
        let session = LibrarySearchSession(feedID: 7, feedTitle: "Podcast", delay: { try await Task.sleep(for: .seconds(100)) },
            read: { query, id in await gate.read("\(query)-\(id ?? 0)") })
        session.change("term"); #expect(!(await gate.contains("term-7")))
        session.submit(); #expect(session.loading)
        try await wait { await gate.contains("term-7") }
        await gate.release("term-7"); try await wait { !session.loading }
        session.clearScope(); try await wait { await gate.contains("term-0") }
        await gate.release("term-0"); try await wait { session.result.feeds.first?.title == "term-0" }
        session.cancel()
    }
}

private actor SearchRevisionGate {
    enum Failure: Error { case read }
    var requests: [CheckedContinuation<LibrarySearchResult, any Error>] = []
    func read() async throws -> LibrarySearchResult {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    var pending: Int { requests.count }
    func finish(_ result: LibrarySearchResult) { requests.removeFirst().resume(returning: result) }
    func fail() { requests.removeFirst().resume(throwing: Failure.read) }
}

extension LibrarySearchSessionTests {
    @Test func acceptedResultRevisionsAndGuardedStatePatchesPreserveOtherFields() async throws {
        let gate = SearchRevisionGate()
        let session = LibrarySearchSession(feedID: 7, feedTitle: "Podcast", delay: {}, read: { _, _ in try await gate.read() })
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        var episode = LibraryEpisode(id: 9, details: .init(title: "Old", media: .init(url: "https://example.test/media", size: 120017, durationMilliseconds: 120_000)))
        episode.userState.playState = .new; episode.userState.positionMilliseconds = 90_123; episode.userState.isFavorite = true
        var result = LibrarySearchResult(); result.episodes = [.init(feedID: 7, episode: episode)]
        #expect(session.resultRevision == 0)
        session.change("term "); try await wait { await gate.pending == 1 }
        #expect(session.resultRevision == 0)
        await gate.finish(result); try await wait { session.resultRevision == 1 }
        let revision = session.resultRevision
        #expect(session.applyCommittedState(.init(playState: .unplayed), episodeID: 9, expectedResultRevision: revision))
        var expected = episode; expected.userState.playState = .unplayed
        #expect(session.result.episodes.first?.episode == expected)
        #expect(session.resultRevision == revision)
        #expect(!session.applyCommittedState(.init(playState: .played), episodeID: 999, expectedResultRevision: revision))
        session.submit(); try await wait { await gate.pending == 1 }
        #expect(session.loading && session.resultRevision == revision)
        await gate.fail(); try await wait { failures == 1 }
        #expect(session.resultRevision == revision && session.result.episodes.first?.episode == expected)
        session.change(""); #expect(session.resultRevision == revision)
        #expect(session.result.episodes.first?.episode == expected)
        session.change("term "); try await wait { await gate.pending == 1 }
        // A new accepted result replaces identity even when values are equal.
        var equal = result; equal.episodes = [.init(feedID: 7, episode: expected)]
        await gate.finish(equal); try await wait { session.resultRevision == revision + 1 }
        #expect(!session.applyCommittedState(.init(playState: .played, resetPosition: true), episodeID: 9, expectedResultRevision: revision))
        #expect(session.result.episodes.first?.episode == expected)
        session.refresh(); try await wait { await gate.pending == 1 }
        session.cancel(); await gate.finish(result)
        session.change("")
        #expect(session.resultRevision == revision + 1 && session.result.episodes.first?.episode == expected)
    }
}


extension LibrarySearchSessionTests {
    @Test func successReconciliationRefreshesRetainedEmptyQueryAndIsRequestFenced() async throws {
        let gate = SearchRevisionGate()
        let session = LibrarySearchSession(feedID: 7, feedTitle: "Podcast", read: { _, _ in try await gate.read() })
        var first = LibrarySearchResult()
        first.episodes = [.init(feedID: 7, episode: .init(id: 9, details: .init(title: "First")))]
        session.change("term "); try await wait { await gate.pending == 1 }
        await gate.finish(first); try await wait { session.resultRevision == 1 }
        session.change("")
        session.reconcileCurrentData(); try await wait { await gate.pending == 1 }
        var committed = first
        committed.episodes = [.init(feedID: 7, episode: .init(id: 9, details: .init(title: "Committed")))]
        await gate.finish(committed); try await wait { session.resultRevision == 2 }
        #expect(session.query.isEmpty && session.result.episodes.first?.episode.details.title == "Committed")
        session.reconcileCurrentData(); try await wait { await gate.pending == 1 }
        session.change("new query "); try await wait { await gate.pending == 2 }
        await gate.finish(first); await gate.finish(LibrarySearchResult())
        try await wait { session.resultRevision == 3 }
        #expect(session.result.episodes.isEmpty && session.query == "new query ")
    }
}
