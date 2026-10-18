import Foundation
import WebKit
import NotTennaPodCore

/// Which remote subresources show notes may load by themselves on the current network. Pictures, styles and fonts
/// (Small) follow "Cover images", as on Android; media and embedded frames (Heavy) follow "Streaming", an intentional
/// difference. Scripts never load. Unknown and offline networks count as restricted; until the network is known
/// nothing remote loads. Links a person taps are not governed here.
///
/// Allowed classes use WebKit's cache normally (normal WebKit cache reuse; expired offline entries are not
/// guaranteed). A denied class is not shown even when cached: a content rule's block also refuses cached resources.
@MainActor final class ShownotesNetworkPolicy {
    typealias Classes = ShownotesFormatter.SubresourceClasses

    /// Every class, with no rules (tests, and screens built without the app).
    static let unrestricted = ShownotesNetworkPolicy()

    let rules: ShownotesContentRules?
    private let network: DownloadNetworkMonitor?
    private let preferences: MobileNetworkPreferenceStore?
    private(set) var allowed: Classes
    private let views = NSHashTable<ShownotesWebView>.weakObjects()
    private var changes: Task<Void, Never>?

    private init() {
        rules = nil; network = nil; preferences = nil; allowed = .all
    }

    init(network: DownloadNetworkMonitor = .shared, preferences: MobileNetworkPreferenceStore, rules: ShownotesContentRules = .shared) {
        self.rules = rules; self.network = network; self.preferences = preferences
        allowed = Self.allowed(network.current, preferences: preferences)
        rules.prepare()
        let stream = network.changes()
        changes = Task { [weak self] in
            for await _ in stream { self?.refresh() }
        }
    }

    isolated deinit { changes?.cancel() }

    /// The Mobile updates options changed (`MobileNetworkPreferenceStore.onChange`).
    func preferencesChanged() { refresh() }

    func register(_ view: ShownotesWebView) { views.add(view) }

    private func refresh() {
        guard let network, let preferences else { return }
        let now = Self.allowed(network.current, preferences: preferences)
        guard now != allowed else { return }
        allowed = now
        for view in views.allObjects { view.networkPolicyChanged() }
    }

    static func allowed(_ state: DownloadNetworkState?, preferences: MobileNetworkPreferenceStore) -> Classes {
        guard let state else { return [] }
        let restricted = !state.connected || state.restricted
        var allowed: Classes = []
        if !restricted || preferences.allows(.images) { allowed.insert(.small) }
        if !restricted || preferences.allows(.streaming) { allowed.insert(.heavy) }
        return allowed
    }
}

/// WebKit content rules for show notes, compiled once per process before any notes load. Each list blocks every
/// remote load of its resource types; `data:`, `blob:` and `about:` (the notes' own font, inline content) stay.
@MainActor final class ShownotesContentRules {
    struct Lists {
        let never, small, heavy: WKContentRuleList
        /// The lists that keep everything but `allowed` from loading.
        func blocking(_ allowed: ShownotesFormatter.SubresourceClasses) -> [WKContentRuleList] {
            [never] + (allowed.contains(.small) ? [] : [small]) + (allowed.contains(.heavy) ? [] : [heavy])
        }
    }

    static let shared = ShownotesContentRules(store: .default())

    private static let local = #"{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},"#
        + #"{"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},"#
        + #"{"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}"#
    static let definitions: [(identifier: String, json: String)] = [
        ("AntennaPodShownotesNever", #"[{"trigger":{"url-filter":".*","resource-type":["script"]},"action":{"type":"block"}},"# + local + "]"),
        ("AntennaPodShownotesSmall", #"[{"trigger":{"url-filter":".*","resource-type":["image","svg-document","style-sheet","font","ping","fetch","websocket","other"]},"action":{"type":"block"}},"# + local + "]"),
        ("AntennaPodShownotesHeavy", #"[{"trigger":{"url-filter":".*","resource-type":["media"]},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":".*","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}},"# + local + "]")
    ]

    private let store: WKContentRuleListStore
    private let definitions: [(identifier: String, json: String)]
    private var compilation: Task<Lists?, Never>?
    /// The compiled lists, once compilation has ended; nil before then and when it failed.
    private(set) var lists: Lists?
    private(set) var isResolved = false

    init(store: WKContentRuleListStore, definitions: [(identifier: String, json: String)] = ShownotesContentRules.definitions) {
        self.store = store; self.definitions = definitions
    }

    func prepare() {
        guard compilation == nil else { return }
        let store = store, definitions = definitions
        compilation = Task { [weak self] in
            var compiled: [WKContentRuleList] = []
            for definition in definitions {
                guard let list = try? await store.compileContentRuleList(forIdentifier: definition.identifier,
                                                                         encodedContentRuleList: definition.json) else { break }
                compiled.append(list)
            }
            let lists = compiled.count == 3 ? Lists(never: compiled[0], small: compiled[1], heavy: compiled[2]) : nil
            self?.lists = lists; self?.isResolved = true
            return lists
        }
    }

    /// The compiled lists; nil when compilation failed (the notes then use a strict Content-Security-Policy).
    func resolved() async -> Lists? {
        prepare()
        return await compilation?.value
    }
}
