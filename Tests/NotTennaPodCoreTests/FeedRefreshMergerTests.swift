import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedRefreshMergerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func episode(_ id: String, date: Double? = 100, title: String? = nil,
                         media: Bool = true) -> ParsedEpisode {
        ParsedEpisode(identifier: id, title: title ?? "Title \(id)", link: "link-\(id)",
                      publicationDate: date.map(Date.init(timeIntervalSince1970:)),
                      media: media ? ParsedMedia(url: "media-\(id)", size: 32_768, mimeType: "audio/mpeg",
                                                 durationMilliseconds: 1_000_000) : nil)
    }

    private func parsed(_ episodes: [ParsedEpisode]) -> ParsedFeed {
        ParsedFeed(format: .rss, title: "Feed", episodes: episodes)
    }

    private func stored(_ episodes: [ParsedEpisode]) -> LibraryFeed {
        LibraryFeed(id: 10, source: "https://example.test/feed", metadata: parsed([]),
                    episodes: episodes.enumerated().map { LibraryEpisode(id: Int64($0.offset + 1), details: $0.element) })
    }

    private func options() -> FeedRefreshOptions { FeedRefreshOptions(now: now, timeZone: .gmt) }

    private func merge(_ incoming: [ParsedEpisode], saved: LibraryFeed,
                       options: FeedRefreshOptions? = nil) -> FeedRefreshResult {
        var nextID: Int64 = 100
        return FeedRefreshMerger.merge(parsed(incoming), into: saved, options: options ?? self.options()) {
            defer { nextID += 1 }
            return nextID
        }
    }

    @Test func originalAddOrUpdateScenarioKeepsListeningStateAndOlderEpisodes() {
        var feed = stored((0..<3).map { episode("item-\($0)", date: Double($0 + 1)) })
        feed.episodes[2].userState.playState = .played
        feed.episodes[2].userState.positionMilliseconds = 500
        let result = merge((2..<5).map { episode("item-\($0)", date: Double($0 + 1)) }, saved: feed)
        #expect(result.feed.episodes.count == 5)
        let old = result.feed.episodes.first { $0.details.identifier == "item-2" }
        #expect(old?.id == 3)
        #expect(old?.userState == feed.episodes[2].userState)
        #expect(Set(result.feed.episodes.map(\.id)).count == 5)
        #expect(result.removedEpisodes.isEmpty)
    }

    @Test func firstInsertionKeepsDuplicatesAndDoesNotApplyRefreshInboxRules() {
        var entries = [episode("a", date: nil), episode("b", date: nil, title: "Title a")]
        entries[1].media = entries[0].media
        var nextID: Int64 = 1
        let feed = FeedRefreshMerger.insert(parsed(entries), feedID: 10, source: "source", options: options()) {
            defer { nextID += 1 }
            return nextID
        }
        #expect(feed.episodes.map(\.id) == [1, 2])
        #expect(feed.episodes.allSatisfy { $0.userState.playState == .unplayed && $0.details.publicationDate == now })
        #expect(feed.metadata.episodes.isEmpty)
        let repeated = merge(entries, saved: feed)
        #expect(repeated.duplicates.count == 1)
        #expect(repeated.feed.episodes.count == 2)
    }

    @Test func mediaAppearingResetsPlayedEpisodeToInboxButPreservesOtherUserChoices() {
        var feed = stored([episode("a", media: false)])
        feed.episodes[0].userState.playState = .played
        feed.episodes[0].userState.isFavorite = true
        feed.episodes[0].userState.autoDownloadEnabled = false
        let result = merge([episode("a")], saved: feed)
        #expect(result.feed.episodes[0].userState.playState == .new)
        #expect(result.feed.episodes[0].userState.isFavorite)
        #expect(!result.feed.episodes[0].userState.autoDownloadEnabled)
        #expect(result.feed.episodes[0].id == 1)
    }

    @Test func metadataRefreshPreservesDownloadedFilePositionStatisticsAndMeasuredDuration() {
        var feed = stored([episode("a")])
        var state = EpisodeUserState()
        state.playState = .played
        state.positionMilliseconds = 42_000
        state.playedDurationMilliseconds = 55_000
        state.timeSpentMilliseconds = 60_000
        state.lastPlayedTimeMilliseconds = 1_700_000_000_000
        state.playbackCompletionDate = now
        state.localFileURL = "file:///saved.mp3"
        state.isDownloaded = true
        state.downloadDate = now.addingTimeInterval(-1_000)
        state.isFavorite = true
        state.autoDownloadEnabled = false
        feed.episodes[0].userState = state
        var incoming = episode("a", date: 200, title: "Changed title")
        incoming.media = ParsedMedia(url: "new-url", size: 65_536, mimeType: "audio/mp4", durationMilliseconds: 80_000)
        incoming.description = "Shorter description is allowed on refresh"
        let result = merge([incoming], saved: feed)
        let item = result.feed.episodes[0]
        #expect(item.userState == state)
        #expect(item.details.media == ParsedMedia(url: "new-url", size: 65_536, mimeType: "audio/mp4",
                                                  durationMilliseconds: 1_000_000))
        #expect(item.details.title == incoming.title)
        #expect(item.details.description == incoming.description)
        #expect(item.details.publicationDate == incoming.publicationDate)
    }

    @Test func absentMetadataRetainsOldValuesAndExplicitEmptyValuesReplaceThem() {
        var original = episode("a")
        original.description = "description"
        original.imageURL = "art"
        original.paymentLink = "payment"
        original.chapterURL = "chapters"
        original.socialInteractionURL = "social"
        original.transcript = FeedTranscript(format: .json, url: "transcript")
        let feed = stored([original])
        var incoming = ParsedEpisode(identifier: "a")
        #expect(merge([incoming], saved: feed).feed.episodes[0].details == original)
        incoming.title = ""
        incoming.description = ""
        incoming.link = ""
        incoming.imageURL = ""
        incoming.paymentLink = ""
        incoming.chapterURL = ""
        incoming.socialInteractionURL = ""
        incoming.transcript = FeedTranscript(format: .srt, url: "lower-priority-new-transcript")
        let updated = merge([incoming], saved: feed).feed.episodes[0].details
        #expect(updated.title == "" && updated.description == "" && updated.link == "")
        #expect(updated.imageURL == "" && updated.paymentLink == "" && updated.chapterURL == "")
        #expect(updated.socialInteractionURL == "")
        #expect(updated.transcript == incoming.transcript)
        #expect(updated.media == original.media)
    }

    @Test func existingChaptersSurviveFeedChangesEvenWhenNotLoaded() {
        let chapter = ParsedChapter(startMilliseconds: 0, title: "Original")
        let replacement = ParsedChapter(startMilliseconds: 10, title: "Replacement")
        for loaded in [false, true] {
            var feed = stored([episode("a")])
            feed.episodes[0].hasStoredChapters = true
            feed.episodes[0].details.chapters = loaded ? [chapter] : nil
            var incoming = episode("a")
            incoming.chapters = [replacement]
            let result = merge([incoming], saved: feed)
            #expect(result.feed.episodes[0].details.chapters == (loaded ? [chapter] : nil))
        }
        var incoming = episode("a")
        incoming.chapters = []
        let result = merge([incoming], saved: stored([episode("a")]))
        #expect(result.feed.episodes[0].details.chapters == [])
        #expect(result.feed.episodes[0].hasStoredChapters)
    }

    @Test func durationAndSizeUpdatesRespectPositiveValueBoundaries() {
        for oldDuration: Int32 in [-1, 0, 1, 100_000] {
            for newDuration: Int32 in [-1, 0, 1, 200_000] {
                for size: Int64 in [-1, 0, 1, 40_000] {
                    var feed = stored([episode("a")])
                    feed.episodes[0].details.media?.durationMilliseconds = oldDuration
                    var incoming = episode("a")
                    incoming.media = ParsedMedia(url: nil, size: size, mimeType: nil,
                                                 durationMilliseconds: newDuration)
                    let media = merge([incoming], saved: feed).feed.episodes[0].details.media
                    #expect(media?.durationMilliseconds == (oldDuration <= 0 && newDuration > 0 ? newDuration : oldDuration))
                    #expect(media?.size == (size > 0 ? size : 32_768))
                    #expect(media?.mimeType == "audio/mpeg")
                    #expect(media?.url == nil)
                }
            }
        }
    }

    @Test func repairedIdentifierKeepsIdentityAndProducesSyncFromOldMediaBeforeUpdate() {
        for state in FeedSubscriptionState.allCases {
            for played in [false, true] {
                var feed = stored([episode("old")])
                feed.subscriptionState = state
                feed.episodes[0].userState.playState = played ? .played : .unplayed
                var replacement = episode("new", title: "New title")
                replacement.media = feed.episodes[0].details.media
                replacement.media?.durationMilliseconds = 50_000
                let result = merge([replacement], saved: feed)
                #expect(result.feed.episodes.count == 1)
                #expect(result.feed.episodes[0].id == 1)
                #expect(result.feed.episodes[0].details.identifier == "new")
                #expect(result.feed.episodes[0].userState == feed.episodes[0].userState)
                #expect(result.duplicates == [.changedIdentifier(previous: feed.episodes[0].details,
                                                               replacement: replacement, episodeID: 1)])
                #expect(result.completedEpisodeSync.count == (played && state != .notSubscribed ? 1 : 0))
                if let sync = result.completedEpisodeSync.first {
                    #expect(sync.totalSeconds == 1_000)
                    #expect(sync.identifier == "new" && sync.mediaURL == "media-old")
                }
            }
        }
    }

    @Test func firstSortedDuplicateWinsDespiteMisleadingOldestSourceComment() {
        var older = episode("older", date: 100)
        var newer = episode("newer", date: 200)
        older.media?.url = "same-url"
        newer.media?.url = "same-url"
        let result = merge([older, newer], saved: stored([]))
        #expect(result.feed.episodes.map(\.details.identifier) == ["newer"])
        #expect(result.duplicates == [.repeatedEpisode(ignored: older, canonical: newer)])
        newer.publicationDate = nil
        let nilFirst = merge([older, newer], saved: stored([]))
        #expect(nilFirst.feed.episodes.map(\.details.identifier) == ["newer"])
        #expect(nilFirst.feed.episodes[0].details.publicationDate == now)
    }

    @Test func equalDatesRetainSourceOrderAndCanonicalDuplicate() {
        var first = episode("first")
        var second = episode("second")
        first.media?.url = "same"
        second.media?.url = "same"
        #expect(merge([first, second], saved: stored([])).feed.episodes[0].details.identifier == "first")
        #expect(merge([second, first], saved: stored([])).feed.episodes[0].details.identifier == "second")
    }

    @Test func undatedEpisodesWithOnlySimilarTitlesRemainDistinct() {
        let first = episode("a", date: nil, title: "Same title")
        let second = episode("b", date: nil, title: "Same title")
        let result = merge([first, second], saved: stored([]))
        #expect(result.feed.episodes.count == 2)
        #expect(result.duplicates.isEmpty)
    }

    @Test func duplicateGUIDWithDifferentTitlesUpdatesSingleRecordInSortedOrder() {
        let recent = episode("same", date: 200, title: "Recent")
        var older = episode("same", date: 100, title: "Older")
        older.media?.url = "different-media"
        let result = merge([older, recent], saved: stored([]))
        #expect(result.feed.episodes.count == 1)
        #expect(result.feed.episodes[0].details.title == "Older")
        #expect(result.duplicates.isEmpty)
    }

    @Test func incomingIndicesIncludeSkippedDuplicatesWhenInsertingIntoSavedOrder() {
        let feed = stored([episode("saved-1", date: 1), episode("saved-2", date: 2), episode("saved-3", date: 3)])
        let canonical = episode("new", date: 300)
        var duplicate = episode("duplicate", date: 200)
        duplicate.media = canonical.media
        let older = episode("older", date: 100)
        let result = merge([older, duplicate, canonical], saved: feed)
        #expect(result.feed.episodes.map(\.details.identifier) == ["new", "saved-1", "older", "saved-2", "saved-3"])
    }

    @Test func largeRefreshRetainsEveryIdentityAndUserStateWithoutSharedMutation() {
        let oldEpisodes = (0..<1_000).map { episode("id-\($0)", date: Double($0 + 1)) }
        var feed = stored(oldEpisodes)
        for index in feed.episodes.indices {
            feed.episodes[index].userState.playState = index.isMultiple(of: 2) ? .played : .new
            feed.episodes[index].userState.positionMilliseconds = Int32(index * 10)
        }
        let incoming = (500..<1_500).map { episode("id-\($0)", date: Double($0 + 1), title: "Updated \($0)") }
        var nextID: Int64 = 1_001
        let result = FeedRefreshMerger.merge(parsed(incoming), into: feed, options: options()) {
            defer { nextID += 1 }
            return nextID
        }
        #expect(result.feed.episodes.count == 1_500)
        #expect(Set(result.feed.episodes.map(\.id)).count == 1_500)
        let byID = Dictionary(uniqueKeysWithValues: result.feed.episodes.map { ($0.id, $0) })
        for old in feed.episodes {
            #expect(byID[old.id]?.userState == old.userState)
            #expect(byID[old.id]?.details.identifier == old.details.identifier)
        }
        #expect(result.duplicates.isEmpty && result.removedEpisodes.isEmpty)
    }

    @Test func changedTitlesWithSameGUIDBypassHeuristicsButDoNotRewriteIdentifier() {
        let feed = stored([episode("same")])
        let changed = episode("same", date: 900_000, title: "Completely changed")
        let result = merge([changed], saved: feed)
        #expect(result.duplicates.isEmpty)
        #expect(result.feed.episodes.count == 1 && result.feed.episodes[0].id == 1)
    }

    @Test func localFeedsSkipDuplicateGuessingAndNeverOverrideQueueForAutoDownload() {
        var feed = stored([episode("a")])
        feed.newEpisodesAction = .queue
        feed.autoDownload = .enabled
        var replacement = episode("b")
        replacement.media = feed.episodes[0].details.media
        var settings = options()
        settings.isLocalFeed = true
        let result = merge([replacement], saved: feed, options: settings)
        #expect(result.feed.episodes.count == 2)
        #expect(result.duplicates.isEmpty)
        #expect(result.queueEpisodeIDs == [100])
    }

    @Test func newEpisodeActionMatrixHonorsStateDateGlobalSettingsAndAutodownloadOverride() {
        for state in FeedSubscriptionState.allCases {
            for local in [false, true] {
                for feedAction in NewEpisodesAction.allCases {
                    for globalAction in NewEpisodesAction.allCases {
                        for autoDownload in FeedAutoDownload.allCases {
                            for globalAutoDownload in [false, true] {
                                var feed = stored([episode("old", date: 100)])
                                feed.subscriptionState = state
                                feed.newEpisodesAction = feedAction
                                feed.autoDownload = autoDownload
                                var settings = options()
                                settings.isLocalFeed = local
                                settings.globalNewEpisodesAction = globalAction
                                settings.globalAutoDownload = globalAutoDownload
                                let incoming = [episode("older", date: 99), episode("equal", date: 100),
                                                episode("newer", date: 101), episode("undated", date: nil)]
                                let result = merge(incoming, saved: feed, options: settings)
                                var action = feedAction == .global ? globalAction : feedAction
                                if !local && (autoDownload == .enabled || (autoDownload == .global && globalAutoDownload)) {
                                    action = .inbox
                                }
                                let newIDs = Set(result.feed.episodes.filter { $0.userState.playState == .new }.map(\.details.identifier))
                                let expected: Set<String?> = ["equal", "newer", "undated"]
                                #expect(newIDs == (state == .subscribed && action == .inbox ? expected : []))
                                let queued = result.queueEpisodeIDs.compactMap { id in
                                    result.feed.episodes.first { $0.id == id }?.details.identifier
                                }
                                #expect(queued == (state == .subscribed && action == .queue ? ["undated", "newer", "equal"] : []))
                                #expect(result.feed.episodes.first { $0.details.identifier == "older" }?.userState.playState == .unplayed)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func noPositivePriorDateUsesRefreshTimeForInboxCutoff() {
        for date: Double? in [nil, -1, 0] {
            let feed = stored([episode("old", date: date)])
            let result = merge([episode("older", date: now.timeIntervalSince1970 - 1),
                                episode("equal", date: now.timeIntervalSince1970)], saved: feed)
            #expect(result.feed.episodes.first { $0.details.identifier == "older" }?.userState.playState == .unplayed)
            #expect(result.feed.episodes.first { $0.details.identifier == "equal" }?.userState.playState == .new)
        }
    }

    @Test func removalIsExplicitAndUsesIdentifierAfterRepair() {
        let feed = stored([episode("old"), episode("absent")])
        var changed = episode("new")
        changed.media = feed.episodes[0].details.media
        var settings = options()
        settings.removeUnlistedItems = true
        let result = merge([changed], saved: feed, options: settings)
        #expect(result.feed.episodes.map(\.id) == [1])
        #expect(result.feed.episodes[0].details.identifier == "new")
        #expect(result.removedEpisodes == [feed.episodes[1]])
        #expect(merge([changed], saved: feed).feed.episodes.count == 2)
    }

    @Test func feedMetadataPreservesCustomTitleSourcePaginationAndAbsentFunding() {
        var metadata = parsed([])
        metadata.identifier = "id"
        metadata.funding = [FeedFunding(url: "donate", content: "Support")]
        metadata.isPaged = true
        metadata.nextPageURL = "page-5"
        var feed = LibraryFeed(id: 1, source: "original", metadata: metadata, episodes: [])
        feed.customTitle = "My title"
        feed.lastUpdateFailed = true
        feed.lastRefreshAttempt = now.addingTimeInterval(1)
        var incoming = ParsedFeed(format: .atom, title: "Changed", isPaged: true, nextPageURL: "page-2", redirectURL: "redirect")
        var settings = options()
        settings.validator = "new-validator"
        let result = FeedRefreshMerger.merge(incoming, into: feed, options: settings, allocateEpisodeID: { 1 }).feed
        #expect(result.source == "original" && result.title == "My title")
        #expect(result.metadata.title == "Changed" && result.metadata.identifier == "id")
        #expect(result.metadata.funding == metadata.funding)
        #expect(result.metadata.nextPageURL == "page-5")
        #expect(result.metadata.format == .atom && result.validator == "new-validator")
        #expect(!result.lastUpdateFailed)
        #expect(result.lastRefreshAttempt == feed.lastRefreshAttempt)
        incoming.funding = [FeedFunding(url: "new", content: "New")]
        #expect(FeedRefreshMerger.merge(incoming, into: feed, options: settings, allocateEpisodeID: { 1 })
            .feed.metadata.funding == incoming.funding)
    }

    @Test func anotherPageChangesNextLinkButDoesNotOverwriteFrontPageMetadataOrRefreshTime() {
        var feed = stored([])
        feed.lastRefreshAttempt = now.addingTimeInterval(-100)
        var settings = options()
        settings.pageNumber = 1
        settings.validator = "page-validator"
        let incoming = ParsedFeed(format: .atom, title: "Old archive title", nextPageURL: "page-3")
        let result = FeedRefreshMerger.merge(incoming, into: feed, options: settings, allocateEpisodeID: { 1 }).feed
        #expect(result.metadata.title == "Feed")
        #expect(result.metadata.nextPageURL == "page-3" && !result.metadata.isPaged)
        #expect(result.lastRefreshAttempt == feed.lastRefreshAttempt)
        #expect(result.pageNumber == 0)
        #expect(result.metadata.format == .atom && result.validator == "page-validator")
    }

    @Test func firstPaginationDiscoverySetsNextLink() {
        let feed = stored([])
        let incoming = ParsedFeed(format: .rss, isPaged: true, nextPageURL: "page-2")
        let result = FeedRefreshMerger.merge(incoming, into: feed, options: options(), allocateEpisodeID: { 1 }).feed
        #expect(result.metadata.isPaged && result.metadata.nextPageURL == "page-2")
    }

    @Test func feedIdentityPrefersPublisherIDThenSourceRatherThanTitle() {
        let first = stored([])
        var second = first
        second.source = "different source"
        #expect(first.identifyingValue != second.identifyingValue)
        let metadata = ParsedFeed(format: .rss, identifier: "publisher", title: "Title", link: "link")
        #expect(LibraryFeed(id: 0, source: "source", metadata: metadata, episodes: []).identifyingValue == "publisher")
        #expect(NewEpisodesAction(storedValue: 999) == .inbox)
        #expect(FeedAutoDownload(storedValue: 999) == .global)
    }
}
