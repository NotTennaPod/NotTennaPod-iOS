import Foundation
import Testing
@testable import NotTennaPodCore

/// Episode pager seeding, navigation and per-page menus against the independent Python oracle
/// (output `TestSupport/Data/episode-pager/expected/pager.json`).
struct EpisodePagerTests {
    static let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data/episode-pager").standardized
    private static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: evidence.appendingPathComponent(name))) as? [String: Any])
    }
    private static func ints(_ value: Any?) -> [Int64] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    private static func items(_ ids: [Int64]) -> [EpisodePagerItem] { ids.map { .init(feedID: 1, episodeID: $0) } }

    /// The rows Android's caller holds at tap time: 150-row pages for feed and episode lists,
    /// search LIMIT 300, Home 8/2/8/2, the whole queue and downloads. iOS callers pass the rows they display.
    private static func displayed(_ ids: [Int64], caller: String, pagesLoaded: Int?) -> [Int64] {
        switch caller {
        case "feed", "inbox", "all_episodes", "favorites", "history", "online_feed_preview":
            Array(ids.prefix(150 * (pagesLoaded ?? 1)))
        case "search": Array(ids.prefix(300))
        case "home_queue", "home_surprise": Array(ids.prefix(8))
        case "home_inbox", "home_downloads": Array(ids.prefix(2))
        default: ids
        }
    }

    @Test func seedsOpenOnTheTappedRowOfTheDisplayedList() throws {
        let fixture = try Self.json("pager-fixture.json"), expected = try Self.json("expected/pager.json")
        let lists = try #require(fixture["caller_lists"] as? [String: Any]), long = try #require(fixture["long_lists"] as? [String: Any])
        let cases = try #require(fixture["seed_cases"] as? [[String: Any]]), seeds = try #require(expected["seeds"] as? [[String: Any]])
        try #require(cases.count == 18 && seeds.count == cases.count)
        for (input, oracle) in zip(cases, seeds) {
            let caller = try #require(input["caller"] as? String), row = try #require(input["row"] as? Int)
            let source = Self.ints(input["list"] as? String == "long" ? long[caller] : lists[caller])
            let rows = Self.displayed(source, caller: caller, pagesLoaded: input["pages_loaded"] as? Int)
            let model = EpisodePagerModel(items: Self.items(rows), tapped: .init(feedID: 1, episodeID: source[row]))
            let label = "\(caller) row \(row) pages \(input["pages_loaded"] ?? "-")"
            #expect(model.count == oracle["pager_size"] as? Int, "\(label)")
            #expect(model.index == oracle["position"] as? Int, "\(label)")
            #expect(model.visible.episodeID == (oracle["tapped_id"] as? NSNumber)?.int64Value, "\(label)")
            #expect(model.items.last?.episodeID == (oracle["last_reachable_id"] as? NSNumber)?.int64Value, "\(label)")
            #expect(Array(model.items.prefix(3).map(\.episodeID)) == Self.ints(oracle["ids_head"]), "\(label)")
            #expect(Array(model.items.suffix(3).map(\.episodeID)) == Self.ints(oracle["ids_tail"]), "\(label)")
            #expect(source.count - model.count == oracle["unreachable_by_swiping"] as? Int, "\(label)")
        }
    }

    @Test func duplicateAbsentAndSingleEntrySeedingFollowTheSourceFormula() throws {
        let expected = try Self.json("expected/pager.json")
        for key in ["duplicate_ids_case", "absent_tapped_case"] {
            let value = try #require(expected[key] as? [String: Any])
            let input = try #require(value["input"] as? [String: Any]), result = try #require(value["result"] as? [String: Any])
            let model = EpisodePagerModel(items: Self.items(Self.ints(input["list"])),
                tapped: .init(feedID: 1, episodeID: try #require((input["tapped"] as? NSNumber)?.int64Value)))
            #expect(model.items.map(\.episodeID) == Self.ints(result["ids"]), "\(key)")
            #expect(model.index == result["position"] as? Int, "\(key)")
        }
        let single = try #require(expected["single_id_entry"] as? [String: Any])
        let model = EpisodePagerModel(single: .init(feedID: 1, episodeID: Self.ints(single["ids"])[0]))
        #expect(model.items.map(\.episodeID) == Self.ints(single["ids"]) && model.index == single["position"] as? Int)
    }

    @Test func navigationStepsBoundariesResidentPagesAndRightToLeftMatchTheOracle() throws {
        let fixture = try Self.json("pager-fixture.json"), expected = try Self.json("expected/pager.json")
        let lists = try #require(fixture["caller_lists"] as? [String: Any])
        let cases = try #require(fixture["navigation_cases"] as? [[String: Any]]), oracle = try #require(expected["navigation"] as? [[String: Any]])
        try #require(cases.count == 7 && oracle.count == cases.count)
        for (input, result) in zip(cases, oracle) {
            let name = try #require(input["name"] as? String), rtl = input["direction"] as? String == "rtl"
            let ids = Self.ints(lists[try #require(input["caller"] as? String)])
            var model = EpisodePagerModel(items: Self.items(ids), tapped: .init(feedID: 1, episodeID: ids[try #require(input["row"] as? Int)]))
            #expect(model.index == result["start_index"] as? Int, "\(name)")
            let steps = try #require(result["steps"] as? [[String: Any]])
            for (gesture, step) in zip(try #require(input["gestures"] as? [String]), steps) {
                let moved: Bool
                switch gesture {
                case "next": moved = model.step(.next)
                case "prev": moved = model.step(.previous)
                case "drag_left": moved = model.drag(.left, rightToLeft: rtl)
                default: moved = model.drag(.right, rightToLeft: rtl)
                }
                #expect(moved == step["moved"] as? Bool, "\(name) \(gesture)")
                #expect(model.index == step["index"] as? Int, "\(name) \(gesture)")
                #expect(model.visible.episodeID == (step["visible_id"] as? NSNumber)?.int64Value, "\(name) \(gesture)")
                #expect(model.residentIndices.map { model.items[$0].episodeID } == Self.ints(step["resident_ids"]), "\(name) \(gesture)")
            }
            #expect(model.visible.episodeID == (result["final_visible_id"] as? NSNumber)?.int64Value, "\(name)")
        }
    }

    @Test func rightToLeftMirrorsTheSlotsAndLeftToRightDoesNot() {
        let model = EpisodePagerModel(items: Self.items([10, 11, 12, 13]), tapped: .init(feedID: 1, episodeID: 11))
        #expect((0..<4).map { model.visualSlot(of: $0, rightToLeft: false) } == [0, 1, 2, 3])
        #expect((0..<4).map { model.visualSlot(of: $0, rightToLeft: true) } == [3, 2, 1, 0])
        #expect((0..<4).map { model.page(atVisualSlot: $0, rightToLeft: true) } == [3, 2, 1, 0])
        // Negative control: the LTR mapping moves the wrong way in RTL (oracle negative_controls).
        #expect(EpisodePagerModel.step(for: .right, rightToLeft: true) == .next)
        #expect(EpisodePagerModel.step(for: .right, rightToLeft: false) == .previous)
    }

    // MARK: Menus of each fixture episode (menu eligibility; the pager adds only which episode it belongs to)

    private static func library(_ fixture: [String: Any]) throws -> (feeds: [Int64: LibraryFeed], episodes: [Int64: (LibraryEpisode, Bool)]) {
        var feeds: [Int64: LibraryFeed] = [:]
        for value in try #require(fixture["feeds"] as? [[String: Any]]) {
            let id = try #require((value["id"] as? NSNumber)?.int64Value)
            var feed = LibraryFeed(id: id, source: value["local"] as? Bool == true ? "antennapod_local:content://tapes" : "https://feeds.example.test/\(id)",
                metadata: ParsedFeed(format: .rss, title: value["title"] as? String, link: value["link"] as? String), episodes: [])
            feed.subscriptionState = value["state"] as? Int == 1 ? .notSubscribed : value["state"] as? Int == 2 ? .archived : .subscribed
            feeds[id] = feed
        }
        var episodes: [Int64: (LibraryEpisode, Bool)] = [:]
        for value in try #require(fixture["episodes"] as? [[String: Any]]) {
            let id = try #require((value["id"] as? NSNumber)?.int64Value)
            let media = value["media_id"] as? NSNumber
            var episode = LibraryEpisode(id: id, details: ParsedEpisode(identifier: "\(id)", title: value["title"] as? String,
                link: value["link"] as? String, media: media.map { ParsedMedia(url: "https://media.example.test/\($0).mp3", size: 1) }))
            episode.userState.playState = switch value["read"] as? Int { case -1: .new; case 1: .played; default: .unplayed }
            episode.userState.positionMilliseconds = Int32(value["position"] as? Int ?? 0)
            episode.userState.isFavorite = value["favorite"] as? Bool == true
            episode.userState.isDownloaded = value["downloaded"] as? Bool == true
            let feedID = try #require((value["feed"] as? NSNumber)?.int64Value)
            feeds[feedID]?.episodes.append(episode)
            episodes[id] = (episode, value["queued"] as? Bool == true)
        }
        return (feeds, episodes)
    }

    private static let englishTitles: [EpisodeMenu.Action: String] = [
        .skip: "Skip episode", .removeFromInbox: "Remove from inbox", .markPlayed: "Mark as played", .markUnplayed: "Mark as unplayed",
        .addToQueue: "Add to queue", .removeFromQueue: "Remove from queue", .resetPosition: "Reset playback position",
        .openPodcast: "Open podcast", .addFavorite: "Add to favorites", .removeFavorite: "Remove from favorites", .share: "Share",
    ]

    @Test func everyFixtureEpisodeShowsTheOracleToolbarIconAndOverflow() throws {
        let fixture = try Self.json("pager-fixture.json"), expected = try Self.json("expected/pager.json")
        let (feeds, episodes) = try Self.library(fixture)
        let playing = (fixture["playing_media_id"] as? NSNumber)?.int64Value
        let menus = try #require(expected["menus"] as? [String: [String: [String]]])
        try #require(menus.count == 10)
        for (key, menu) in menus {
            let id = try #require(Int64(key)), (episode, queued) = try #require(episodes[id])
            let feed = try #require(feeds.values.first { $0.episodes.contains { $0.id == id } })
            let selected = playing.map { "https://media.example.test/\($0).mp3" } == episode.details.media?.url
            let overflow = EpisodeMenu.actions(episode: episode, feed: feed, queued: queued, isSelectedMedia: selected)
            #expect(overflow.map { Self.englishTitles[$0] ?? "?" } == menu["overflow"], "episode \(id)")
            let icon = EpisodeWebsite.toolbarDestination(episode: episode, feed: feed) != nil
            #expect((icon ? ["Visit website"] : []) == menu["toolbar_icons"], "episode \(id)")
        }
    }

    @Test func journeyMenusDifferBetweenPagesThreeAndFourAndFollowTheVisiblePage() throws {
        let fixture = try Self.json("pager-fixture.json"), expected = try Self.json("expected/pager.json")
        let (feeds, episodes) = try Self.library(fixture)
        let journey = try #require(expected["journey"] as? [String: Any])
        let inbox = Self.ints(journey["inbox_before"])
        var model = EpisodePagerModel(items: Self.items(inbox), tapped: .init(feedID: 1, episodeID: inbox[(journey["open_row"] as? Int ?? 1) - 1]))
        func menu(_ id: Int64) throws -> [String] {
            let (episode, queued) = try #require(episodes[id])
            let feed = try #require(feeds.values.first { $0.episodes.contains { $0.id == id } })
            return EpisodeMenu.actions(episode: episode, feed: feed, queued: queued, isSelectedMedia: false).map { Self.englishTitles[$0] ?? "?" }
        }
        #expect(model.visible.episodeID == 303)
        for step in try #require(journey["steps"] as? [[String: Any]]) {
            model.step(step["gesture"] as? String == "next" ? .next : .previous)
            #expect(model.visible.episodeID == (step["visible_id"] as? NSNumber)?.int64Value)
        }
        let action = try #require(journey["action"] as? [String: Any])
        #expect(model.visible.episodeID == (action["target_id"] as? NSNumber)?.int64Value)
        let before = try #require((journey["pager_after_action"] as? [String: Any])?["menu_before"] as? [String: [String]])
        #expect(try menu(model.visible.episodeID) == before["overflow"])
        // Negative control: the previous page's menu is visibly different, so a stale target would show.
        #expect(try menu(303) != before["overflow"])
    }
}
