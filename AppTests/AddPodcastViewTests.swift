import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: Add-podcast composition and order (LTR/RTL, phone/tablet widths), suggestion
/// states, Discover states and the chooser. Expectations from Android 3.12.1.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AddPodcastViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    private func makeController(width: CGFloat, rtl: Bool = false,
                                read: @escaping @Sendable (String, Int) async throws -> [PodcastSearchResult]) throws -> (LibraryViewController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M25View-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = navigation.value; value.defaultPage = NavigationDestination.addPodcast.rawValue
        try navigation.update(value)
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil)
        controller.discoveryPreferences = try DiscoveryPreferenceStore(file: root.appendingPathComponent("discovery.json"))
        controller.addPodcastScreen.readTopList = read
        if rtl { controller.traitOverrides.layoutDirection = .rightToLeft }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return (controller, root)
    }

    @Test(arguments: [(402.0, false), (402.0, true), (834.0, false)])
    func addScreenShowsSearchSuggestionsAndSixRowsInAndroidOrder(_ width: Double, _ rtl: Bool) async throws {
        let (controller, root) = try makeController(width: width, rtl: rtl) { _, limit in
            #expect(limit == 12)
            return (1...12).map { PodcastSearchResult(title: "Show \($0)", imageURL: "", feedURL: "https://itunes.apple.com/lookup?id=\($0)", author: "A") }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await wait { element("quickDiscoveryItem-11", in: controller.view, as: UIControl.self) != nil }
        controller.view.layoutIfNeeded()
        let view = controller.view!
        let bar = try #require(element("addPodcastSearchBar", in: view))
        let field = try #require(element("addPodcastSearchField", in: view, as: UITextField.self))
        #expect(field.placeholder == "Search podcast…")
        #expect(element("addPodcastSearchButton", in: view, as: UIButton.self)?.accessibilityLabel == "Search podcast…")
        let grid = try #require(element("quickDiscovery", in: view))
        let ids = ["addRSS", "addLocalFolder", "addSearchApple", "addSearchFyyd", "addSearchPodcastIndex", "addOPML"]
        let titles = ["Add podcast by RSS address", "Add local folder", "Search Apple Podcasts", "Search fyyd",
                      "Search Podcast Index", "Import podcast list (OPML)"]
        let rows = try ids.map { try #require(element($0, in: view, as: UIControl.self)) }
        #expect(rows.map(\.accessibilityLabel) == titles)
        // Top to bottom: search, suggestions, then the six rows; nothing overlaps.
        let stack = [bar, grid] + rows
        for (upper, lower) in zip(stack, stack.dropFirst()) {
            let a = upper.convert(upper.bounds, to: view), b = lower.convert(lower.bounds, to: view)
            #expect(a.maxY <= b.minY + 0.5)
        }
        // 4 columns on a phone, 6 above 600 points; every cover is square and inside the block.
        let first = try #require(element("quickDiscoveryItem-0", in: view, as: UIControl.self))
        let second = try #require(element("quickDiscoveryItem-1", in: view, as: UIControl.self))
        let columns = width > 600 ? 6 : 4
        #expect(abs(first.frame.width - grid.bounds.width / CGFloat(columns)) < 1)
        #expect(abs(first.frame.width - first.frame.height) < 1)
        #expect(first.accessibilityLabel == "Show 1")
        // Reading order follows the layout direction.
        #expect(rtl ? second.frame.minX < first.frame.minX : second.frame.minX > first.frame.minX)
        let more = try #require(element("discoverMore", in: view, as: UIButton.self))
        let attribution = try #require(element("quickDiscoveryAttribution", in: view, as: UILabel.self))
        #expect(more.title(for: .normal) == "Discover more »" && attribution.text == "Suggestions by Apple Podcasts")
        #expect(!more.frame.intersects(attribution.frame))
        #expect(rtl ? more.frame.midX < attribution.frame.midX : more.frame.midX > attribution.frame.midX)
    }

    @Test func suggestionStatesShowSourceTextsAndRetry() async throws {
        let calls = Counter()
        let (controller, root) = try makeController(width: 402) { _, _ in
            if await calls.next() == 1 { throw TopListError.http(503) }
            return []
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let view = controller.view!
        let message = try #require(element("quickDiscoveryMessage", in: view, as: UILabel.self))
        try await wait { !message.isHidden && message.text?.hasPrefix("An error occurred:") == true }
        #expect(message.text?.contains("503") == true)
        let retry = try #require(element("quickDiscoveryRetry", in: view, as: UIButton.self))
        #expect(!retry.isHidden)
        retry.sendActions(for: .touchUpInside)
        try await wait { message.text == "No results were found" }
        #expect(retry.isHidden)
        #expect(element("quickDiscoveryItem-0", in: view, as: UIControl.self) == nil)
        #expect(await calls.value == 2)
    }

    @Test func hiddenSuggestionsKeepDiscoverMoreButNoAttributionOrRequest() async throws {
        let calls = Counter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M25Hidden-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoveryPreferenceStore(file: root.appendingPathComponent("discovery.json"))
        try store.update(.init(countryCode: "DE", hidden: true))
        let quick = QuickDiscoveryView()
        let session = TopListSession(read: { _ in _ = await calls.next(); return [] }, describe: { $0.localizedDescription })
        session.onChange = { [weak quick] in quick?.update(session.state) }
        session.load(store.value, device: "US")
        quick.frame = CGRect(x: 0, y: 0, width: 370, height: quick.sizeThatFits(CGSize(width: 370, height: 0)).height)
        quick.layoutIfNeeded()
        #expect(session.state == .hidden)
        #expect(element("quickDiscoveryMessage", in: quick, as: UILabel.self)?.text == "You selected to hide suggestions.")
        #expect(element("quickDiscoveryAttribution", in: quick, as: UILabel.self)?.isHidden == true)
        let more = try #require(element("discoverMore", in: quick, as: UIButton.self))
        #expect(!more.isHidden && quick.bounds.contains(more.frame))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.value == 0)
    }

    @Test func discoverShowsRowsEmptyAndErrorStates() async throws {
        let outcome = Box(0)
        let session = TopListSession(read: { country in
            switch await outcome.value {
            case 0: return (1...25).map { PodcastSearchResult(title: "\(country) \($0)", imageURL: "", feedURL: "https://itunes.apple.com/lookup?id=\($0)", author: nil) }
            case 1: return []
            default: throw TopListError.noDataForCountry
            }
        }, describe: { error in (error as? TopListError) == .noDataForCountry ? ItunesTopList.noDataMessage : "other" })
        let discover = DiscoverView(session: session)
        session.onChange = { [weak discover] in discover?.update() }
        discover.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        session.load(.init(countryCode: "DE"), device: "US")
        try await wait { element("discoverResult-24", in: discover, as: UIControl.self) != nil }
        discover.layoutIfNeeded()
        let row = try #require(element("discoverResult-0", in: discover, as: UIControl.self))
        // A missing artist on an Apple lookup URL hides the second line.
        #expect(row.accessibilityLabel == "DE 1")
        #expect(element("discoverAttribution", in: discover, as: UILabel.self)?.text == "Suggestions by Apple Podcasts")
        await outcome.set(1); session.load(.init(countryCode: "DE"), device: "US")
        let message = try #require(element("discoverMessage", in: discover, as: UILabel.self))
        try await wait { message.text == "No results were found" && !message.isHidden }
        #expect(element("discoverResult-0", in: discover, as: UIControl.self) == nil)
        await outcome.set(2); session.load(.init(countryCode: "DE"), device: "US")
        try await wait { message.text == "iTunes does not have data for the selected country." }
        #expect(element("discoverRetry", in: discover, as: UIButton.self)?.isHidden == false)
        session.load(.init(countryCode: "DE", hidden: true), device: "US")
        #expect(message.text == "You selected to hide suggestions.")
        #expect(element("discoverRetry", in: discover, as: UIButton.self)?.isHidden == true)
    }

    @Test func chooserListsLinksUnderSubscriptionsAndReportsTheChoiceOrCancel() async throws {
        let links = [DiscoveredFeedLink(url: "http://h/feeds/mp3.xml", label: "MP3 Feed (renamed)"),
                     DiscoveredFeedLink(url: "http://h/feeds/atom.xml", label: "http://h/a/very/long/path/that/ends/in/atom.xml")]
        var chosen: [String] = [], cancelled = 0
        try await withViewTestWindow { host, _ in
            let chooser = FeedChooserController(links: links, choose: { chosen.append($0.url) }, cancel: { cancelled += 1 })
            host.present(chooser, animated: false)
            chooser.view.layoutIfNeeded()
            #expect(element("feedChooserTitle", in: chooser.view, as: UILabel.self)?.text == "Subscriptions")
            let first = try #require(element("feedChooserRow-0", in: chooser.view, as: UIButton.self))
            let second = try #require(element("feedChooserRow-1", in: chooser.view, as: UIButton.self))
            #expect(first.frame.maxY <= second.frame.minY + 0.5)
            #expect(second.titleLabel?.lineBreakMode == .byTruncatingHead && second.titleLabel?.numberOfLines == 1)
            first.sendActions(for: .touchUpInside)
            try await wait { chosen == ["http://h/feeds/mp3.xml"] }
            let again = FeedChooserController(links: links, choose: { chosen.append($0.url) }, cancel: { cancelled += 1 })
            try await wait { host.presentedViewController == nil }
            host.present(again, animated: false)
            #expect(again.accessibilityPerformEscape())
            try await wait { cancelled == 1 && host.presentedViewController == nil }
            #expect(chosen.count == 1)
        }
    }

    @Test func addressDialogBodyShowsTheInlineErrorBelowTheField() throws {
        let body = AddressInputBody(text: "", hint: "RSS address", identifier: "rssAddress")
        let before = body.sizeThatFits(CGSize(width: 320, height: 0)).height
        body.showError("The RSS address you entered is not valid.")
        let size = body.sizeThatFits(CGSize(width: 320, height: 0))
        #expect(size.height > before)
        body.frame = CGRect(origin: .zero, size: size); body.layoutIfNeeded()
        let error = try #require(element("rssAddressError", in: body, as: UILabel.self))
        #expect(!error.isHidden && error.frame.minY >= body.field.frame.maxY && body.bounds.contains(error.frame))
        #expect(body.field.placeholder == "RSS address" && body.field.keyboardType == .URL)
    }

    @Test func countryBodyFiltersTheListAndPicksAName() throws {
        let countries = DiscoveryCountries([("DE", "Germany"), ("GB", "United Kingdom"), ("US", "United States")])
        let body = CountrySelectionBody(countries: countries, current: "United States")
        #expect(body.text == "United States")
        body.textFieldDidBeginEditing(body.field)
        #expect(body.text.isEmpty)
        body.field.text = "uni"; body.field.sendActions(for: .editingChanged)
        body.frame = CGRect(origin: .zero, size: body.sizeThatFits(CGSize(width: 320, height: 0))); body.layoutIfNeeded()
        let option = try #require(element("selectCountryOption-1", in: body, as: UIButton.self))
        #expect(option.title(for: .normal) == "United States")
        #expect(element("selectCountryOption-2", in: body, as: UIButton.self) == nil)
        option.sendActions(for: .touchUpInside)
        #expect(body.text == "United States")
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}
private actor Box {
    private(set) var value: Int
    init(_ value: Int) { self.value = value }
    func set(_ value: Int) { self.value = value }
}
