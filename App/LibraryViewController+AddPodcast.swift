import UIKit
import Synchronization
import NotTennaPodCore

/// The parts of the Add-podcast screen that live across renders.
@MainActor final class AddPodcastScreenState {
    /// False once another screen has been rendered: returning recreates the suggestions (onCreateView).
    fileprivate(set) var visible = false
    fileprivate var searchBar: AddPodcastSearchBar?
    fileprivate var suggestions: QuickDiscoveryView?
    fileprivate var session: TopListSession?
    /// Tests replace the top-list request (country, limit).
    var readTopList: (@Sendable (String, Int) async throws -> [PodcastSearchResult])?
    func left() { visible = false; session?.cancel() }
}

// Add podcast (AddFeedFragment): search box, suggestions, the six rows, and the online feed page
// (OnlineFeedViewActivity) with website discovery, the chooser and the error dialogs.
extension LibraryViewController {
    func addPodcast() {
        let state = addPodcastScreen
        let firstShow = !state.visible
        state.visible = true
        let width = content.bounds.width
        let bar = state.searchBar ?? {
            let bar = AddPodcastSearchBar()
            bar.onSubmit = { [weak self] in self?.performAddPodcastSearch($0) }
            state.searchBar = bar
            return bar
        }()
        let inset = min(16, width / 4)
        bar.frame = CGRect(x: inset, y: 8, width: max(0, width - inset * 2), height: bar.sizeThatFits(CGSize(width: width, height: 0)).height)
        content.addSubview(bar)
        let suggestions = state.suggestions ?? makeSuggestions()
        if firstShow { reloadSuggestions() }
        let suggestionWidth = max(0, width - inset * 2)
        suggestions.frame = CGRect(x: inset, y: bar.frame.maxY + 8 + 16, width: suggestionWidth,
                                   height: suggestions.sizeThatFits(CGSize(width: suggestionWidth, height: 0)).height)
        content.addSubview(suggestions)
        var y = suggestions.frame.maxY + 16
        let rows: [(String, String, String, () -> Void)] = [
            ("add_podcast_by_url", "ic_feed", "addRSS", { [weak self] in self?.askForAddress() }),
            ("add_local_folder", "ic_folder", "addLocalFolder", { [weak self] in self?.chooseLocalFolder() }),
            ("search_itunes_label", "ic_search", "addSearchApple", { [weak self] in self?.openProviderSearch(.apple, query: nil) }),
            ("search_fyyd_label", "ic_search", "addSearchFyyd", { [weak self] in self?.openProviderSearch(.fyyd, query: nil) }),
            ("search_podcastindex_label", "ic_search", "addSearchPodcastIndex", { [weak self] in self?.openProviderSearch(.podcastIndex, query: nil) }),
            ("opml_add_podcast_label", "ic_download", "addOPML", { [weak self] in self?.opmlImportFlow?.chooseDocument() }),
        ]
        for (key, image, identifier, action) in rows {
            let row = AddPodcastEntryButton(title: Appearance.text(key), image: image, identifier: identifier, action: action)
            row.frame = CGRect(origin: CGPoint(x: 0, y: y), size: row.sizeThatFits(content.bounds.size))
            content.addSubview(row)
            y = row.frame.maxY
        }
        content.contentSize.height = max(content.bounds.height, y + 16)
    }

    private func makeSuggestions() -> QuickDiscoveryView {
        let state = addPodcastScreen
        let view = QuickDiscoveryView()
        let session = TopListSession(read: topListReader(limit: ItunesTopList.addScreenLimit), describe: Self.topListErrorText())
        session.onChange = { [weak self, weak view, weak session] in
            guard let self, let view, let session else { return }
            let before = view.bounds.height
            view.update(session.state)
            let after = view.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
            // A state with another height moves the rows below; lay the screen out again after this update.
            guard abs(after - before) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, case .destination(.addPodcast) = path.last else { return }
                render()
            }
        }
        view.onSelect = { [weak self] item in
            // A placeholder has no URL and does nothing.
            guard !item.feedURL.isEmpty else { return }
            self?.openFeedPage(item.feedURL, manual: false)
        }
        view.onRetry = { [weak self] in self?.reloadSuggestions() }
        view.onDiscoverMore = { [weak self] in self?.openDiscover() }
        state.suggestions = view; state.session = session
        return view
    }

    private func reloadSuggestions() {
        guard let session = addPodcastScreen.session else { return }
        // Without the preference store (previews, isolated view hosts) nothing is requested.
        guard let preferences = discoveryPreferences else { return }
        session.load(preferences.value, device: Self.deviceCountry)
    }

    static var deviceCountry: String {
        let region = Locale.current.region?.identifier ?? ""
        return region.count == 2 && region.allSatisfy({ $0.isASCII && $0.isLetter }) ? region : "US"
    }

    private func topListReader(limit: Int) -> @Sendable (String) async throws -> [PodcastSearchResult] {
        if let override = addPodcastScreen.readTopList { return { try await override($0, limit) } }
        let client = podcastSearch
        return { [weak self] country in
            // DBReader.getFeedList at each load: every stored feed, including previews and archived.
            let feeds = await MainActor.run { self?.feeds ?? [] }
            return try await client.topList(country: country, limit: limit, feeds: feeds)
        }
    }

    /// ItunesTopListLoader messages: HTTP 400 is a literal; other statuses follow "An error occurred:".
    private static func topListErrorText() -> @Sendable (any Error) -> String {
        let prefix = Appearance.text("error_msg_prefix")
        return { error in
            switch error {
            case TopListError.noDataForCountry: ItunesTopList.noDataMessage
            case TopListError.http(let code): prefix + "HTTP \(code) " + HTTPURLResponse.localizedString(forStatusCode: code)
            default: error.localizedDescription
            }
        }
    }

    // MARK: Search box and provider screens

    func performAddPodcastSearch(_ text: String) {
        switch AddPodcastInput.route(text) {
        case .feedPage(let url): openFeedPage(url, manual: true)
        case .combinedSearch(let query):
            openProviderSearch(.combined, query: query)
            addPodcastScreen.searchBar?.field.text = ""
        }
    }

    /// OnlineSearchFragment for one provider; the Add-box text is not carried into the provider rows.
    func openProviderSearch(_ provider: PodcastSearchProvider, query: String?) {
        push(.onlineSearch(makeOnlineSearch(provider: provider, query: query)))
    }

    // MARK: Discover (DiscoveryFragment)

    /// Discover's root tag (`MainActivity.loadFragment` saves it as the last page).
    static let discoverTag = "DiscoveryFragment"

    func openDiscover() {
        let discover = makeDiscover()
        loadRootScreen(.discover(discover.view), tag: Self.discoverTag)
        discover.load()
    }

    /// The Discover page and the read of its top list (opened, or restored with its scene).
    func makeDiscover() -> (view: DiscoverView, load: () -> Void) {
        let session = TopListSession(read: topListReader(limit: ItunesTopList.discoverLimit), describe: Self.topListErrorText())
        let discover = DiscoverView(session: session)
        session.onChange = { [weak discover] in discover?.update() }
        discover.onSelect = { [weak self] in self?.openFeedPage($0.feedURL, manual: false) }
        discover.onRetry = { [weak self, weak session] in if let session { self?.loadTopList(session) } }
        return (discover, { [weak self, weak session] in if let session { self?.loadTopList(session) } })
    }

    private func loadTopList(_ session: TopListSession) {
        session.load(discoveryPreferences?.value ?? .init(), device: Self.deviceCountry)
    }

    func renderDiscover(_ discover: DiscoverView, heading: UILabel) {
        content.isScrollEnabled = false
        discover.emptyAreaTop = -content.frame.minY
        discover.frame = content.bounds; discover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(discover)
        let layout = toolbarLayout(hasOverflow: true, forceNavigation: true)
        heading.frame = layout.title
        let back = Appearance.icon("abc_ic_ab_back_material", label: Appearance.text("toolbar_back_button_content_description")) { [weak self] in
            self?.performRootBack()
        }
        back.configuration?.image = UIImage(named: "abc_ic_ab_back_material")?.imageFlippedForRightToLeftLayoutDirection()
        back.accessibilityIdentifier = "toolbarBack"; back.frame = layout.navigation
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self, weak discover] in
            guard let self, let discover else { return }
            let hidden = discoveryPreferences?.value.hidden ?? false
            // countries_menu.xml: Hide (checkable), then Select country; no icons.
            showFeedMenu([(Appearance.text("discover_hide"), "discoverHide", { [weak self] in self?.toggleDiscoverHide(discover) }),
                          (Appearance.text("select_country"), "discoverSelectCountry", { [weak self] in self?.showCountrySelection(discover) })],
                         identifier: "discoverMenu", accessories: ["discoverHide": .checkbox(hidden)])
        }
        more.accessibilityIdentifier = "discoverOverflow"; more.frame = layout.overflow
        toolbar.addSubview(back); toolbar.addSubview(more)
        discover.update()
    }

    private func toggleDiscoverHide(_ discover: DiscoverView) {
        guard let store = discoveryPreferences else { return }
        var value = store.value; value.hidden.toggle()
        do { try store.update(value) } catch { showError(error); return }
        loadTopList(discover.session)
    }

    static func platformCountries() -> DiscoveryCountries {
        let codes = Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isUppercase } }.sorted()
        return DiscoveryCountries(codes.compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } })
    }

    private func showCountrySelection(_ discover: DiscoverView) {
        guard let store = discoveryPreferences else { return }
        let countries = Self.platformCountries(), device = Self.deviceCountry
        let body = CountrySelectionBody(countries: countries, current: countries.name(for: store.value.country(device: device)))
        let dialog = SourceMessageController(title: nil, message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "selectCountryOK", perform: { [weak self, weak body, weak discover] in
                guard let self, let body else { return }
                do { try store.update(countries.confirm(body.text, current: store.value, device: device)) }
                catch { showError(error); return }
                if let discover { loadTopList(discover.session) }
            }),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "selectCountryCancel"), customBody: body)
        dialog.avoidsKeyboard = true
        body.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        present(dialog, animated: true)
    }

    // MARK: Local folder

    private func chooseLocalFolder() {
        let picker = localFolderPicker.makeController { [weak self] directory in
            Task { [weak self] in await self?.addLocalFolder(directory) }
        }
        present(picker, animated: true)
    }

    func addLocalFolder(_ directory: URL) async {
        guard let localFolders else { return }
        do {
            let selection = try await LocalFolderSelection.prepare(directory: directory)
            let feed = try await localFolders.add(selection, fallbackTitle: Appearance.text("local_folder"))
            await reloadLibrary()?.value
            push(.feed(feed.id))
        } catch is CancellationError { }
        catch { showNotice(error.localizedDescription) }
    }

    // MARK: Add podcast by RSS address

    /// showAddViaUrlDialog: Confirm accepts only a WEB_URL match; otherwise the field shows
    /// "The RSS address you entered is not valid." and the dialog stays. The clipboard is not read
    /// (iOS asks for permission on every programmatic paste; Paste stays in the field's menu).
    private func askForAddress() {
        let input = AddressInputBody(text: "", hint: Appearance.text("rss_address"), identifier: "rssAddress")
        weak var presented: SourceMessageController?
        var confirmed = false
        let confirm: () -> Void = { [weak self, weak input] in
            guard let input, !confirmed else { return }
            let text = input.text
            guard AddPodcastInput.isValidAddress(text) else { input.showError(Appearance.text("rss_address_invalid")); return }
            confirmed = true
            input.field.resignFirstResponder()
            presented?.dismiss(animated: true) { self?.openFeedPage(text, manual: true) }
        }
        let dialog = SourceMessageController(title: Appearance.text("add_podcast_by_url"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "addRSSConfirm", perform: confirm, dismisses: false),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "addRSSCancel"), customBody: input)
        presented = dialog
        dialog.avoidsKeyboard = true
        input.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        input.onReturn = confirm
        present(dialog, animated: true)
    }

    // MARK: Online feed page

    /// Search results, suggestions, Discover and library search: not a manually entered address.
    func fetch(_ address: String) { openFeedPage(address, manual: false) }

    func openFeedPage(_ address: String, manual: Bool) {
        fetchTask?.cancel()
        let preview = FeedPreviewController(content: FeedPreviewLoadingController())
        preview.onClose = { [weak self] in self?.fetchTask?.cancel() }
        messages.present(preview)
        loadFeedPage(address, manual: manual, visited: [], preview: preview)
    }

    /// lookup → existing-feed check → download → parse. `visited` holds the page URLs followed
    /// automatically in this page session (a repeated one-link page stops).
    private func loadFeedPage(_ address: String, manual: Bool, visited: Set<String>, preview: FeedPreviewController) {
        fetchTask?.cancel()
        fetchTask = Task { [weak self, weak preview] in
            guard let self, let preview else { return }
            do {
                let resolved: PodcastSearchClient.FeedResolution
                do { resolved = try await podcastSearch.resolveFeed(try FeedAddress.prepare(address)) }
                catch {
                    try Task.checkCancellation()
                    previewFailure(Appearance.text("null_value_podcast_error"), preview: preview)
                    return
                }
                let source = try FeedAddress.prepare(resolved.url)
                if let library, let existing = try await library.snapshot().feeds.first(where: { $0.source == source }) {
                    try Task.checkCancellation()
                    await reloadLibrary()?.value
                    try Task.checkCancellation()
                    if existing.subscriptionState == .notSubscribed {
                        showPreview(existing.id, recoveredBySearch: resolved.recoveredBySearch, container: preview)
                    } else {
                        preview.dismiss(animated: true) { [weak self] in self?.push(.feed(existing.id)) }
                    }
                    return
                }
                await fetchPreview(source: source, recoveredBySearch: resolved.recoveredBySearch, credentials: nil,
                                   manual: manual, visited: visited, preview: preview)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { previewFailure(error.localizedDescription, preview: preview) } }
        }
    }

    private func fetchPreview(source: String, recoveredBySearch: Bool, credentials: FeedCredentials?, manual: Bool,
                              visited: Set<String>, preview: FeedPreviewController) async {
        let diagnostic = Mutex<String?>(nil)
        do {
            let result = try await FeedFetcher(transport: proxyTransport, userAgent: HTTPUserAgent.current).fetch(
                // A server library's subscription parses with the parity parse, as its refreshes do.
                FeedFetchRequest(source: source, credentials: credentials, force: true, generateMissingArtwork: false,
                                 classifiesDocuments: true, parity: library?.isServerLibraryAtOpen ?? false),
                failureDiagnostic: { message in diagnostic.withLock { $0 = message } })
            try Task.checkCancellation()
            guard case .updated(let fetched) = result, let library else { return }
            let saved: LibraryFeed
            if let credentials, let feedAuthentication {
                saved = try await feedAuthentication.preparePreview(fetched, credentials: credentials)
            } else { saved = try await library.preparePreview(fetched) }
            try Task.checkCancellation()
            await reloadLibrary()?.value
            try Task.checkCancellation()
            if saved.subscriptionState == .notSubscribed {
                showPreview(saved.id, recoveredBySearch: recoveredBySearch, container: preview)
            } else { preview.dismiss(animated: true) { [weak self] in self?.push(.feed(saved.id)) } }
        } catch FeedFetchError.unauthorized {
            guard !Task.isCancelled else { return }
            let dialog = FeedAuthenticationController.make(credentials: credentials, confirm: { [weak self, weak preview] login in
                guard let self, let preview else { return }
                fetchTask = Task { [weak self, weak preview] in
                    guard let self, let preview else { return }
                    await fetchPreview(source: source, recoveredBySearch: recoveredBySearch, credentials: login,
                                       manual: manual, visited: visited, preview: preview)
                }
            }, cancel: { [weak preview] in preview?.close() })
            messages.present(dialog)
        } catch FeedDocumentError.unsupported(let root, let message, let body) {
            guard !Task.isCancelled else { return }
            if root?.lowercased() == "html" {
                let links = FeedDiscoverer.findLinks(in: String(decoding: body, as: UTF8.self), base: source)
                let seen = visited.union([source])
                // One link opens directly; the chosen feed is no longer a manual address (resetIntent).
                if links.count == 1, !seen.contains(links[0].url) {
                    loadFeedPage(links[0].url, manual: false, visited: seen, preview: preview); return
                }
                if links.count > 1 {
                    let chooser = FeedChooserController(links: links, choose: { [weak self, weak preview] link in
                        guard let self, let preview else { return }
                        loadFeedPage(link.url, manual: false, visited: seen, preview: preview)
                    }, cancel: { [weak preview] in preview?.close() })
                    messages.present(chooser); return
                }
            }
            showFeedError(OnlineFeedFailure(document: root, message: message, manual: manual), url: source, manual: manual, preview: preview)
        } catch FeedDocumentError.broken(let message) {
            guard !Task.isCancelled else { return }
            showFeedError(.init(labelKey: "download_error_parser_exception", details: message), url: source, manual: manual, preview: preview)
        } catch let error as FeedFetchError {
            guard !Task.isCancelled else { return }
            showFeedError(OnlineFeedFailure(error, diagnostic: diagnostic.withLock { $0 }), url: source, manual: manual, preview: preview)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { previewFailure(error.localizedDescription, preview: preview) } }
    }

    /// showErrorDialog: "Error", the label followed by the technical reason and file URL in grey,
    /// OK closes the page; Edit feed URL only for a manually entered address. No Retry button.
    private func showFeedError(_ failure: OnlineFeedFailure, url: String, manual: Bool, preview: FeedPreviewController) {
        let label = Appearance.text(failure.labelKey)
        let composed = OnlineFeedFailure.message(label: label, details: failure.details, url: url,
                                                 template: Appearance.text("download_log_details_message"))
        var details = String(composed.text.dropFirst(label.count))
        if details.hasPrefix(" \n\n") { details.removeFirst(3) }
        let edit: SourceMessageController.Action? = manual ? .init(title: Appearance.text("edit_url_menu"), identifier: "feedErrorEditURL",
            perform: { [weak self, weak preview] in
                guard let self, let preview else { return }
                editFeedURL(url, preview: preview)
            }, performAfterDismiss: true) : nil
        let dialog = SourceMessageController(title: Appearance.text("error_label"), message: label, details: details,
            // Source OnlineFeedViewActivity error dialogs use android.R.string.ok.
            positive: .init(title: Appearance.text("ok"), identifier: "feedPreviewErrorConfirm",
                            perform: { [weak preview] in preview?.close() }, performAfterDismiss: true),
            neutral: edit)
        dialog.onCancelAfterDismiss = { [weak preview] in preview?.close() }
        messages.present(dialog)
    }

    /// editUrl: prefilled with the last download's address; Confirm tries again without address
    /// validation and keeps the manual flag; Cancel, Back or a tap outside closes the page.
    private func editFeedURL(_ url: String, preview: FeedPreviewController) {
        let input = AddressInputBody(text: url, hint: Appearance.text("rss_address"), identifier: "editFeedURLField")
        let dialog = SourceMessageController(title: Appearance.text("edit_url_menu"), message: "",
            // The input is read after the dialog has gone, so the action keeps it.
            positive: .init(title: Appearance.text("confirm_label"), identifier: "feedErrorEditConfirm", perform: { [weak self, weak preview] in
                guard let self, let preview else { return }
                loadFeedPage(input.text, manual: true, visited: [], preview: preview)
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "feedErrorEditCancel",
                            perform: { [weak preview] in preview?.close() }, performAfterDismiss: true),
            customBody: input)
        dialog.avoidsKeyboard = true
        dialog.onCancelAfterDismiss = { [weak preview] in preview?.close() }
        input.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        messages.present(dialog)
    }

    func previewFailure(_ message: String, preview: FeedPreviewController) {
        let dialog = SourceMessageController(title: Appearance.text("error_label"), message: message,
            // Source OnlineFeedViewActivity error dialogs use android.R.string.ok.
            positive: .init(title: Appearance.text("ok"), identifier: "feedPreviewErrorConfirm",
                            perform: { [weak preview] in preview?.close() }, performAfterDismiss: true))
        dialog.onCancelAfterDismiss = { [weak preview] in preview?.close() }
        messages.present(dialog)
    }

    func showPreview(_ feedID: Int64, recoveredBySearch: Bool, container: FeedPreviewController? = nil) {
        let child = LibraryViewController(library: library, startupError: nil, downloads: downloads, playback: playback,
            timeDisplayPreferences: timeDisplayPreferences, navigationPreferences: navigationPreferences,
            speedPreferences: speedPreferences, mobileNetworkPreferences: mobileNetworkPreferences, usage: usage, loadSnapshot: loadSnapshot,
            manualRefresh: manualRefresh, podcastSearch: podcastSearch,
            previewFeedID: feedID, feedAuthentication: feedAuthentication,
            automaticDownloadPreferences: automaticDownloadPreferences, downloadPreferences: downloadPreferences, proxyPreferences: proxyPreferences, proxyTransport: proxyTransport, playbackHardwarePreferences: playbackHardwarePreferences, statisticsPreferences: statisticsPreferences, refreshNetwork: refreshNetwork)
        let preview = container ?? FeedPreviewController(content: child, recoveredBySearch: recoveredBySearch)
        if container != nil { preview.replaceContent(child); preview.showRecoveryNoticeIfNeeded(recoveredBySearch) }
        preview.onClose = nil
        child.onPreviewClose = { [weak preview] in preview?.close() }
        child.onPreviewSubscribe = { [weak self, weak preview] id in
            guard let self, let library else { return }
            let changed = try await library.subscribePreview(feedID: id)
            if let preview {
                await withCheckedContinuation { continuation in preview.dismiss(animated: true) { continuation.resume() } }
            }
            await openNotification(.feed(id))
            if changed, let feed = try await library.feed(id: id) { requestFeedRefresh(feed) }
        }
        if container == nil { present(preview, animated: true) }
    }
}
