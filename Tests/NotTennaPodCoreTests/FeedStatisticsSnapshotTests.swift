import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedStatisticsSnapshotTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let last = Date(timeIntervalSince1970: 20_000 * 86_400 + 43_200)

    private func feed() -> LibraryFeed {
        var state = EpisodeUserState()
        state.playState = .played
        let episodes = (0..<4).map { index -> LibraryEpisode in
            // The newest release is text-only: dropping non-media episodes would
            // incorrectly move the predicted date a full day earlier.
            let media: ParsedMedia? = index == 3 ? nil : ParsedMedia(url: "fixture://\(index)", size: 0, durationMilliseconds: 3_600_000)
            let details = ParsedEpisode(identifier: "\(index)", title: "Episode \(index)",
                publicationDate: last.addingTimeInterval(Double(index - 3) * 86_400), media: media)
            return LibraryEpisode(id: Int64(index + 1), details: details, userState: state)
        }
        return LibraryFeed(id: 42, source: "https://example.test/feed", metadata: ParsedFeed(format: .rss, title: "Original"),
                           episodes: episodes)
    }

    @Test func completeHistoryAndSourceVisibilitySurviveFiltersOrderAndPreferences() throws {
        for subscription in FeedSubscriptionState.allCases {
            for local in [false, true] {
                for enabled in [false, true] {
                    for filtered in [false, true] {
                        for reversed in [false, true] {
                            var feed = feed()
                            feed.subscriptionState = subscription
                            feed.keepUpdated = enabled
                            feed.customTitle = "Custom"
                            if local { feed.source = "antennapod_local:folder" }
                            if filtered { feed.episodeFilterValues = ["unplayed"] }
                            if reversed { feed.episodes.reverse() }
                            let snapshot = try FeedStatisticsSnapshot(feed: feed, now: last, timeZone: utc)
                            if subscription == .notSubscribed {
                                #expect(snapshot == nil)
                                continue
                            }
                            let actual = try #require(snapshot)
                            #expect(actual.feedID == 42 && actual.title == "Custom")
                            #expect(actual.statistics.episodes == 4 && actual.statistics.episodesStarted == 4)
                            #expect(actual.statistics.totalSeconds == 10_800 && actual.statistics.playedSeconds == 10_800)
                            #expect(actual.prediction?.schedule == .daily)
                            #expect(actual.prediction?.nextExpectedDate == last.addingTimeInterval(86_400))
                            if local {
                                #expect(actual.release.next == .textKey("local_folder"))
                                #expect(actual.release.scheduleKeys == ["local_folder"])
                            } else if !enabled {
                                #expect(actual.release.next == .textKey("updates_disabled_label"))
                                #expect(actual.release.scheduleKeys == ["updates_disabled_label"])
                            } else {
                                #expect(actual.release.next == .date(last.addingTimeInterval(86_400)))
                                #expect(actual.release.scheduleKeys == ["release_schedule_daily"])
                            }
                            if filtered { #expect(feed.filteredDisplayEpisodes(queuedIDs: []).isEmpty) }
                        }
                    }
                }
            }
        }
    }

    @Test func emptySingleAndLegacyMissingDatesDoNotInventRecentHistory() throws {
        var feed = feed()
        feed.episodes = []
        #expect(try FeedStatisticsSnapshot(feed: feed, now: last, timeZone: utc) == nil)
        feed.episodes = [self.feed().episodes[0]]
        let single = try #require(try FeedStatisticsSnapshot(feed: feed, now: last, timeZone: utc))
        #expect(single.prediction == nil && single.statistics.episodes == 1)
        #expect(single.release.next == .textKey("statistics_expected_next_episode_unknown"))
        feed.episodes.append(self.feed().episodes[1])
        for index in feed.episodes.indices { feed.episodes[index].details.publicationDate = nil }
        let legacy = try #require(try FeedStatisticsSnapshot(feed: feed, now: last, timeZone: utc))
        #expect(legacy.prediction == (try ReleaseSchedule.guess([Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0)], timeZone: utc)))
        #expect(legacy.release.next == .textKey("statistics_expected_next_episode_unknown"))
    }

    /// Feeds saved before the "Keep updated" setting existed read as kept updated (Android's default).
    /// Persistence of both explicit values is covered by the reopen test below.
    @Test func olderRecordsDefaultToKeptUpdated() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feed())) as? [String: Any])
        object.removeValue(forKey: "keepUpdatedValue")
        let legacy = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.keepUpdated)
    }

    @Test func savedPreferenceAndHistoryRemainConsistentAfterRefreshReopenAndFailedEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsSnapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        var parsed = ParsedFeed(format: .rss, title: "Original", episodes: feed().episodes.map(\.details))
        func fetched(_ parsed: ParsedFeed) -> FetchedFeed {
            FetchedFeed(feed: parsed, source: "https://example.test/feed",
                responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
        }
        let inserted = try await store.insert(fetched(parsed))
        #expect(inserted.keepUpdated)
        #expect(try await store.statisticsSnapshot(feedID: -1, now: last, timeZone: utc) == nil)
        try await store.updatePreferences(feedID: inserted.id) { $0.keepUpdated = false; $0.customTitle = "Custom" }
        try await store.setEpisodeFilter(feedID: inserted.id, filter: FeedEpisodeFilter(values: ["played"]))
        parsed.title = "Refreshed"
        _ = try await store.insert(fetched(parsed))
        let before = try #require(try await store.statisticsSnapshot(feedID: inserted.id, now: last, timeZone: utc))
        #expect(before.statistics.episodes == 4 && before.title == "Custom")
        #expect(before.release.next == .textKey("updates_disabled_label"))
        #expect(before.prediction?.nextExpectedDate == last.addingTimeInterval(86_400))
        enum EditError: Error { case rejected }
        await #expect(throws: EditError.self) {
            try await store.updatePreferences(feedID: inserted.id) {
                $0.keepUpdated = true; $0.customTitle = "Rejected"; throw EditError.rejected
            }
        }
        #expect(try await store.statisticsSnapshot(feedID: inserted.id, now: last, timeZone: utc) == before)
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.statisticsSnapshot(feedID: inserted.id, now: last, timeZone: utc) == before)
        try await reopened.updatePreferences(feedID: inserted.id) { $0.keepUpdated = true; $0.subscriptionState = .archived }
        let enabled = try #require(try await reopened.statisticsSnapshot(feedID: inserted.id, now: last, timeZone: utc))
        #expect(enabled.release.next == .date(last.addingTimeInterval(86_400)))
        try await reopened.updatePreferences(feedID: inserted.id) { $0.subscriptionState = .notSubscribed }
        #expect(try await reopened.statisticsSnapshot(feedID: inserted.id, now: last, timeZone: utc) == nil)
        try await reopened.close()
    }
}
