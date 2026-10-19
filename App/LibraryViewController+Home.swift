import UIKit
import NotTennaPodCore

// Home (HomeFragment) sections, cards and configuration.
extension LibraryViewController {
    // MARK: - Home (source HomeFragment)

    func renderHome(heading: UILabel) {
        let layout = toolbarLayout(hasOverflow: true, hasPrimaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "homeSearch"; search.frame = layout.primaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            self?.showFeedMenu([(Appearance.text("refresh_label"), "homeRefresh", { [weak self] in self?.requestFeedRefresh(nil) }),
                                (Appearance.text("configure_home"), "homeConfigure", { [weak self] in self?.showHomeConfiguration() })],
                               identifier: "homeMenu")
        }
        more.accessibilityIdentifier = "homeMore"; more.frame = layout.overflow
        [search, more].forEach(toolbar.addSubview)
        // Welcome: no episodes in subscribed feeds (source getTotalEpisodeCount(unfiltered)); menu stays.
        homeSections = []
        homeShowsWelcome = HomeScreenModel.showsWelcome(mirror)
        guard !homeShowsWelcome else { welcome(); return }
        // Home opens (or appears again): its sections are read from the screens' library once, Classics included.
        if Self.homeSurpriseSeed == 0 { Self.homeSurpriseSeed = Self.initialSurpriseSeed() }
        homeModel = HomeScreenModel(mirror: mirror, inboxSort: episodeLists.inbox, seed: Self.homeSurpriseSeed, now: Self.homeNow(),
                                    includeMarkedAsPlayed: statisticsPreferences?.value.includeMarkedAsPlayed == true)
        var y: CGFloat = 0
        for section in (homePreferences?.value ?? .init()).sections {
            let state = buildHomeSection(section, top: y)
            homeSections.append(state)
            y = state.top + state.height
        }
        content.contentSize.height = max(content.bounds.height, y + 12)
    }

    /// What one Home section shows now, from the kept sections (`HomeScreenModel`).
    func homeContent(_ section: HomeSection) -> HomeSectionContent {
        guard homeModel != nil else { return HomeSectionContent() }
        var content = HomeSectionContent()
        func rows(_ ids: [Int64]) -> [(LibraryFeed, LibraryEpisode)] { ids.compactMap { id in libraryEpisode(id).map { ($0.feed, $0.episode) } } }
        switch section {
        case .queue: content.rows = rows(homeModel?.continueIDs ?? [])
        case .inbox:
            let inbox = homeModel?.inbox() ?? (ids: [], total: 0)
            content.rows = rows(inbox.ids)
            content.badge = inbox.ids.isEmpty ? nil : HomeSectionQueries.badge(inbox.total)
        case .surprise: content.rows = rows(homeModel?.surprise() ?? [])
        case .classics: content.feeds = (homeModel?.classics ?? []).compactMap(mirror.feed)
        case .downloads: content.rows = rows(HomeScreenModel.downloads(mirror, order: downloadPreferences?.value.listSortOrder))
        }
        return content
    }

    /// Draws one section from `top`; returns it with the views it added and its height.
    func buildHomeSection(_ section: HomeSection, top: CGFloat) -> HomeSectionState {
        let existing = Set(content.subviews.map(ObjectIdentifier.init))
        let shown = homeContent(section)
        var y = top
        switch section {
        case .queue:
            y = homeHeader(section, more: "queue_label", destination: .queue, y: y)
            y = shown.rows.isEmpty ? homeEmpty("home_continue_empty_text", y: y) : homeCardStrip(shown.rows, identifier: "homeQueueStrip", y: y)
        case .inbox:
            y = homeHeader(section, more: "inbox_label", destination: .inbox, badge: shown.badge, y: y)
            if shown.rows.isEmpty { y = homeEmpty("home_new_empty_text", y: y) }
            else { y = homeRows(shown.rows, scope: .inbox, y: y) }
        case .surprise:
            y = homeHeader(section, more: "episodes_label", destination: .episodes, shuffle: !shown.rows.isEmpty, y: y)
            y = shown.rows.isEmpty ? homeEmpty("home_no_recent_unplayed_episodes_text", y: y) : homeCardStrip(shown.rows, identifier: "homeSurpriseStrip", y: y)
        case .classics:
            y = homeHeader(section, more: "subscriptions_label", destination: .subscriptions, y: y)
            let covers = shown.feeds.map { feed in
                let cover = HomeFeedCover(feed: feed) { [weak self] in self?.push(.feed(feed.id)) }
                cover.contextMenu = { [weak self] anchor, fraction in self?.showSearchFeedMenu(feed.id, anchor: anchor, fraction: fraction) }
                return cover
            }
            // Source: no empty text; the header stays over an empty strip.
            let strip = HomeStrip(items: covers, pitch: HomeFeedCover.pitch, itemSize: CGSize(width: HomeFeedCover.size, height: HomeFeedCover.size),
                                  identifier: "homeClassicsStrip")
            strip.frame = CGRect(x: 0, y: y, width: content.bounds.width, height: HomeFeedCover.pitch + 8)
            content.addSubview(strip); y = strip.frame.maxY
        case .downloads:
            y = homeHeader(section, more: "downloads_label", destination: .downloads, y: y)
            y = shown.rows.isEmpty ? homeEmpty("home_downloads_empty_text", y: y) : homeRows(shown.rows, scope: .downloads, y: y)
        }
        y += 4
        let views = content.subviews.filter { !existing.contains(ObjectIdentifier($0)) }
        return HomeSectionState(section: section, shown: shown, views: views, top: top, height: y - top)
    }

    static func homeNow() -> Date {
#if DEBUG
        // UI tests pin Home's clock so its time-dependent sections match a fixed oracle result.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-test-home-now-ms"), index + 1 < arguments.count, let ms = Double(arguments[index + 1]) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
#endif
        return Date()
    }

    private static func initialSurpriseSeed() -> Int32 {
#if DEBUG
        // UI tests pin the source seed to reach exact Get surprised lists.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-test-home-surprise-seed"), index + 1 < arguments.count, let seed = Int32(arguments[index + 1]) { return seed }
#endif
        var seed: Int32 = 0
        while seed == 0 { seed = Int32.random(in: .min ... .max) }
        return seed
    }

    private func homeHeader(_ section: HomeSection, more: String, destination: NavigationDestination, badge: String? = nil,
                            shuffle: Bool = false, y: CGFloat) -> CGFloat {
        let header = HomeSectionHeader(section: section, moreTitle: Appearance.text(more), badge: badge,
            onShuffle: shuffle ? { [weak self] in
                var next: Int32 = 0
                while next == 0 { next = Int32.random(in: .min ... .max) }
                Self.homeSurpriseSeed = next
                self?.reseedHome(next)
            } : nil,
            onMore: { [weak self] in self?.select(destination) })
        header.frame = CGRect(x: 0, y: y, width: content.bounds.width, height: HomeSectionHeader.height)
        content.addSubview(header)
        return header.frame.maxY
    }

    private func homeEmpty(_ key: String, y: CGFloat) -> CGFloat {
        let label = Appearance.label(Appearance.text(key), size: 14)
        label.textAlignment = .center; label.textColor = Appearance.secondary
        let width = max(0, content.bounds.width - 64)
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: 32, y: y + 8, width: width, height: height)
        content.addSubview(label)
        return label.frame.maxY + 8
    }

    private func homeCardStrip(_ items: [(LibraryFeed, LibraryEpisode)], identifier: String, y: CGFloat) -> CGFloat {
        // A card opens the pager over this section's cards only (HorizontalItemListAdapter).
        let pagerList = items.map { EpisodePagerItem(feedID: $0.0.id, episodeID: $0.1.id) }
        let cards = items.map { feed, episode in
            let playing = playback?.episode?.id == episode.id && playback?.wantsPlayback == true
            // The card acts through the episode's action model, as a row does, and shows the player's live position.
            let model = actionModel(feed: feed, episode: episode)
            applyLivePosition(model)
            let card = HomeEpisodeCard(feed: feed, episode: model.snapshot().episode, library: library, playing: playing,
                episodeCover: usesEpisodeCover,
                action: { [weak self] in self?.downloadAction(episode.id) },
                open: { [weak self] in self?.openEpisode(feedID: feed.id, episodeID: episode.id, list: pagerList) })
            card.actionModel = model
            card.contextMenu = { [weak self] anchor, fraction in
                self?.showListEpisodeMenu(episode.id, feedID: feed.id, anchor: anchor, fraction: fraction, home: .episodes)
            }
            let job = downloads?.activeJob(source: episode.details.media?.url)
            let localFeed = feed.source.isLocalFeedSource
            card.actionButton.update(episode: episode, job: job, progress: job.flatMap { downloads?.progress[$0.id] }, playing: playing,
                                     localFeed: localFeed,
                                     streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
            homeCards.append((episode, card, localFeed))
            return card
        }
        let strip = HomeStrip(items: cards, pitch: HomeEpisodeCard.pitch, itemSize: CGSize(width: HomeEpisodeCard.width, height: HomeEpisodeCard.height),
                              identifier: identifier)
        strip.frame = CGRect(x: 0, y: y, width: content.bounds.width, height: HomeEpisodeCard.height + 8)
        content.addSubview(strip)
        return strip.frame.maxY
    }

    private func homeRows(_ rows: [(LibraryFeed, LibraryEpisode)], scope: EpisodeSelectionScope, y: CGFloat) -> CGFloat {
        addEpisodeRows(rows, top: y, home: scope)
    }

    private func showHomeConfiguration() {
        guard let homePreferences, presentedViewController == nil else { return }
        let value = homePreferences.value
        present(HomeConfigurationController(shown: value.sections, hidden: value.dialogHidden, onConfirm: { [weak self] shown, hidden in
            do { try homePreferences.update(.confirmed(shown: shown, hidden: hidden)) } catch { self?.showError(error) }
            self?.render()
        }, onReset: { [weak self] in
            do { try homePreferences.update(.init()) } catch { self?.showError(error) }
            self?.render()
        }), animated: true)
    }

    private func welcome() {
        let logo = AdaptiveLogoView()
        logo.frame = CGRect(x: (content.bounds.width - 64) / 2, y: 48, width: 64, height: 64)
        content.addSubview(logo)
        let title = Appearance.label(Appearance.text("home_welcome_title"), size: 20)
        title.textAlignment = .center
        title.accessibilityIdentifier = "welcomeTitle"
        let height = title.sizeThatFits(CGSize(width: content.bounds.width - 64, height: .greatestFiniteMagnitude)).height
        title.frame = CGRect(x: 32, y: 128, width: content.bounds.width - 64, height: height)
        content.addSubview(title)
        let message = Appearance.label(Appearance.text("home_welcome_text"), size: 14)
        message.textAlignment = .center
        let messageHeight = message.sizeThatFits(CGSize(width: content.bounds.width - 64, height: .greatestFiniteMagnitude)).height
        message.frame = CGRect(x: 32, y: title.frame.maxY + 8, width: content.bounds.width - 64, height: messageHeight)
        content.addSubview(message)
        let arrow = UIImageView(image: UIImage(named: "ic_curved_arrow"))
        arrow.tintColor = Appearance.foreground
        arrow.frame = CGRect(x: content.bounds.width - 128, y: max(message.frame.maxY + 16, content.bounds.height - 96), width: 80, height: 80)
        arrow.transform = CGAffineTransform(scaleX: -1, y: -1)
        content.addSubview(arrow)
        content.contentSize.height = max(content.bounds.height, arrow.frame.maxY + 16)
    }
}
