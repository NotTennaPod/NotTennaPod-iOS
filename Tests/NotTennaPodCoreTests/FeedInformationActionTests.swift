import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedInformationActionTests {
    /// NotTennaPod shares the title and the plain feed address (no antennapod.org link), for every title and
    /// address the Android oracle covers, character for character, except whitespace a shared link would end at
    /// (Unicode White_Space): around the address it is left out, inside it is percent-encoded.
    @Test func shareIsTitleAndPlainFeedAddress() throws {
        struct Row: Decodable { let title, source, expected: String }
        struct Fixture: Decodable { let cases: [Row] }
        let file = try #require(Bundle.module.url(forResource: "feed-share", withExtension: "json", subdirectory: "Fixtures"))
        let data = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        #expect(data.cases.count == 365)
        var expected = ["  https://example.com  ": "https://example.com", "htt htt": "htt%20htt",
                        "https://\u{E9}xample.fr/a b": "https://\u{E9}xample.fr/a%20b"]
        for space in ["\t", "\n", "\u{0B}", "\u{0C}", "\r", " ", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2028}", "\u{2029}", "\u{3000}"] {
            expected["https://example.com/" + space] = "https://example.com/"
        }
        // The fixture's U+001C–U+001F endings are not White_Space (a shared link does not end there): shared as stored.
        for row in data.cases {
            let text = FeedShareText.make(title: row.title, source: row.source)
            let link = expected[row.source] ?? row.source
            #expect(text.utf16.elementsEqual((row.title + "\n\n" + link).utf16), "title=\(row.title), source=\(row.source)")
            #expect(!text.dropFirst(row.title.count).contains("antennapod.org"))
        }
    }

    private func withStore(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedURL-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func seed(_ store: FeedLibraryStore, identity: String, source: String,
                      state: FeedSubscriptionState = .subscribed) async throws -> LibraryFeed {
        try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, identifier: identity, title: identity, episodes: [
            .init(identifier: identity + "-episode", title: "An episode", publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
                  media: .init(url: "https://example.com/episode.mp3", size: 10))]),
            source: source, responseURL: URL(string: "https://example.com/feed")!, validator: "\"old\"", permanentRedirectURL: nil),
            subscriptionState: state)
    }

    @Test func URLUpdateMatchesEveryExactSourceAndPreservesOtherStateAcrossReopen() async throws {
        try await withStore { store, url in
            let original = "https://éxample.fr/feed"
            let sources = [original, original, original, "https://e\u{301}xample.fr/feed", original.uppercased(), original + "/", "prefix" + original, ""]
            let states: [FeedSubscriptionState] = [.subscribed, .archived, .notSubscribed]
            var ids: [Int64] = []
            for (index, source) in sources.enumerated() {
                let feed = try await seed(store, identity: "feed-\(index)", source: source, state: states[index % 3])
                ids.append(feed.id)
                try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Custom \(index)"; $0.keepUpdated = false }
                try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.positionMilliseconds = 1234; $0.userState.isFavorite = true }
            }
            for id in ids { try await store.recordFailure(.forbidden, feedID: id, date: Date(timeIntervalSince1970: 1_700_000_000)) }
            let before = try await store.feeds(), effects = try await store.pendingEffects()
            var logs: [Int64: [FeedLibraryLog]] = [:]
            for id in ids { logs[id] = try await store.logs(feedID: id) }
            let replacement = "  https://new.example/é?x=1&b=2#section  "
            #expect(try await store.updateFeedDownloadURL(original: original, updated: replacement) == Array(ids.prefix(3)))
            let after = try await store.feeds()
            for prior in before {
                var expected = prior
                if ids.prefix(3).contains(prior.id) { expected.source = replacement }
                let current = try #require(after.first { $0.id == prior.id })
                #expect(current == expected)
                #expect(current.source.utf16.elementsEqual(expected.source.utf16))
            }
            #expect(try await store.pendingEffects() == effects)
            for id in ids { #expect(try await store.logs(feedID: id) == logs[id]) }
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feeds() == after)
            try await reopened.close()
            #expect(try await store.updateFeedDownloadURL(original: "absent", updated: "unused").isEmpty)
            #expect(try await store.feeds() == after)
            // No validation or trimming: the source database operation stores
            // even empty user input. The subsequent fetch reports malformed URL.
            #expect(try await store.updateFeedDownloadURL(original: replacement, updated: "") == Array(ids.prefix(3)))
            #expect(try await store.feed(id: ids[0])?.source == "")
        }
    }

    @Test func URLUpdateFailureRollsBackAllMatchesAndCancellationDoesNotWrite() async throws {
        try await withStore { store, url in
            let first = try await seed(store, identity: "one", source: "same")
            let second = try await seed(store, identity: "two", source: "same")
            let before = try await store.feeds(), effects = try await store.pendingEffects()
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER reject_second_url BEFORE UPDATE ON feeds WHEN NEW.id = \(second.id) BEGIN SELECT RAISE(ABORT, 'injected URL failure'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.updateFeedDownloadURL(original: "same", updated: "new") }
            #expect(try await store.feeds() == before)
            #expect(try await store.pendingEffects() == effects)
            try db.execute("DROP TRIGGER reject_second_url"); try db.close()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.updateFeedDownloadURL(original: "same", updated: "cancelled")
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.feed(id: first.id)?.source == "same")
            #expect(try await store.feed(id: second.id)?.source == "same")
            #expect(try await store.updateFeedDownloadURL(original: "same", updated: "same") == [first.id, second.id])
        }
    }

    @Test func editPersistencePrecedesSelectedForcedRefreshAndNetworkFailureDoesNotUndoURL() async throws {
        try await withStore { store, _ in
            let selected = try await seed(store, identity: "selected", source: "https://old.example/feed")
            let other = try await seed(store, identity: "other", source: selected.source)
            let newSource = "https://new.example/feed"
            try await store.updateFeedDownloadURL(original: selected.source, updated: newSource)
            let transport = EditedURLTransport { (request: URLRequest) async throws -> FeedHTTPResponse in
                #expect(request.url?.absoluteString == newSource)
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
                #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
                #expect(try await store.feed(id: selected.id)?.source == newSource)
                #expect(try await store.feed(id: other.id)?.source == newSource)
                return FeedHTTPResponse(url: request.url!, status: 403, headers: [:], body: Data())
            }
            let refresh = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport))
            #expect(try await refresh.refresh(feedID: selected.id, force: true) == .failed(.forbidden))
            let selectedAfter = try #require(try await store.feed(id: selected.id))
            let otherAfter = try #require(try await store.feed(id: other.id))
            #expect(selectedAfter.source == newSource && selectedAfter.lastUpdateFailed)
            #expect(otherAfter.source == newSource && !otherAfter.lastUpdateFailed)
            #expect(otherAfter.validator == "\"old\"" && otherAfter.episodes == other.episodes)
            #expect(try await store.logs(feedID: selected.id).count == 1)
            #expect(try await store.logs(feedID: other.id).isEmpty)
        }
    }
}

private struct EditedURLTransport: FeedHTTPTransport {
    var sendRequest: @Sendable (URLRequest) async throws -> FeedHTTPResponse
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { try await sendRequest(request) }
}
