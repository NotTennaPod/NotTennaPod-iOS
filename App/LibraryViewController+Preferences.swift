import UIKit
import NotTennaPodCore

// Settings screens: global download preferences, the settings list, synchronization and Nextcloud.
extension LibraryViewController {
    private func showGlobalDownloadPreference(_ key: String) {
        if ["prefHardwareForwardButton", "prefHardwarePreviousButton"].contains(key), let owner = playbackHardwarePreferences {
            let forward = key == "prefHardwareForwardButton"
            let choices = PlaybackHardwareAction.allCases
            let selected = forward ? owner.value.forward : owner.value.previous
            present(SourceSingleChoiceController(title: Appearance.text(forward ? "pref_hardware_forward_button_title" : "pref_hardware_previous_button_title"),
                identifier: key, choices: choices.map { ($0.rawValue, Appearance.text($0.titleKey)) },
                selectedIndex: choices.firstIndex(of: selected)) { index in
                    var value = owner.value
                    if forward { value.forward = choices[index] } else { value.previous = choices[index] }
                    try owner.update(value)
                }, animated: true)
            return
        }
        if key == NotificationButtonsDialog.identifier,
           let store = (UIApplication.shared.delegate as? AppDelegate)?.notificationButtonPreferences {
            present(NotificationButtonsDialog.make(store: store), animated: true)
            return
        }
        if key == "prefScreenSynchronization" { push(.settings(.synchronization)); return }
        // Playback → Playback speed opens the player's speed dialog (`PlaybackPreferencesFragment.java:41–44`).
        if key == "prefPlaybackSpeedLauncher" {
            if let playback, let speedPreferences { present(PlaybackSpeedController(playback: playback, preferences: speedPreferences), animated: true) }
            return
        }
        // Android 8+ opens the system per-channel screen here; iOS has no per-kind switches, so
        // Android's own Notifications screen opens instead.
        if key == "notifications" { push(.settings(.notifications)); return }
        if key == "prefProxy", let proxyPreferences {
            present(ProxySettingsController(preferences: proxyPreferences), animated: true)
            return
        }
        if let direction = PlaybackIntervalDirection.allCases.first(where: { $0.preferenceKey == key }), let intervalPreferences {
            present(PlaybackIntervalController(direction: direction, preferences: intervalPreferences), animated: true)
            return
        }
        if key == "prefMobileUpdateTypes", let mobile = mobileNetworkPreferences {
            let uses: [MobileNetworkPreferenceStore.Use] = [.feedRefresh, .episodeDownload, .autoDownload, .streaming, .images, .sync]
            let titles = ["pref_mobileUpdate_refresh", "pref_mobileUpdate_episode_download", "pref_automatic_download_title",
                          "pref_mobileUpdate_streaming", "pref_mobileUpdate_images", "synchronization_pref"]
            present(SourceSingleChoiceController(title: Appearance.text("pref_mobileUpdate_title"), identifier: key,
                choices: zip(uses, titles).map { ($0.0.rawValue, Appearance.text($0.1)) }, selectedIndex: nil,
                selectedIndices: Set(uses.indices.filter { mobile.allows(uses[$0]) }), onConfirm: { selected in
                    try mobile.updateAllowed(Set(selected.map { uses[$0].rawValue }))
                }, onSelect: { _ in }), animated: true)
            return
        }
        if key == "prefEnqueueLocation", downloadPreferences != nil {
            // MaterialListPreference: tapping a choice saves it and closes; Cancel keeps the old value.
            let choices = EnqueueLocation.allCases, policy = accountPolicy
            present(SourceSingleChoiceController(title: Appearance.text("pref_enqueue_location_title"), identifier: key,
                choices: choices.map { ($0.rawValue, Appearance.text($0.titleKey)) },
                selectedIndex: choices.firstIndex(of: policy.enqueueLocation)) { [weak self] index in
                    try policy.setEnqueueLocation(choices[index])
                    self?.applyQueueInsertionSettings()
                    self?.render()
                }, animated: true)
            return
        }
        guard let downloads = downloadPreferences, let automatic = automaticDownloadPreferences else { return }
        if key == "prefAutoDeleteLocal" {
            present(SourceMessageController(message: Appearance.text("pref_auto_local_delete_dialog_body"),
                positive: .init(title: Appearance.text("yes"), identifier: "confirmAutoDeleteLocal", perform: { [weak self] in
                    do { var value = downloads.value; value.autoDeleteLocal = true; try downloads.update(value); self?.render() }
                    catch { self?.showError(error) }
                }, performAfterDismiss: true), negative: .init(title: Appearance.text("cancel_label"), identifier: "cancelAutoDeleteLocal")), animated: true)
            return
        }
        let values: [Int], labels: [String], titleKey: String, current: Int
        switch key {
        case "prefAutoUpdateIntervall":
            values = PeriodicFeedRefreshSchedule.intervals
            labels = ["feed_refresh_never", "feed_every_hour", "feed_every_2_hours", "feed_every_4_hours",
                      "feed_every_8_hours", "feed_every_12_hours", "feed_every_24_hours", "feed_every_72_hours"].map(Appearance.text)
            titleKey = "feed_refresh_title"; current = downloads.value.refreshIntervalMinutes ?? PeriodicFeedRefreshSchedule.defaultInterval
        case "prefNewEpisodesAction":
            let actions: [NewEpisodesAction] = [.inbox, .queue, .nothing]
            values = actions.map(\.rawValue); labels = actions.map { Appearance.text($0.titleKey) }
            titleKey = "pref_new_episodes_action_title"; current = accountPolicy.newEpisodesAction.rawValue
        case "prefEpisodeCacheSize":
            values = [5, 10, 25, 50, 100, 500, -1]
            labels = values.map { $0 == -1 ? Appearance.text("pref_episode_cache_unlimited") : String($0) }
            titleKey = "pref_episode_cache_title"; current = automatic.value.cacheSize
        case "prefEpisodeCleanup":
            values = [-3, -1, 0, 12, 24, 72, 120, 168, -2]
            labels = values.map { value in
                switch value {
                case -3: Appearance.text("episode_cleanup_except_favorite_removal")
                case -1: Appearance.text("episode_cleanup_queue_removal")
                case -2: Appearance.text("episode_cleanup_never")
                case 0: Appearance.text("episode_cleanup_after_listening")
                case 12: Appearance.plural("episode_cleanup_hours_after_listening", value)
                default: Appearance.plural("episode_cleanup_days_after_listening", value/24)
                }
            }
            titleKey = "pref_episode_cleanup_title"; current = automatic.value.cleanup
        case "prefSmartMarkAsPlayedSecs":
            values = [0, 15, 30, 60, 120, 300, 600]
            labels = values.map { value in
                value == 0 ? Appearance.text("pref_smart_mark_as_played_disabled")
                    : value < 60 ? Appearance.plural("time_seconds_quantified", value) : Appearance.plural("time_minutes_quantified", value/60)
            }
            titleKey = "pref_smart_mark_as_played_title"; current = Int(downloads.value.smartMarkAsPlayedSeconds ?? 30)
        default: return
        }
        let policy = accountPolicy
        present(SourceSingleChoiceController(title: Appearance.text(titleKey), identifier: key,
            choices: zip(values, labels).map { (String($0.0), $0.1) }, selectedIndex: values.firstIndex(of: current)) { index in
                if key == "prefAutoUpdateIntervall" {
                    var value = downloads.value; value.refreshIntervalMinutes = values[index]; try downloads.update(value)
                } else if key == "prefNewEpisodesAction" {
                    if let action = NewEpisodesAction(rawValue: values[index]) { try policy.setNewEpisodesAction(action) }
                } else if key == "prefSmartMarkAsPlayedSecs" {
                    var value = downloads.value; value.smartMarkAsPlayedSeconds = Int32(values[index]); try downloads.update(value)
                } else {
                    var value = automatic.value
                    if key == "prefEpisodeCacheSize" { value.cacheSize = values[index] } else { value.cleanup = values[index] }
                    try automatic.update(value)
                }
            }, animated: true)
    }

    func renderPreferences(_ page: SettingsPage) {
        if page == .about || page == .licenses {
            let shell: UIView
            if page == .about {
                let about = AboutSettingsView(width: content.bounds.width)
                // AboutFragment: a tap on Version copies it (Android 13+ confirms by itself; older versions show a Snackbar).
                about.onCopyVersion = { [weak self] version in
                    UIPasteboard.general.string = version
                    self?.showNotice(Appearance.text("copied_to_clipboard"))
                }
                about.onOpenLicenses = { [weak self] in self?.openSettingsPage(.licenses) }
                shell = about
            } else {
                shell = LicensesSettingsView(width: content.bounds.width)
            }
            content.addSubview(shell)
            content.contentSize = CGSize(width: shell.bounds.width, height: max(content.bounds.height, shell.bounds.height))
            return
        }
        if page == .importExport {
            // While a server library is active, each export first asks which library (PROTOCOL §11.5).
            let export: (() -> Void)? = library == nil ? nil : { [weak self] in self?.beginLibraryExport(.opml) }
            let database: (() -> Void)? = library == nil ? nil : { [weak self] in self?.beginLibraryExport(.database) }
            let restore: (() -> Void)? = importDatabase == nil ? nil : { [weak self] in self?.databaseImportFlow.begin() }
            let shell = BackupRestoreView(importAction: { [weak self] in self?.opmlImportFlow?.chooseDocument() }, exportAction: export,
                                          databaseExportAction: database, databaseImportAction: restore,
                                          htmlExportAction: library == nil ? nil : { [weak self] in self?.beginLibraryExport(.html) },
                                          favoritesExportAction: library == nil ? nil : { [weak self] in self?.beginLibraryExport(.favorites) },
                                          automaticExport: automaticBackup.map { runtime in .init(isOn: runtime.isEnabled, toggle: { [weak self] in self?.toggleAutomaticBackup() }) })
            content.addSubview(shell)
            shell.frame = CGRect(origin: .zero, size: shell.sizeThatFits(content.bounds.size))
            content.contentSize = CGSize(width: shell.bounds.width, height: max(content.bounds.height, shell.bounds.height))
            return
        }

        if page == .synchronization, let synchronizationSettings {
            renderSynchronizationSettings(synchronizationSettings)
            return
        }
        if page == .synchronizationLog { renderServerSyncLog(); return }
        if page == .synchronizationAttention { renderServerAttention(); return }
        if page == .notifications {
            renderNotificationSettings()
            return
        }
        let preferences = NavigationSettingsView(navigation: navigationPreferences, timeDisplay: timeDisplayPreferences,
            page: page, width: content.bounds.width, downloads: downloadPreferences, accountPolicy: accountPolicy, automatic: automaticDownloadPreferences,
            playbackQueue: playbackQueuePreferences, playbackHardware: playbackHardwarePreferences, interface: interfacePreferences)
        preferences.onInterfaceChange = { InterfaceTheme.applyEverywhere($0) }
        preferences.onPreferenceAction = { [weak self] key in
            // The Settings root's search card opens the search page.
            if key == "searchPreference" { self?.openSettingsSearch(); return }
            if key == "prefHiddenDrawerItems" { self?.showNavigationCustomization(); return }
            if key == "prefDefaultPage" {
                if let owner = self?.navigationPreferences { self?.present(DefaultPageController(preferences: owner), animated: true) }
                return
            }
            if key == "prefGlobalDefaultSortedOrder" { self?.showGlobalFeedSort(); return }
            // Settings → Swipe actions: every row opens its screen's dialog (`SwipePreferencesFragment`).
            if let row = SwipeActionsSettingsRow(rawValue: key) {
                if let screen = row.screen { self?.showInboxSwipeSettings(screen) } else { self?.showDownloadsSwipeSettings() }
                return
            }
            self?.showGlobalDownloadPreference(key)
        }
        preferences.onChange = { [weak self] in self?.render() }
        preferences.onNavigate = { [weak self] page in self?.openSettingsPage(page) }
        preferences.onMessage = { [weak self] message in self?.present(SourceMessageController(message: message), animated: true) }
        preferences.onFailure = { [weak self] error in self?.showError(error) }
        content.addSubview(preferences)
        preferences.frame.origin = .zero
        content.contentSize = preferences.bounds.size
    }

    /// Opens a settings page, preparing the stored defaults the Downloads and Automatic download pages show.
    func openSettingsPage(_ page: SettingsPage) {
        do {
            try prepareSettingsPage(page)
            push(.settings(page))
        } catch { showError(error) }
    }

    /// What opening a settings page prepares (also for a page restored with its scene).
    func prepareSettingsPage(_ page: SettingsPage) throws {
        if page == .downloads { try mobileNetworkPreferences?.initializeSettingsDefaults() }
        if page == .synchronization { synchronizationSettings?.server?.pageOpened() }
        if page == .automaticDownload, let owner = automaticDownloadPreferences {
            var value = owner.value; value.initializeSettingsDefaults(); try owner.update(value)
        }
    }

    private func renderSynchronizationSettings(_ presentation: SynchronizationSettingsPresentation) {
        let serverPage = presentation.serverPage
        let settings = SynchronizationSettingsView(state: presentation.saved, server: serverPage, width: content.bounds.width)
        let state = presentation.saved
        settings.onAction = { [weak self, weak presentation] action in
            guard let self, let presentation else { return }
            if let serverPage, !serverPage.showsOrdinaryRows {
                performServerAction(action, page: serverPage, presentation: presentation)
                return
            }
            switch action {
            case .serverPassword, .startOver, .log, .attention, .keptLibraries, .previousLibrary, .stopPlayback:
                performServerAction(action, page: serverPage, presentation: presentation)
            case .choose:
                // While keeping a library at logout, the provider choice opens only once the Keep has finished (PROTOCOL §15.5).
                guard serverPage?.providerChoiceBlocked != true else { return }
                showSynchronizationProviders(presentation)
            case .password:
                guard let account = state.account else { return }
                let body = FeedAuthenticationBody(credentials: .init(username: account.username, password: ""))
                body.username.isEnabled = false
                let dialog = SourceMessageController(title: Appearance.text("pref_gpodnet_setlogin_information_title"), message: "",
                    positive: .init(title: Appearance.text("confirm_label"), identifier: "syncPasswordConfirm", perform: { [weak self] in
                        let password = body.password.text ?? ""
                        body.password.text = ""
                        Task { [weak self] in
                            do { try await presentation.changePassword(password, accountID: account.id) }
                            catch is CancellationError { }
                            catch { self?.showError(error) }
                        }
                    }, performAfterDismiss: true),
                    negative: .init(title: Appearance.text("cancel_label"), identifier: "syncPasswordCancel"), customBody: body)
                dialog.avoidsKeyboard = true
                present(dialog, animated: true)
            case .synchronize, .full:
                Task { [weak self] in
                    do { try await presentation.synchronize(full: action == .full, epoch: state.epoch) }
                    catch is CancellationError { }
                    catch { self?.showError(error) }
                }
            case .logout:
                guard let account = state.account else { return }
                Task { [weak self] in
                    do {
                        try await presentation.logout(accountID: account.id)
                        self?.showEpisodeActionMessage(Appearance.text("pref_synchronization_logout_toast"))
                    } catch is CancellationError { }
                    catch { self?.showError(error) }
                }
            }
        }
        content.addSubview(settings); content.contentSize = settings.bounds.size
        presentServerQuestionIfNeeded(presentation)
    }

    private func showSynchronizationProviders(_ presentation: SynchronizationSettingsPresentation) {
        guard presentedViewController == nil else { return }
        let choices = SynchronizationProviderChoices(frame: .zero)
        let dialog = SourceMessageController(title: Appearance.text("dialog_choose_sync_service_title"), message: "",
            positive: .init(title: "", identifier: "syncProviderUnused"), customBody: choices)
        dialog.updateAction(identifier: "syncProviderUnused", title: "", isEnabled: false, isHidden: true)
        choices.onSelectServer = { [weak self, weak dialog] in
            dialog?.dismiss(animated: true) { [weak self] in self?.showServerSignIn(presentation) }
        }
        choices.onSelect = { [weak self, weak dialog] backend in
            dialog?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                switch backend {
                case .gpodder:
                    // Device class is only a default caption; it never selects a layout.
                    let model = self.traitCollection.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
                    let flow = GpodderAuthenticationFlow(accounts: presentation.accounts, deviceModel: model)
                    self.present(GpodderAuthenticationController(flow: flow, onSync: { [weak self] in
                        guard let epoch = flow.connectedEpoch else { return }
                        Task { [weak self] in
                            do { try await presentation.synchronize(epoch: epoch) }
                            catch is CancellationError { }
                            catch { self?.showError(error) }
                        }
                    }), animated: true)
                case .nextcloud:
                    self.showNextcloudAuthorization(presentation)
                }
            }
        }
        present(dialog, animated: true)
    }

    private func showNextcloudAuthorization(_ presentation: SynchronizationSettingsPresentation,
                                            restoring session: NextcloudAuthenticationSession? = nil) {
        let flow = NextcloudAuthenticationFlow(accounts: presentation.accounts) { url in
            await UIApplication.shared.open(url)
        }
        let dialog = NextcloudAuthenticationController(flow: flow, restoring: session)
        dialog.onSessionChange = { [weak self, weak flow, weak dialog] session in
            guard let self, let flow else { return }
            // A start/resume request has no token yet. Keep a securely saved
            // session until a terminal outcome, rather than clearing it mid-resume.
            guard session != nil || !flow.busy else { return }
            do { try self.nextcloudRestoration?.update(session) }
            catch {
                dialog?.onSessionChange = nil
                flow.cancel()
                dialog?.dismiss(animated: true) { [weak self] in self?.showError(URLError(.cannotWriteToFile)) }
            }
        }
        present(dialog, animated: true)
    }

    func restoreNextcloudAuthorizationIfNeeded() {
        guard !recoveredNextcloudAuthorization, presentedViewController == nil,
              let restoration = nextcloudRestoration, let presentation = synchronizationSettings else { return }
        recoveredNextcloudAuthorization = true
        do {
            let session = try restoration.load()
            guard let session else { return }
            // The window's restored place may already be the Synchronization page: it is not opened twice.
            if case .settings(.synchronization) = path.last {} else {
                if case .settings(.main) = path.last {} else { push(.settings(.main)) }
                push(.settings(.synchronization))
            }
            showNextcloudAuthorization(presentation, restoring: session)
        } catch {
            // Corrupt/unreadable restoration must not open the same error on
            // every foreground transition or retain a token we cannot resume.
            try? restoration.clear()
            showError(URLError(.cannotOpenFile))
        }
    }
}
