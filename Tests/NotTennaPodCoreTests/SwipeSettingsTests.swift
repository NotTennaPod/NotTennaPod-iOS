import Foundation
import Testing
@testable import NotTennaPodCore

/// Settings → Swipe actions for every list, Queue and History swipes. Every expectation comes from the
/// independent oracle (cross-checked against the unchanged Java files):
/// `TestSupport/Data/swipe-settings/expected/swipe-settings.json` and its input `swipe-cases.json`.
/// English texts are read from the app's own string tables, so the checks see what a person reads.
@MainActor struct SwipeSettingsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("TestSupport/Data/swipe-settings")

    private func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent(name))) as? [String: Any])
    }
    private func expected() throws -> [String: Any] { try json("expected/swipe-settings.json") }
    private func cases() throws -> [String: Any] { try json("swipe-cases.json") }

    /// `Localizable.strings` (key → English text).
    private func strings() throws -> [String: String] {
        let text = try String(contentsOf: Self.root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        var result: [String: String] = [:]
        let pattern = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$"#, options: .anchorsMatchLines)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let key = String(text[Range(match.range(at: 1), in: text)!])
            let value = String(text[Range(match.range(at: 2), in: text)!])
                .replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
            result[key] = value
        }
        return result
    }
    /// The singular form of a `Localizable.stringsdict` plural, formatted with 1.
    private func one(_ key: String) throws -> String {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("App/Resources/en.lproj/Localizable.stringsdict"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let entry = try #require(plist[key] as? [String: Any])
        let variable = try #require(entry.first { $0.key != "NSStringLocalizedFormatKey" }?.value as? [String: Any])
        let format = try #require(variable["one"] as? String)
        return String(format: format, 1)
    }
    private func ints(_ value: Any?) -> [Int] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    private func screen(tag: String) -> SwipeScreen? { SwipeScreen(rawValue: tag) }
    private static let tagsByName = ["queue": "QueueFragment", "inbox": "NewEpisodesFragment", "episodes": "EpisodesFragment",
        "downloads": "DownloadsFragment", "history": "PlaybackHistoryFragment", "favorites": "FavoritesFragment", "feed": "ItemlistFragment"]

    // MARK: Settings rows, action sets, defaults

    @Test func settingsScreenHasTheSevenSourceRowsInOrderEachRoutedToItsDialog() throws {
        let settings = try #require(try expected()["settings"] as? [String: Any]), text = try strings()
        let entry = try #require(settings["entry_row"] as? [String: String])
        #expect(entry["key"] == "prefSwipe")
        #expect(text["swipeactions_label"] == entry["title"] && text["swipeactions_summary"] == entry["summary"])
        #expect(text["swipeactions_label"] == settings["screen_title"] as? String)
        let rows = try #require(settings["rows"] as? [[String: Any]])
        #expect(rows.map { $0["position"] as? Int } == Array(1...7))
        #expect(SwipeActionsSettingsRow.allCases.count == rows.count)
        for (row, oracle) in zip(SwipeActionsSettingsRow.allCases, rows) {
            let title = try #require(text[row.titleKey])
            #expect(row.key == oracle["key"] as? String)
            #expect(title == oracle["title"] as? String)
            #expect(row.tag == oracle["tag"] as? String)
            // Dialog title: "Swipe actions" + " - " + the screen label (`SwipeActionsDialog:86–112`).
            #expect(text["swipeactions_label"]! + " - " + title == oracle["dialog_title"] as? String)
            if let screen = row.screen { #expect(text[screen.titleKey] == title) }
        }
        #expect(SwipeActionsSettingsRow.downloads.screen == nil)
    }

    @Test func everyScreenOffersTheSourcePickerInGridOrderWithTheSourceDefaults() throws {
        let screens = try #require(try expected()["screens"] as? [[String: Any]]), text = try strings()
        #expect(screens.count == 7)
        for oracle in screens {
            let tag = try #require(oracle["tag"] as? String)
            let picker = try #require(oracle["picker"] as? [[String: Any]])
            let defaults = try #require(oracle["dialog_defaults"] as? [String: String])
            if tag == "DownloadsFragment" {
                // Downloads keeps its own model; its set and defaults still follow the source.
                #expect(DownloadsSwipeAction.allCases.map(\.rawValue) == picker.map { $0["id"] as? String })
                for (action, item) in zip(DownloadsSwipeAction.allCases, picker) {
                    #expect(text[action.titleKey] == item["title"] as? String && action.icon == item["icon"] as? String)
                }
                let value = DownloadsSwipePreferences()
                #expect(value.right.rawValue == defaults["right"] && value.left.rawValue == defaults["left"] && value.enabled)
                continue
            }
            let screen = try #require(screen(tag: tag), "screen \(tag)")
            #expect(screen.actions.map(\.rawValue) == picker.map { $0["id"] as? String }, "\(tag) picker order")
            for (index, (action, item)) in zip(screen.actions, picker).enumerated() {
                #expect(text[action.titleKey] == item["title"] as? String, "\(tag) \(action)")
                #expect(action.icon == item["icon"] as? String && action.colorAttribute == item["color"] as? String)
                // Two-column grid filled row by row.
                #expect(index / 2 == item["grid_row"] as? Int && index % 2 == item["grid_column"] as? Int)
            }
            #expect(screen.defaultConfiguration == .init(left: SwipeAction(rawValue: defaults["left"]!)!,
                                                         right: SwipeAction(rawValue: defaults["right"]!)!), "\(tag) defaults")
            if let filter = oracle["swipe_filter"] as? [String], let fixed = screen.fixedSwipeFilter {
                #expect(fixed.values == filter, "\(tag) swipe filter")
            }
        }
        // Queue swipes use the `queued` filter; History passes an unfiltered one.
        #expect(SwipeScreen.queue.fixedSwipeFilter?.values == ["queued"])
        #expect(SwipeScreen.history.fixedSwipeFilter?.values == [])
    }

    // MARK: Action outcomes (698 oracle rows)

    private func item(_ raw: [String: Any]) -> EpisodeListItem {
        let hasMedia = raw["has_media"] as? Bool ?? false
        var episode = LibraryEpisode(id: Int64(raw["id"] as! Int), details: .init(title: "Oracle \(raw["id"]!)",
            media: hasMedia ? .init(url: "https://example.test/\(raw["id"]!).mp3", size: 100) : nil))
        episode.userState.playState = switch raw["state"] as? String { case "NEW": .new; case "PLAYED": .played; default: .unplayed }
        episode.userState.isFavorite = raw["favorite"] as? Bool ?? false
        episode.userState.isDownloaded = raw["downloaded"] as? Bool ?? false
        if let history = raw["history_ms"] as? Int64 { episode.userState.lastPlayedHistoryMilliseconds = history }
        return .init(episode: episode, local: raw["local_feed"] as? Bool ?? false, queued: raw["queued"] as? Bool ?? false)
    }

    /// Translates one recorded Android outcome into the iOS recipient, independently of the Swift decision code.
    private func recipient(action: String, effects: [String], message: String?, item: EpisodeListItem, text: [String: String])
        -> (SwipeDecision.Recipient, offersUndo: Bool)? {
        let names = effects.map { String($0.prefix { $0 != "(" }) }
        switch names {
        case []:
            if message == nil { return (.none, false) }
            if message == text["no_media_label"] { return (.notice("no_media_label"), false) }
            if message == text["already_downloaded"] { return (.notice("already_downloaded"), false) }
            return nil
        case ["downloadActionButton"]: return (.download, false)
        case ["addQueueItem"]: return (.list(.addQueue), false)
        case ["removeQueueItem"]: return (.list(.removeQueue), message != nil)
        case ["toggleFavoriteItem"]: return (.list(item.episode.userState.isFavorite ? .removeFavorite : .addFavorite), false)
        case ["localDeleteWarning", "deleteFeedMediaOfItem"]: return (.list(.delete), false)
        case ["deleteFromPlaybackHistory"]: return (.removeHistory, message != nil)
        case ["markReadWithUndo"]:
            let snackbar = effects[0].contains("snackbar=true")
            if action == "REMOVE_FROM_INBOX" { return (.markWithUndo(.removeInbox), snackbar) }
            return (.markWithUndo(effects[0].contains("state=PLAYED") ? .markPlayed : .markUnplayed), snackbar)
        default: return nil
        }
    }

    @Test func everyListActionOutcomeMatchesTheOracle() throws {
        let oracle = try expected(), input = try cases(), text = try strings()
        let items = Dictionary(uniqueKeysWithValues: try #require(input["items"] as? [[String: Any]]).map { ($0["id"] as! Int, item($0)) })
        let outcomes = try #require(oracle["outcomes"] as? [[String: Any]])
        let removedFromQueue = try one("removed_from_queue_message")
        var checked = 0
        for outcome in outcomes {
            let name = try #require(outcome["screen"] as? String)
            // Downloads keeps its own model and tests (DownloadsSwipeTests).
            guard name != "downloads" else { continue }
            let tag = try #require(Self.tagsByName[name]), screen = try #require(screen(tag: tag))
            let raw = try #require(outcome["action"] as? String), itemID = try #require(outcome["item"] as? Int)
            let action = try #require(SwipeAction(rawValue: raw))
            #expect(screen.actions.contains(action))
            let current = try #require(items[itemID])
            let filter = FeedEpisodeFilter(values: outcome["filter"] as? [String] ?? [])
            let message = (outcome["message"] as? [String: Any])?["text"] as? String
            let undoLabel = (outcome["message"] as? [String: Any])?["action"] as? String
            let (want, offersUndo) = try #require(recipient(action: action.rawValue, effects: outcome["effects"] as? [String] ?? [],
                                                            message: message, item: current, text: text), "\(outcome)")
            let decision = action.decision(item: current, filter: filter)
            let context = "\(name) \(filter.values) \(action.rawValue) item \(current.episode.id)"
            #expect(decision.removesRow == outcome["will_remove"] as? Bool, "\(context): row motion")
            #expect(decision.recipient == want, "\(context): recipient")
            #expect((decision.undo != nil) == offersUndo, "\(context): Undo offer")
            if undoLabel != nil { #expect(undoLabel == text["undo"]) }
            switch decision.undo {
            case .queuePosition: #expect(message == removedFromQueue)
            case .historyDate: #expect(message == text["removed_history_label"])
            default: break
            }
            checked += 1
        }
        #expect(checked == outcomes.count - outcomes.filter { $0["screen"] as? String == "downloads" }.count)
        #expect(checked > 600)
        // Queue and History: only Remove from queue / Remove from history slide out and offer Undo.
        for (screen, remover) in [(SwipeScreen.queue, SwipeAction.removeQueue), (.history, .removeHistory)] {
            for action in screen.actions {
                for current in items.values where current.episode.details.media != nil {
                    let decision = action.decision(item: current, filter: screen.fixedSwipeFilter!)
                    #expect((decision.undo != nil) == (action == remover), "\(screen) \(action)")
                    #expect(decision.removesRow == (action == remover), "\(screen) \(action)")
                }
            }
        }
    }

    // MARK: Dialog sessions and gestures

    private func picked(_ step: String, screen: SwipeScreen) -> (EpisodeSwipeDirection, SwipeAction)? {
        guard step.count == 2, let index = Int(step.dropFirst()), ["L", "R"].contains(step.first) else { return nil }
        return (step.first == "L" ? .left : .right, screen.actions[index])
    }
    private func configuration(_ stored: String?, enabled: Bool?, screen: SwipeScreen) -> SwipeConfiguration? {
        // Android stores "<RIGHT>,<LEFT>" and the enabled flag separately; iOS stores both together on Confirm.
        guard let stored else { return enabled == false ? .init(enabled: false, left: screen.defaultConfiguration.left,
                                                                right: screen.defaultConfiguration.right) : nil }
        let parts = stored.split(separator: ",").map(String.init)
        return .init(enabled: enabled ?? true, left: SwipeAction(rawValue: parts[1])!, right: SwipeAction(rawValue: parts[0])!)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M26Swipe-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func dialogSessionsShowDefaultsEditOnlyTheDraftAndStoreOnlyOnConfirm() throws {
        let sessions = try #require(try cases()["dialog_cases"] as? [[String: Any]])
        let results = Dictionary(uniqueKeysWithValues: try #require(try expected()["dialogs"] as? [[String: Any]]).map { ($0["name"] as! String, $0) })
        let text = try strings()
        var checked = 0
        for session in sessions {
            let name = try #require(session["name"] as? String), tag = try #require(session["tag"] as? String)
            let result = try #require(results[name])
            // Downloads: its own model. FOO,BAR and an action outside the picker cannot be stored on iOS (the store
            // validates every Confirm), so Android's crash on a malformed pair has no iOS equivalent.
            guard let screen = screen(tag: tag), result["stored_after"] != nil,
                  !(name == "queue_stored_action_outside_picker") else { continue }
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("swipe.json"), store = try SwipePreferenceStore(file: file)
            if let stored = configuration(session["stored_actions"] as? String, enabled: session["stored_enabled"] as? Bool, screen: screen) {
                try store.confirm(.init(screen: screen, configuration: stored))
            }
            let before = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            #expect(text["swipeactions_label"]! + " - " + text[screen.titleKey]! == result["title"] as? String)
            var draft = store.draft(for: screen)
            let initial = try #require(result["initial"] as? [String: Any]), rows = try #require(initial["rows"] as? [String: [String: Any]])
            #expect(draft.configuration.enabled == initial["switch"] as? Bool, "\(name) switch")
            #expect(text[draft.configuration.left.titleKey] == rows["L"]?["action"] as? String, "\(name) left")
            #expect(text[draft.configuration.right.titleKey] == rows["R"]?["action"] as? String, "\(name) right")
            let steps = try #require(result["steps"] as? [[String: Any]])
            var stepIndex = 0
            for step in session["script"] as? [String] ?? [] {
                switch step {
                case "OK": try store.confirm(draft)
                case "CANCEL": break
                case "S0", "S1": draft.configuration.enabled = step == "S1"
                case "L", "R":
                    // Opening a picker lists the screen's actions in order; closing it changes nothing.
                    let items = try #require(steps[stepIndex]["items"] as? [[String: Any]])
                    #expect(items.map { $0["title"] as? String } == screen.actions.map { text[$0.titleKey] }, "\(name) picker")
                default:
                    let (direction, action) = try #require(picked(step, screen: screen))
                    if direction == .left { draft.configuration.left = action } else { draft.configuration.right = action }
                }
                if !["OK", "CANCEL"].contains(step) {
                    let recorded = steps[stepIndex]; stepIndex += 1
                    if let rows = recorded["rows"] as? [String: [String: Any]] {
                        #expect(text[draft.configuration.left.titleKey] == rows["L"]?["action"] as? String, "\(name) \(step)")
                        #expect(text[draft.configuration.right.titleKey] == rows["R"]?["action"] as? String, "\(name) \(step)")
                        // Switch off fades both rows to 40 % but keeps them editable.
                        #expect((rows["L"]?["alpha"] as? Double == 1.0) == draft.configuration.enabled)
                    }
                }
                if step != "OK" {
                    let now = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
                    #expect(now == before, "\(name): nothing is stored before Confirm")
                }
            }
            let storedAfter = try #require(result["stored_after"] as? [String: Any])
            let reopened = try SwipePreferenceStore(file: file).value.configuration(for: screen)
            if let actions = storedAfter["actions"] as? String {
                let want = try #require(configuration(actions, enabled: storedAfter["enabled"] as? Bool, screen: screen))
                #expect(reopened == want, "\(name) stored")
            } else {
                #expect(reopened == nil, "\(name): Cancel leaves the screen unconfigured")
            }
            checked += 1
        }
        #expect(checked == 19)
    }

    @Test func firstUseDisabledAndConfiguredSwipesFollowTheOracle() throws {
        let input = try cases(), text = try strings()
        let items = Dictionary(uniqueKeysWithValues: try #require(input["items"] as? [[String: Any]]).map { ($0["id"] as! Int, item($0)) })
        let results = Dictionary(uniqueKeysWithValues: try #require(try expected()["swipes"] as? [[String: Any]]).map { ($0["name"] as! String, $0) })
        var checked = 0
        for swipe in try #require(input["swipe_cases"] as? [[String: Any]]) {
            let name = try #require(swipe["name"] as? String), tag = try #require(swipe["tag"] as? String)
            // Downloads: its own model. A malformed stored pair cannot exist on iOS (validated storage).
            guard let screen = screen(tag: tag), name != "inbox_malformed_is_first_use" else { continue }
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
            if let stored = configuration(swipe["stored_actions"] as? String, enabled: swipe["stored_enabled"] as? Bool, screen: screen) {
                try store.confirm(.init(screen: screen, configuration: stored))
            }
            let direction: EpisodeSwipeDirection = swipe["dir"] as? String == "LEFT" ? .left : .right
            let result = try #require(results[name]), current = try #require(items[swipe["item"] as! Int])
            let gesture = store.gesture(on: screen, direction: direction)
            if (result["swipe_dirs"] as? [String])?.isEmpty == true {
                #expect(gesture == .disabled, "\(name)")
            } else if let outcome = result["on_swiped"] as? [String: Any], let dialog = outcome["dialog"] as? String {
                #expect(gesture == .configure, "\(name)")
                #expect(text["swipeactions_label"]! + " - " + text[screen.titleKey]! == dialog)
            } else {
                let outcome = try #require(result["on_swiped"] as? [String: Any])
                let action = try #require(SwipeAction(rawValue: outcome["action"] as! String))
                #expect(gesture == .action(action), "\(name)")
                let message = (outcome["message"] as? [String: Any])?["text"] as? String
                let want = try #require(recipient(action: action.rawValue, effects: outcome["effects"] as? [String] ?? [],
                                                  message: message, item: current, text: text))
                let decision = action.decision(item: current, filter: screen.fixedSwipeFilter!)
                #expect(decision.recipient == want.0 && (decision.undo != nil) == want.offersUndo, "\(name)")
            }
            checked += 1
        }
        #expect(checked == 10)
    }

    // MARK: Queue remove/Undo and History remove/Undo in the database

    private func library(_ count: Int, _ body: (FeedLibraryStore, LibrarySQLite, [Int64]) async throws -> Void) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: url)
        let db = try LibrarySQLite(url: url)
        do {
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "M26", episodes: (1...count).map {
                .init(identifier: "m26-\($0)", title: "Episode \($0)", publicationDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + $0 * 60)),
                      media: .init(url: "https://example.test/\($0).mp3", size: 42, durationMilliseconds: 1_800_000))
            }), source: "https://example.test/m26", responseURL: URL(string: "https://example.test/m26")!, validator: nil, permanentRedirectURL: nil))
            let ids = feed.episodes.map(\.id).sorted()
            try await body(store, db, ids)
            try db.close(); try await store.close()
        } catch { try? db.close(); try? await store.close(); throw error }
    }
    /// Independent read of the saved queue: the `queue` table, not the store API.
    private func savedQueue(_ db: LibrarySQLite) throws -> [Int64] {
        try db.rows("SELECT episode_id FROM queue ORDER BY position").map { try #require($0[0].integer) }
    }
    /// Independent read of one saved episode record.
    private func savedState(_ db: LibrarySQLite, _ id: Int64) throws -> [String: Any] {
        let row = try #require(try db.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first)
        guard case .blob(let data) = row[0] else { throw CocoaError(.fileReadCorruptFile) }
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(record["userState"] as? [String: Any])
    }

    @Test func queueRemoveAndUndoSequencesMatchTheOracleIncludingTheClamp() async throws {
        let sequences = try #require(try expected()["queue_sequences"] as? [[String: Any]])
        #expect(sequences.count == 10)
        for sequence in sequences {
            let name = try #require(sequence["name"] as? String)
            try await library(6) { store, db, ids in
                // Oracle ids 21…26 map to this library's episodes in order.
                @Sendable func map(_ oracle: Int) -> Int64 { ids[oracle - 21] }
                @Sendable func back(_ id: Int64) -> Int { ids.firstIndex(of: id)! + 21 }
                _ = try await store.enqueue(ints(sequence["base"]).map(map))
                let before = try await store.episode(id: map(sequence["swiped"] as! Int))
                let removal = try await store.removeFromQueueWithUndo(map(sequence["swiped"] as! Int))
                let receipt = try #require(removal.receipt)
                #expect(receipt.index == sequence["position"] as? Int, "\(name) index")
                #expect(try savedQueue(db).map(back) == ints(sequence["after_remove"]), "\(name) after remove")
                for step in sequence["between"] as? [[Any]] ?? [] {
                    switch step[0] as? String {
                    case "remove": _ = try await store.removeFromQueue([map(step[1] as! Int)])
                    case "append": _ = try await store.enqueue([map(step[1] as! Int)])
                    case "clear": _ = try await store.clearQueue()
                    default: Issue.record("unknown step \(step)")
                    }
                }
                #expect(try savedQueue(db).map(back) == ints(sequence["before_undo"]), "\(name) before Undo")
                if sequence["undo"] as? Bool == true { _ = try await store.undoQueueRemoval(receipt) }
                else { await store.releaseQueueRemoval(receipt) }
                // iOS never loses an Undo: an index beyond the shrunk queue restores at the end.
                #expect(try savedQueue(db).map(back) == ints(sequence["ios"]), "\(name) final")
                // Only the queue changes: favorites, position, played state and downloads are untouched.
                let after = try await store.episode(id: map(sequence["swiped"] as! Int))
                #expect(after?.userState.isFavorite == before?.userState.isFavorite)
                #expect(after?.userState.positionMilliseconds == before?.userState.positionMilliseconds)
                #expect(after?.userState.isDownloaded == before?.userState.isDownloaded)
                #expect(try await store.synchronizationQueue().isEmpty, "\(name): no sync action")
            }
        }
    }

    @Test func historyRemoveAndUndoChangeOnlyTheHistoryDateAndRestoreTheOrder() async throws {
        let input = try cases(), oracle = try expected()
        let rows = try #require(input["history_rows"] as? [[String: Any]])
        let durations = try #require(input["played_duration_example"] as? [String: Any])
        let stored = Int64(try #require(durations["db_ms"] as? Int))
        #expect(stored == 900_000)
        let sequences = try #require(oracle["history_sequences"] as? [[String: Any]])
        #expect(sequences.count == 5)
        for sequence in sequences {
            let name = try #require(sequence["name"] as? String)
            try await library(6) { store, db, ids in
                // Oracle items 31…36 map to this library's episodes in id order, so the tie 32/33 keeps
                // the same order (equal dates sort by ascending id).
                @Sendable func map(_ oracle: Int) -> Int64 { ids[oracle - 31] }
                @Sendable func back(_ id: Int64) -> Int { ids.firstIndex(of: id)! + 31 }
                for row in rows {
                    let date = Int64(row["history_ms"] as! Int)
                    try await store.updateEpisode(id: map(row["item_id"] as! Int)) {
                        $0.userState.lastPlayedHistoryMilliseconds = date > 0 ? date : nil
                        $0.userState.lastPlayedTimeMilliseconds = max(date, 1)
                        $0.userState.playedDurationMilliseconds = stored
                        $0.userState.positionMilliseconds = 120_000; $0.userState.playState = .unplayed
                    }
                }
                func history() async throws -> [Int] { EpisodeListQueries.history(try await store.snapshot().feeds).map { back($0.episode.id) } }
                func started() async throws -> Int64 {
                    try LibraryStatistics(feeds: try await store.snapshot().feeds, includeMarkedAsPlayed: false, now: Date()).feeds.map(\.episodesStarted).reduce(0, +)
                }
                #expect(try await history() == ints(oracle["history_initial_order"]))
                let startedBefore = try await started(), effects = try await store.pendingEffects()
                let swiped = map(sequence["swiped"] as! Int)
                let before = try savedState(db, swiped)
                let receipt = try #require(try await store.removeFromPlaybackHistoryWithUndo(swiped))
                #expect(receipt.originalMilliseconds == Int64(sequence["original_ms"] as! Int))
                #expect(try await history() == ints(sequence["after_remove"]), "\(name) after remove")
                #expect(try await started() == startedBefore - 1, "\(name): Episodes started drops by one")
                let removed = try savedState(db, swiped)
                #expect(removed["lastPlayedHistoryMilliseconds"] == nil, "\(name): history date cleared")
                // Everything else is kept, including the stored played duration (Android's stale overwrite not copied).
                for key in ["playedDurationMilliseconds", "positionMilliseconds", "playState", "lastPlayedTimeMilliseconds", "isFavorite"] {
                    #expect((removed[key] as? NSObject) == (before[key] as? NSObject), "\(name) \(key)")
                }
                let script = try #require((input["history_sequences"] as? [[String: Any]])?.first { $0["name"] as? String == name })
                if let meanwhile = script["played_meanwhile_ms"] as? Int {
                    // Playing again sets a new history date (`PlayableUtils.saveCurrentPosition`).
                    try await store.updateEpisode(id: swiped) { $0.userState.lastPlayedHistoryMilliseconds = Int64(meanwhile) }
                }
                #expect(try await history() == ints(sequence["before_undo"]), "\(name) before Undo")
                if sequence["after_undo"] != nil {
                    #expect(try await store.undoHistoryRemoval(receipt).status == .restored)
                    #expect(try await history() == ints(sequence["after_undo"]), "\(name): Undo restores the old place")
                    #expect(try await started() == startedBefore)
                    let restored = try savedState(db, swiped)
                    #expect((restored["lastPlayedHistoryMilliseconds"] as? NSNumber)?.int64Value == receipt.originalMilliseconds)
                    #expect((restored["playedDurationMilliseconds"] as? NSNumber)?.int64Value == stored)
                    #expect(try await store.undoHistoryRemoval(receipt).status == .unavailable, "\(name): one Undo only")
                } else {
                    await store.releaseHistoryRemoval(receipt)
                    #expect(try await store.undoHistoryRemoval(receipt).status == .unavailable)
                    #expect(try await history() == ints(sequence["final"]), "\(name) final")
                }
                #expect(try await store.synchronizationQueue().isEmpty, "\(name): no sync action")
                #expect(try await store.pendingEffects() == effects, "\(name): no new pending effects")
            }
        }
    }

    @Test func historyRemovalOfAnEpisodeWithoutHistoryOffersNothing() async throws {
        try await library(2) { store, db, ids in
            let receipt = try await store.removeFromPlaybackHistoryWithUndo(ids[0])
            let state = try savedState(db, ids[0])
            #expect(receipt == nil)
            #expect(state["lastPlayedHistoryMilliseconds"] == nil)
        }
    }

    @Test func queueUndoIsOfferedOnlyByTheLiveStoreAndSurvivesNoRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "M26", episodes: (1...3).map {
            .init(identifier: "r-\($0)", title: "R \($0)", media: .init(url: "https://example.test/r\($0).mp3", size: 42))
        }), source: "https://example.test/relaunch", responseURL: URL(string: "https://example.test/relaunch")!, validator: nil, permanentRedirectURL: nil))
        let ids = feed.episodes.map(\.id).sorted()
        _ = try await store.enqueue(ids)
        let receipt = try #require(try await store.removeFromQueueWithUndo(ids[1]).receipt)
        try await store.close()
        // The removal is committed at once: a relaunch without Undo keeps it removed, and the old offer is gone.
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.queue().map(\.id) == [ids[0], ids[2]])
        #expect(try await reopened.undoQueueRemoval(receipt).status == .unavailable)
        #expect(try await reopened.queue().map(\.id) == [ids[0], ids[2]])
        try await reopened.close()
    }
}
