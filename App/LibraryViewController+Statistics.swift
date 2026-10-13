import UIKit
import NotTennaPodCore
import OSLog

// Statistics: tab bar and pager, Subscriptions, Years and Downloads.
extension LibraryViewController {
    /// Loads every page. Years also reloads on each StatisticsEvent (Filter OK, Reset); Downloads
    /// reloading with them shows the same values.
    func refreshSubscriptionStatistics() {
        guard statisticsVisible else { return }
        statisticsActive = true
        subscriptionStatistics?.load(preferences: statisticsPreferences?.value ?? .init(), formatter: .init())
        yearStatistics?.load()
        downloadStatistics?.load()
        if !renderingContent { render() }
    }

    var statisticsPager: StatisticsPagerView {
        if let statisticsPagerStorage { return statisticsPagerStorage }
        let tabs = StatisticsTab.allCases
        let pager = StatisticsPagerView(titles: tabs.map { Appearance.text($0.titleKey) },
                                        identifiers: ["subscriptions", "years", "downloads"])
        pager.onSelect = { [weak self] index in
            guard let self, let tab = StatisticsTab(rawValue: index), statisticsVisible else { return }
            statisticsTab = tab
            // The toolbar menu follows the settled page (PagedToolbarFragment:25–43).
            render()
        }
        statisticsPagerStorage = pager
        return pager
    }

    func observeStatisticsPages() {
        yearStatistics?.onChange = { [weak self] state in
            guard let self, statisticsActive, statisticsVisible else { return }
            if case .failed(let message) = state {
                Logger(subsystem: "org.nottennapod.app", category: "Statistics").error("Years statistics read failed: \(message, privacy: .public)")
            }
            statisticsPagesChanged()
        }
        downloadStatistics?.onChange = { [weak self] state in
            guard let self, statisticsActive, statisticsVisible else { return }
            if case .failed(let message) = state {
                Logger(subsystem: "org.nottennapod.app", category: "Statistics").error("Download statistics read failed: \(message, privacy: .public)")
            }
            statisticsPagesChanged()
        }
    }

    /// A page finished loading: update the pages in place, so a swipe in progress, the tab and
    /// each page's scroll position are kept.
    func statisticsPagesChanged() {
        if let pager = statisticsPagerStorage, pager.superview === content { updateStatisticsPages() } else { render() }
    }

    /// Leaving the Statistics screen: the next one is a new screen on Subscriptions.
    func leaveStatisticsTabs() {
        statisticsTab = .subscriptions
        yearStatistics?.cancel(); downloadStatistics?.cancel()
        statisticsPagerStorage?.reset()
    }

    func renderStatistics(heading: UILabel) {
        if !statisticsActive { refreshSubscriptionStatistics() }
        let tab = statisticsTab
        // Source statistics menu per page: Subscriptions Filter (ifRoom icon) and overflow Reset,
        // Years overflow Reset only, Downloads nothing.
        let layout = toolbarLayout(hasOverflow: tab.showsReset, hasPrimaryAction: tab.showsFilter)
        heading.frame = layout.title
        if tab.showsFilter {
            let filter = Appearance.icon("ic_filter_white", label: Appearance.text("filter")) { [weak self] in
                self?.showStatisticsFilter()
            }
            filter.accessibilityIdentifier = "statisticsFilter"
            filter.frame = layout.primaryAction; toolbar.addSubview(filter)
        }
        if tab.showsReset {
            let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
                self?.showFeedMenu([(Appearance.text("statistics_reset_data"), "statisticsReset", { [weak self] in self?.confirmStatisticsReset() })],
                                   identifier: "statisticsMenu")
            }
            more.accessibilityIdentifier = "statisticsMore"; more.frame = layout.overflow; toolbar.addSubview(more)
        }
        let pager = statisticsPager
        content.isScrollEnabled = false
        pager.frame = content.bounds
        content.addSubview(pager)
        // Like DrawerLayout, an edge swipe opens the drawer before the pages scroll.
        if let drawerPan = surface.gestureRecognizers?.first(where: { $0 is UIPanGestureRecognizer && $0.delegate === self }) {
            pager.pages.panGestureRecognizer.require(toFail: drawerPan)
        }
        if pager.selected != tab.rawValue { pager.select(tab.rawValue, animated: false) }
        updateStatisticsPages()
        pager.layoutIfNeeded()
    }

    private func updateStatisticsPages() {
        let pager = statisticsPager
        // Subscriptions: a reload for the same period keeps the shown totals until it completes;
        // a new period or a failed read shows loading.
        var subscriptions: SubscriptionStatisticsSnapshot?
        switch subscriptionStatistics?.state {
        case .loaded(let snapshot): subscriptions = snapshot
        case .loading(let request):
            if let last = subscriptionStatistics?.lastSnapshot, last.request.preferences == request.preferences { subscriptions = last }
        default: break
        }
        if let snapshot = subscriptions {
            if (pager.content(ofPage: StatisticsTab.subscriptions.rawValue) as? StatisticsPieListView)?.source != .subscriptions(snapshot) {
                let view = StatisticsPieListView(snapshot: snapshot)
                view.source = .subscriptions(snapshot)
                view.openFeedStatistics = { [weak self] id in
                    guard let row = snapshot.rows.first(where: { $0.statistics.feedID == id }) else { return }
                    self?.presentFeedStatistics(feedID: id, title: row.title)
                }
                pager.setContent(view, forPage: StatisticsTab.subscriptions.rawValue)
            }
        } else { pager.setContent(nil, forPage: StatisticsTab.subscriptions.rawValue) }

        if case .loaded(let snapshot) = yearStatistics?.state {
            if (pager.content(ofPage: StatisticsTab.years.rawValue) as? YearsStatisticsView)?.snapshot != snapshot {
                pager.setContent(YearsStatisticsView(snapshot: snapshot, formatter: .init()), forPage: StatisticsTab.years.rawValue)
            }
        } else { pager.setContent(nil, forPage: StatisticsTab.years.rawValue) }

        if case .loaded(let snapshot) = downloadStatistics?.state {
            if (pager.content(ofPage: StatisticsTab.downloads.rawValue) as? StatisticsPieListView)?.source != .downloads(snapshot) {
                let view = StatisticsPieListView(downloads: snapshot, formatter: .init())
                view.source = .downloads(snapshot)
                view.openFeedStatistics = { [weak self] id in
                    guard let row = snapshot.rows.first(where: { $0.feedID == id }) else { return }
                    self?.presentFeedStatistics(feedID: id, title: row.title)
                }
                pager.setContent(view, forPage: StatisticsTab.downloads.rawValue)
            }
        } else { pager.setContent(nil, forPage: StatisticsTab.downloads.rawValue) }
    }

    /// `FeedStatisticsDialogFragment`: all-time feed statistics with Open podcast and OK.
    private func presentFeedStatistics(feedID: Int64, title: String?) {
        guard presentedViewController == nil else { return }
        let dialog = FeedStatisticsDialog.make(feedID: feedID, title: title, read: statisticsRead()) { [weak self] in self?.drawerAction(.feed(feedID)) }
        present(dialog, animated: true)
    }

    private func showStatisticsFilter() {
        guard presentedViewController == nil, let statisticsPreferences,
              let snapshot = subscriptionStatistics?.lastSnapshot else { return }
        do {
            let selector = try StatisticsFilterController(preferences: statisticsPreferences,
                oldestMilliseconds: snapshot.statistics.oldestPlaybackMilliseconds,
                formatter: .init(), applied: {})
            present(selector, animated: true)
        } catch { showError(error) }
    }

    /// Source `confirmResetStatistics`: ConfirmationDialog with Confirm/Cancel; Cancel writes nothing.
    private func confirmStatisticsReset() {
        let dialog = SourceMessageController(title: Appearance.text("statistics_reset_data"),
            message: Appearance.text("statistics_reset_data_msg"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "statisticsResetConfirm",
                            perform: { [weak self] in self?.resetStatistics() }),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "statisticsResetCancel"))
        messages.present(dialog)
    }

    /// Source `doResetStatistics`: period choices return to defaults, all played durations are zeroed
    /// in one transaction, then statistics reload. A choice-write failure stops before touching data.
    private func resetStatistics() {
        guard let library else { return }
        do { try statisticsPreferences?.update(.init()) } catch { showError(error); return }
        Task { [weak self] in
            do { try await library.resetPlayedDurationStatistics() }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Statistics").error("Statistics reset failed: \(String(describing: error), privacy: .public)") }
            self?.refreshSubscriptionStatistics()
        }
    }

    func statisticsRead() -> FeedStatisticsLoader.Read {
        let library = library
        return { id, now, zone in try await library?.statisticsSnapshot(feedID: id, now: now, timeZone: zone) }
    }
}
