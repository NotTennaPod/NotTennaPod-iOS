/// Value-owned editing session for the release's DrawerPreferencesDialog/ReorderDialog.
/// Discard this value to cancel. Confirmation applies only its owned fields to current preferences.
public struct NavigationCustomization: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case shown, hidden, destination(NavigationDestination)
        public var tag: String {
            switch self { case .shown: "shown"; case .hidden: "hidden"; case .destination(let value): value.rawValue }
        }
    }
    public private(set) var items: [Item]

    public init(preferences: NavigationPreferences) {
        func include(_ destination: NavigationDestination) -> Bool {
            !preferences.bottomNavigation || destination != .subscriptionList
        }
        items = [.shown]
            + preferences.configuration.visibleDrawerItems.filter(include).map(Item.destination)
            + [.hidden]
            + preferences.configuration.hiddenTags.compactMap(NavigationDestination.init(rawValue:)).filter(include).map(Item.destination)
    }

    @discardableResult public mutating func move(from: Int, to: Int) -> Bool {
        guard from > 0, to > 0, items.indices.contains(from), items.indices.contains(to) else { return false }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        return true
    }

    public func confirmed(updating preferences: NavigationPreferences) -> NavigationPreferences {
        var result = preferences
        let hiddenIndex = items.firstIndex(of: .hidden)!
        let hidden = items.dropFirst(hiddenIndex + 1).compactMap { item -> String? in
            if case .destination(let destination) = item { return destination.rawValue }; return nil
        }
        let order = items.compactMap { item -> String? in
            if case .destination(let destination) = item { return destination.rawValue }; return nil
        }
        result.configuration = NavigationConfiguration(hiddenTags: hidden, orderedTags: order)
        if hidden.contains(result.defaultPage),
           let replacement = NavigationDestination.allCases.first(where: { !hidden.contains($0.rawValue) }) {
            result.defaultPage = replacement.rawValue
        }
        return result
    }

    public static func reset(updating preferences: NavigationPreferences) -> NavigationPreferences {
        var result = preferences
        result.configuration = NavigationConfiguration()
        return result
    }
}
