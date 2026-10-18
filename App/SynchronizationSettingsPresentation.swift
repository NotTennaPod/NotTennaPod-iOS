import UIKit
import NotTennaPodCore

/// Scene presentation of the application's shared synchronization owners.
@MainActor final class SynchronizationSettingsPresentation {
    let accounts: SynchronizationAccounts
    private let store: FeedLibraryStore
    private let coordinator: SynchronizationCoordinator
    private let delivery: SynchronizationDelivery
    private(set) var saved = SynchronizationState()
    /// `saved` has been read from the library at least once (until then it is the empty state).
    private(set) var loaded = false
    private var status: SynchronizationDelivery.Snapshot?
    private var observation: Task<Void, Never>?
    private var statusObservation: Task<Void, Never>?
    /// The NotTennaPod server accounts (PROTOCOL §15.5); nil where the app has none (view tests).
    let server: ServerAccounts?
    private var serverObservation: ServerAccounts.Observation?
    /// The empty-account question is on screen.
    var asksQuestion = false
    var onChange: (() -> Void)?
    var onFailure: ((any Error) -> Void)?

    init(store: FeedLibraryStore, accounts: SynchronizationAccounts,
         coordinator: SynchronizationCoordinator, delivery: SynchronizationDelivery,
         server: ServerAccounts? = (UIApplication.shared.delegate as? AppDelegate)?.serverAccounts) {
        self.store = store; self.accounts = accounts; self.coordinator = coordinator; self.delivery = delivery
        self.server = server
        serverObservation = server?.observe { [weak self] in self?.onChange?() }
        observation = Task { [weak self, store] in
            let events = await store.synchronizationChanges()
            await self?.reload()
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
        statusObservation = Task { [weak self, delivery] in
            for await value in delivery.updates() {
                guard !Task.isCancelled else { return }
                self?.status = value
                await self?.reload()
            }
        }
    }
    deinit { observation?.cancel(); statusObservation?.cancel() }

    private func reload() async {
        do {
            let value = try await store.synchronizationState()
            guard !Task.isCancelled else { return }
            saved = value; loaded = true; onChange?()
        } catch { if !Task.isCancelled { onFailure?(error) } }
    }

    /// The page's server-mode state; nil without server accounts.
    var serverPage: ServerSynchronizationPage? { server?.page(otherProvider: saved.account != nil) }

    var subtitle: String? {
        if let page = serverPage, !page.showsOrdinaryRows || page.condition != nil {
            return page.subtitle.map(ServerSynchronizationText.subtitle)
        }
        guard saved.account != nil else { return nil }
        if let status, status.epoch == saved.epoch {
            let key: String?
            switch status.status {
            case .started: key = "sync_status_started"
            case .subscriptions: key = "sync_status_subscriptions"
            case .waitingForRefresh: key = "sync_status_wait_for_downloads"
            case .downloadingEpisodes: key = "sync_status_episodes_download"
            case .uploadingEpisodes: key = "sync_status_episodes_upload"
            case .uploadingPlayed: key = "sync_status_upload_played"
            case .success, .error: key = nil
            }
            if let key { return Appearance.text(key) }
        }
        let relative = SynchronizationStatusDateFormatter.string(from: saved.lastAttempt ?? Date(timeIntervalSince1970: 0))
        return Appearance.text(saved.lastAttemptSuccessful ? "gpodnetsync_pref_report_successful" : "gpodnetsync_pref_report_failed") + " (" + relative + ")"
    }

    func synchronize(full: Bool = false, epoch: UUID) async throws {
        _ = try await coordinator.request(immediately: true, full: full, expectedEpoch: epoch).value
    }
    func logout(accountID: UUID) async throws { try await accounts.disconnect(expectedAccountID: accountID) }
    func changePassword(_ password: String, accountID: UUID) async throws {
        try await accounts.changePassword(password, expectedAccountID: accountID)
    }
}

@MainActor final class SynchronizationSettingsView: UIView {
    enum Action: Equatable {
        case choose, password, synchronize, full, logout
        // NotTennaPod server rows (PROTOCOL §15.5).
        case serverPassword, startOver, log, attention, keptLibraries
        /// "Library from before %1$@" (PROTOCOL §15.4).
        case previousLibrary(String)
        /// "Stop playback and continue": a switch or Keep waiting for playback goes ahead.
        case stopPlayback
    }
    var onAction: ((Action) -> Void)?
    private struct Row {
        let control: UIControl
        let title: UILabel
        let summary: UILabel
        let icon: UIImageView?
    }
    private var rows: [Row] = []

    init(state: SynchronizationState, server: ServerSynchronizationPage? = nil, width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        if let server, !server.showsOrdinaryRows {
            addServerRows(server)
            frame.size.height = arrange(width: width)
            return
        }
        let account = state.account
        addRow(.choose, id: "preference_synchronization_description",
            title: account == nil ? Appearance.text("synchronization_choose_title") : nil,
            summary: Appearance.text(account.map { $0.backend == .gpodder ? "gpodnet_description" : "synchronization_summary_nextcloud" } ?? "synchronization_summary_unchoosen"),
            icon: account.map { $0.backend == .gpodder ? "gpodder_icon" : "nextcloud_logo" }, enabled: true, actionable: account == nil)
        if account?.backend == .gpodder {
            addRow(.password, id: "pref_gpodnet_setlogin_information", title: Appearance.text("pref_gpodnet_setlogin_information_title"),
                summary: Appearance.text("pref_gpodnet_setlogin_information_sum"), enabled: true)
        }
        addRow(.synchronize, id: "pref_synchronization_sync", title: Appearance.text("synchronization_sync_changes_title"),
            summary: Appearance.text("synchronization_sync_summary"), enabled: account != nil)
        addRow(.full, id: "pref_synchronization_force_full_sync", title: Appearance.text("synchronization_full_sync_title"),
            summary: Appearance.text("synchronization_force_sync_summary"), enabled: account != nil)
        addRow(.logout, id: "pref_synchronization_logout", title: Appearance.text("synchronization_logout"),
            summary: account.map { Self.loginStatus(username: $0.username, host: $0.host) }, enabled: account != nil)
        if let server {
            // Logged out while playing: the status row explains, below the provider row, with its action below it.
            if server.condition != nil { addStatusRow(server, at: 1) }
            if server.rows.contains(.stopPlayback) { addStopPlaybackRow(at: 2) }
            if server.rows.contains(.keptLibraries) { addKeptLibrariesRow(server) }
            addPreviousLibraryRows(server)
        }
        frame.size.height = arrange(width: width)
    }

    /// One row per previous library (PROTOCOL §15.5), labelled by its `kept_at` date, with the time when two share a date.
    private func addPreviousLibraryRows(_ page: ServerSynchronizationPage) {
        let labels = Self.previousLibraryLabels(page.previousLibraries)
        for library in page.previousLibraries {
            addRow(.previousLibrary(library.id), id: "ntp_server_previous_library-\(library.id)", title: labels[library.id], summary: nil, enabled: true)
        }
    }

    /// "Library from before %1$@" for each previous library.
    static func previousLibraryLabels(_ libraries: [LibraryRegistry.PreviousLibrary]) -> [String: String] {
        func date(_ library: LibraryRegistry.PreviousLibrary, time: Bool) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium; formatter.timeStyle = time ? .short : .none
            return formatter.string(from: Date(timeIntervalSince1970: Double(library.keptAt) / 1_000))
        }
        let days = Dictionary(grouping: libraries) { date($0, time: false) }
        return Dictionary(uniqueKeysWithValues: libraries.map { library in
            let shared = (days[date(library, time: false)]?.count ?? 0) > 1
            return (library.id, String(format: Appearance.text("ntp_server_previous_library"), date(library, time: shared)))
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Server mode, attaching and ready (PROTOCOL §15.5 rows by state), in the page's row style.
    private func addServerRows(_ page: ServerSynchronizationPage) {
        for row in page.rows {
            switch row {
            case .provider:
                addRow(.choose, id: "preference_synchronization_description", title: nil,
                       summary: Appearance.text("ntp_server_description"), image: ServerProviderIcon.image, enabled: true, actionable: false)
            case .status: addStatusRow(page, at: nil)
            case .startOver:
                addRow(.startOver, id: "ntp_server_start_over", title: Appearance.text("ntp_server_start_over_title"),
                       summary: Appearance.text("ntp_server_start_over_sum"), enabled: true)
            case .changeLogin:
                addRow(.serverPassword, id: "ntp_server_setlogin_information", title: Appearance.text("pref_gpodnet_setlogin_information_title"),
                       summary: Appearance.text("ntp_server_setlogin_information_sum"), enabled: true)
            case .synchronize:
                let unsent = page.unsentChanges > 0 ? "\n" + Appearance.plural("ntp_server_unsent_changes", page.unsentChanges) : ""
                addRow(.synchronize, id: "pref_synchronization_sync", title: Appearance.text("synchronization_sync_changes_title"),
                       summary: Appearance.text("synchronization_sync_summary") + unsent, enabled: true)
            case .fullSynchronization:
                addRow(.full, id: "pref_synchronization_force_full_sync", title: Appearance.text("synchronization_full_sync_title"),
                       summary: Appearance.text("synchronization_force_sync_summary"), enabled: true)
            case .log:
                addRow(.log, id: "ntp_server_log", title: Appearance.text("ntp_server_log_title"),
                       summary: Appearance.text("ntp_server_log_sum"), enabled: true)
            case .attention:
                addRow(.attention, id: "ntp_server_attention", title: Appearance.text("ntp_server_attention_title"),
                       summary: Appearance.plural("ntp_server_attention_items", page.exchange.attentionItems), enabled: true)
            case .logout:
                addRow(.logout, id: "pref_synchronization_logout", title: Appearance.text("synchronization_logout"),
                       summary: page.library.map { Self.loginStatus(username: $0.entry.username, host: $0.entry.serverURL) }, enabled: true)
            case .keptLibraries: addKeptLibrariesRow(page)
            case .stopPlayback: addStopPlaybackRow(at: nil)
            case .previousLibrary: break
            }
        }
        addPreviousLibraryRows(page)
    }

    private func addStatusRow(_ page: ServerSynchronizationPage, at index: Int?) {
        guard let condition = page.condition else { return }
        let text = ServerSynchronizationText.status(condition, hold: page.playbackHold)
        // "Sign in again" opens the password dialog, "See the synchronization log" (a recovery that could not restore
        // everything, or waits for another device) the log; the other statuses only explain.
        let opensLog = condition == .recoveryIncomplete || condition == .recoveryWaiting
        addRow(opensLog ? .log : .serverPassword, id: "ntp_server_status", title: text.title, summary: text.summary,
               enabled: true, actionable: condition == .needsSignIn || opensLog, at: index)
    }

    /// "Stop playback and continue", below the status row of a switch or Keep waiting for playback.
    private func addStopPlaybackRow(at index: Int?) {
        addRow(.stopPlayback, id: "ntp_server_stop_playback", title: Appearance.text("ntp_server_stop_playback"), summary: nil,
               enabled: true, at: index)
    }

    private func addKeptLibrariesRow(_ page: ServerSynchronizationPage) {
        let count = Appearance.plural("ntp_server_libraries_count", page.keptLibraries.count)
        let unsent = page.keptLibraries.reduce(0) { $0 + $1.unsentChanges }
        let summary = unsent == 0 ? count : String(format: Appearance.text("ntp_server_libraries_summary_unsent"), count,
                                                    Appearance.plural("ntp_server_unsent_changes", unsent))
        addRow(.keptLibraries, id: "ntp_server_libraries", title: Appearance.text("ntp_server_libraries_title"), summary: summary, enabled: true)
    }

    /// Android renders this template through HtmlCompat: literal resource line breaks collapse to spaces.
    static func loginStatus(username: String, host: String) -> String {
        let template = Appearance.text("synchronization_login_status").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(format: template, username, host)
    }

    private func addRow(_ action: Action, id: String, title: String?, summary: String?, icon: String? = nil, image: UIImage? = nil,
                        enabled: Bool, actionable: Bool = true, at index: Int? = nil) {
        let control = UIControl(), heading = Appearance.label(title, size: 16), detail = Appearance.label(summary, size: 14)
        heading.font = Appearance.font(16, medium: true); detail.textColor = Appearance.secondary
        let image = (image ?? icon.flatMap { UIImage(named: $0) }).map { UIImageView(image: $0) }
        image?.contentMode = .scaleAspectFit
        control.isEnabled = enabled
        control.isAccessibilityElement = true; control.accessibilityIdentifier = id
        control.accessibilityLabel = title; control.accessibilityValue = summary
        control.accessibilityTraits = actionable ? .button : .staticText
        if !enabled { control.accessibilityTraits.insert(.notEnabled) }
        control.addSubview(heading); control.addSubview(detail)
        if let image { control.addSubview(image) }
        if actionable { control.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside) }
        addSubview(control)
        let row = Row(control: control, title: heading, summary: detail, icon: image)
        if let index, index <= rows.count { rows.insert(row, at: index) } else { rows.append(row) }
    }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(width: bounds.width) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width)) }
    @discardableResult private func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let inset: CGFloat = width >= 600 ? 24 : 16
        for row in rows {
            let leading: CGFloat = row.icon == nil ? inset : (width >= 600 ? 96 : 72)
            let textWidth = max(1, width - leading - inset)
            let th = row.title.text?.isEmpty == false ? row.title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height : 0
            let sh = row.summary.text?.isEmpty == false ? row.summary.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height : 0
            let height = ceil(max(row.icon == nil ? 64 : 80, th + sh + 32))
            row.control.frame = CGRect(x: 0, y: y, width: width, height: height)
            row.title.frame = CGRect(x: rtl ? inset : leading, y: (height - th - sh) / 2, width: textWidth, height: th)
            row.summary.frame = CGRect(x: rtl ? inset : leading, y: row.title.frame.maxY, width: textWidth, height: sh)
            row.icon?.frame = CGRect(x: rtl ? width - inset - 48 : inset, y: (height - 48) / 2, width: 48, height: 48)
            y += height
        }
        return y
    }
}

@MainActor final class SynchronizationProviderChoices: UIView {
    var onSelect: ((SynchronizationHTTPClient.Backend) -> Void)?
    /// The third provider, NotTennaPod server (PROTOCOL §15.5).
    var onSelectServer: (() -> Void)?
    private var rows: [(UIControl, UILabel, UIImageView)] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        let providers: [(SynchronizationHTTPClient.Backend?, UIImage?, String)] = [
            (.gpodder, UIImage(named: "gpodder_icon"), "gpodnet_description"),
            (.nextcloud, UIImage(named: "nextcloud_logo"), "synchronization_summary_nextcloud"),
            (nil, ServerProviderIcon.image, "ntp_server_description")]
        for (backend, icon, key) in providers {
            let row = UIControl(), label = Appearance.label(Appearance.text(key), size: 14), image = UIImageView(image: icon)
            label.textColor = Appearance.secondary
            image.contentMode = .scaleAspectFit
            row.isAccessibilityElement = true; row.accessibilityLabel = label.text; row.accessibilityTraits = .button
            row.accessibilityIdentifier = "syncProvider-" + (backend?.rawValue ?? "server")
            row.addAction(UIAction { [weak self] _ in
                if let backend { self?.onSelect?(backend) } else { self?.onSelectServer?() }
            }, for: .touchUpInside)
            row.addSubview(label); row.addSubview(image); addSubview(row); rows.append((row, label, image))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(size.width)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(bounds.width) }
    @discardableResult private func arrange(_ width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (row, label, image) in rows {
            let textWidth = max(1, width - 96)
            let h = ceil(max(48, label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height))
            row.frame = CGRect(x: 0, y: y, width: width, height: h + 32)
            label.frame = CGRect(x: rtl ? 16 : 80, y: 16, width: textWidth, height: h)
            image.frame = CGRect(x: rtl ? width - 64 : 16, y: (h + 32 - 48) / 2, width: 48, height: 48)
            y += h + 32
        }
        return y
    }
}

/// The NotTennaPod server's provider icon: the app's own adaptive logo, round, as the About page shows it.
@MainActor enum ServerProviderIcon {
    static let image: UIImage = {
#if DEBUG
        let variant = "debug"
#else
        let variant = "main"
#endif
        let size = CGSize(width: 48, height: 48)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            // AdaptiveLogoView: both layers extend a quarter beyond the visible circle.
            let layer = CGRect(origin: .zero, size: size).insetBy(dx: -size.width / 4, dy: -size.height / 4)
            UIImage(named: "Logo-\(variant)-background")?.draw(in: layer)
            UIImage(named: "Logo-\(variant)-foreground")?.draw(in: layer)
        }
        return image
    }()
}

/// The words of server mode on the Synchronization page (PROTOCOL §15.5).
@MainActor enum ServerSynchronizationText {
    static func subtitle(_ subtitle: ServerSynchronizationPage.Subtitle) -> String {
        switch subtitle {
        case .preparing: Appearance.text("ntp_server_subtitle_preparing")
        case .ready: Appearance.text("ntp_server_subtitle_ready")
        case .restoring: Appearance.text("ntp_server_subtitle_restoring")
        case .signInAgain: Appearance.text("ntp_server_subtitle_sign_in_again")
        case .paused: Appearance.text("ntp_server_subtitle_paused")
        case .waitingForServer: Appearance.text("ntp_server_subtitle_waiting")
        case .waitingForNetwork(let wait): status(.waitingForNetwork(wait)).title
        case .report(let status):
            Appearance.text(status.successful ? "gpodnetsync_pref_report_successful" : "gpodnetsync_pref_report_failed")
                + " (" + SynchronizationStatusDateFormatter.string(from: status.date) + ")"
        }
    }

    /// The status row's words. A switch or Keep held by a resumption after an interruption says so: the player shows
    /// paused, yet playback may resume by itself.
    static func status(_ condition: ServerSynchronizationPage.Condition, hold: LibraryPlaybackHold?) -> (title: String, summary: String) {
        let words = status(condition)
        guard hold == .resumingAfterInterruption else { return words }
        return (words.title, words.summary + " " + Appearance.text("ntp_server_status_interrupted_sum"))
    }

    static func status(_ condition: ServerSynchronizationPage.Condition) -> (title: String, summary: String) {
        func text(_ title: String, _ summary: String) -> (String, String) { (Appearance.text(title), Appearance.text(summary)) }
        switch condition {
        case .attaching(let items):
            return (Appearance.text("ntp_server_status_preparing_title"),
                    String(format: Appearance.text("ntp_server_status_preparing_sum"), items))
        case .ready: return text("ntp_server_status_ready_title", "ntp_server_status_ready_sum")
        case .readyCast: return text("ntp_server_status_ready_title", "ntp_server_status_ready_cast_sum")
        case .loggedOut: return text("ntp_server_status_logged_out_title", "ntp_server_status_logged_out_sum")
        case .loggedOutCast: return text("ntp_server_status_logged_out_title", "ntp_server_status_logged_out_cast_sum")
        case .keeping: return text("ntp_server_status_logged_out_title", "ntp_server_status_keeping_sum")
        case .keepingCast: return text("ntp_server_status_logged_out_title", "ntp_server_status_keeping_cast_sum")
        case .keepStalled(let failure):
            // The reason is a sentence of its own, when it is known (PROTOCOL §15.5).
            let reason = failure == .storage ? Appearance.text("ntp_server_keep_reason_storage") : ""
            let summary = String(format: Appearance.text("ntp_server_status_keep_stalled_sum"), reason)
                .replacingOccurrences(of: "  ", with: " ")
            return (Appearance.text("ntp_server_status_logged_out_title"), summary)
        case .recovering: return text("ntp_server_status_restoring_title", "ntp_server_status_restoring_sum")
        case .recoveryWaiting: return text("ntp_server_status_restoring_title", "ntp_server_status_restore_waiting_sum")
        case .recoveryIncomplete: return text("ntp_server_status_restored_title", "ntp_server_status_restored_sum")
        case .needsSignIn: return text("ntp_server_status_sign_in_title", "ntp_server_status_sign_in_sum")
        case .serverNeedsUpdate: return text("ntp_server_status_server_update_title", "ntp_server_status_update_sum")
        case .appNeedsUpdate: return text("ntp_server_status_app_update_title", "ntp_server_status_update_sum")
        case .lineageUnknown: return text("ntp_server_status_paused_title", "ntp_server_status_lineage_sum")
        case .serverRestored: return text("ntp_server_status_paused_title", "ntp_server_status_restored_backup_sum")
        case .sharedInstallation: return text("ntp_server_status_paused_title", "ntp_server_status_shared_login_sum")
        case .serverLostChanges: return text("ntp_server_status_paused_title", "ntp_server_status_lost_changes_sum")
        case .changeTooLarge: return text("ntp_server_status_paused_title", "ntp_server_status_change_too_large_sum")
        case .changeRefused: return text("ntp_server_status_paused_title", "ntp_server_status_change_refused_sum")
        case .unreachable: return ("", "")
        case .waitingForBackground: return text("ntp_server_status_waiting_background_title", "ntp_server_status_waiting_background_sum")
        case .waitingForNetwork(.offline): return text("download_error_no_connection", "ntp_server_status_offline_sum")
        case .waitingForNetwork(.mobileDataOff): return text("ntp_server_status_wifi_title", "ntp_server_status_wifi_sum")
        case .attachingWaits(.network(.offline)): return text("download_error_no_connection", "ntp_server_status_attach_offline_sum")
        case .attachingWaits(.network(.mobileDataOff)): return text("ntp_server_status_wifi_title", "ntp_server_status_attach_wifi_sum")
        case .attachingWaits(.space): return text("download_error_insufficient_space", "ntp_server_status_attach_space_sum")
        case .waitingForSpace: return text("download_error_insufficient_space", "ntp_server_status_space_sum")
        case .fullSynchronizing: return text("synchronization_full_sync_title", "ntp_server_status_full_sum")
        case .fullSynchronizationWaitsForNetwork(.mobileDataOff): return text("synchronization_full_sync_title", "ntp_server_status_full_wifi_sum")
        case .fullSynchronizationWaitsForNetwork(.offline): return text("synchronization_full_sync_title", "ntp_server_status_full_offline_sum")
        }
    }

    /// A change a server library refused to record, in plain words (PROTOCOL §6.13): a queue too long to sort, a change too
    /// large, a history or statistics cut that would leave out listening the server refused. Nil for any other error.
    static func refusal(_ error: any Error) -> String? {
        switch error as? ServerRecordingError {
        case .factTooLarge(let type, _)?:
            return Appearance.text(type == "queue.reorder" ? "ntp_server_sort_too_large" : "ntp_server_change_too_large")
        case .cutBlockedByRefusedListening(let intent)?:
            return Appearance.text(intent == "statisticsReset" ? "ntp_server_statistics_blocked" : "ntp_server_history_blocked")
        default:
            return nil
        }
    }

    /// Sign-in and account errors in plain words (PROTOCOL §15.5). Never a server's own text: it could echo what was sent.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as ServerClientError:
            switch error {
            case .invalidAddress: return URLError(.badURL).localizedDescription
            case .unreachable: return Appearance.text("ntp_server_error_unreachable")
            case .notAServer: return Appearance.text("ntp_server_error_not_server")
            case .serverNeedsUpdate: return Appearance.text("ntp_server_status_server_update_title")
            case .appNeedsUpdate: return Appearance.text("ntp_server_status_app_update_title")
            case .wrongCredentials, .unauthorized: return Appearance.text("ntp_server_error_credentials")
            case .forbidden: return Appearance.text("ntp_server_error_disabled")
            case .rateLimited(let wait):
                guard let wait else { return Appearance.text("ntp_server_error_rate_limited_later") }
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("jm")
                return String(format: Appearance.text("ntp_server_error_rate_limited"),
                              formatter.string(from: Date().addingTimeInterval(TimeInterval(wait) + 59)))
            case .busy: return Appearance.text("ntp_server_error_busy")
            case .installationConflict, .installationSuperseded, .viewExpired, .server:
                return Appearance.text("sync_status_error")
            }
        case ServerAccountError.differentAccount: return Appearance.text("ntp_server_error_other_account")
        default: return Appearance.text("sync_status_error")
        }
    }
}
