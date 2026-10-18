import UIKit
import NotTennaPodCore

// The NotTennaPod server on Settings → Synchronization (PROTOCOL §15.4): sign-in, the attachment
// confirmations, sign in again, logout, and the server libraries kept on this device.
extension LibraryViewController {
    /// The scene this screen is in, so a switch it asks for reopens the page here.
    private var sceneIdentifier: String? { view.window?.windowScene?.session.persistentIdentifier }

    func performServerAction(_ action: SynchronizationSettingsView.Action, page: ServerSynchronizationPage?,
                             presentation: SynchronizationSettingsPresentation) {
        guard let server = presentation.server else { return }
        switch action {
        case .serverPassword: showServerPassword(server)
        case .keptLibraries: showKeptServerLibraries(presentation)
        case .previousLibrary(let id): showPreviousLibrary(id, page: page, server: server)
        case .logout:
            // In server mode Logout asks which library this phone uses afterwards (PROTOCOL §15.5).
            if page?.mode == .server { showLogoutChoice(server); return }
            logout(server, choice: .goBack)
        // "Synchronize now" pushes, then pulls; "Force full synchronization" reprojects every row from the server's
        // library (PROTOCOL §6.14). The page shows the outcome in its status line as the exchange reports it.
        case .synchronize:
            guard let sync = (UIApplication.shared.delegate as? AppDelegate)?.serverSync else { return }
            Task { await sync.synchronizeNow() }
        // It downloads the whole library again: the person is told so, with its estimated size, and confirms first.
        case .full:
            guard let sync = (UIApplication.shared.delegate as? AppDelegate)?.serverSync, presentedViewController == nil else { return }
            Task { [weak self] in
                let estimate = await sync.fullSynchronizationEstimate()
                guard let self, self.presentedViewController == nil else { return }
                messages.present(ServerSynchronizationDialogs.fullSynchronization(estimate: estimate) {
                    Task { await sync.forceFullSynchronization() }
                })
            }
        // A switch or Keep waiting for playback goes ahead: playback stops, a resumption after an interruption
        // included; applied at once, the page reopens here after the restart.
        case .stopPlayback:
            let scene = sceneIdentifier
            Task { await server.stopPlaybackAndContinue(scene: scene) }
        // "Start over with the server's library" (PROTOCOL §6.11 `lineage_unknown`): signing in to the server's library begins a
        // first attachment; this library is kept, inactive, with its changes.
        case .startOver:
            guard let library = page?.library else { return }
            showServerSignIn(presentation, address: library.address, username: library.entry.username, startOver: true)
        // The Synchronization log and Needs attention open their screens (PROTOCOL §15.5); an incomplete recovery's status row,
        // which says "See the synchronization log", opens the log too.
        case .log: openSettingsPage(.synchronizationLog)
        case .attention: openSettingsPage(.synchronizationAttention)
        case .choose, .password: break
        }
    }

    private func logout(_ server: ServerAccounts, choice: ServerLogoutChoice) {
        let scene = sceneIdentifier
        Task { [weak self] in
            do {
                try await server.logout(choice, scene: scene)
                self?.showEpisodeActionMessage(Appearance.text("pref_synchronization_logout_toast"))
            } catch { self?.showServerError(error) }
        }
    }

    /// "Logout": "Keep using this library", "Go back to the library from before you signed in", "Cancel"; with changes
    /// the server has not confirmed, the message says how many and what each choice does with them (PROTOCOL §15.4).
    func showLogoutChoice(_ server: ServerAccounts) {
        guard presentedViewController == nil else { return }
        Task { [weak self] in
            let unconfirmed = await server.unconfirmedChanges()
            guard let self, self.presentedViewController == nil else { return }
            messages.present(ServerSynchronizationDialogs.logout(unconfirmed: unconfirmed) { [weak self] choice in
                self?.logout(server, choice: choice)
            })
        }
    }

    // MARK: - Previous libraries (PROTOCOL §15.4)

    /// A previous library's row: its exports and "Remove library".
    func showPreviousLibrary(_ id: String, page: ServerSynchronizationPage?, server: ServerAccounts) {
        guard presentedViewController == nil, let library = page?.previousLibraries.first(where: { $0.id == id }) else { return }
        let title = SynchronizationSettingsView.previousLibraryLabels(page?.previousLibraries ?? [])[id]
        messages.present(ServerSynchronizationDialogs.previousLibrary(title: title, export: { [weak self] in
            self?.showPreviousLibraryExports(library)
        }, remove: { [weak self] in
            self?.confirmPreviousLibraryRemoval(library, title: title, server: server)
        }))
    }

    /// The four exports of a previous library (PROTOCOL §11.5): database, OPML, HTML and favorites HTML.
    private func showPreviousLibraryExports(_ library: LibraryRegistry.PreviousLibrary) {
        guard presentedViewController == nil else { return }
        messages.present(ServerSynchronizationDialogs.previousLibraryExports { [weak self] kind in
            self?.beginExport(kind, identity: library.identity)
        })
    }

    private func confirmPreviousLibraryRemoval(_ library: LibraryRegistry.PreviousLibrary, title: String?, server: ServerAccounts) {
        messages.present(ServerSynchronizationDialogs.previousLibraryRemoval(title: title) {
            Task { [weak self] in
                do { try await server.removePreviousLibrary(library.id) } catch { self?.showServerError(error) }
            }
        })
    }

    func showServerError(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        messages.present(SourceMessageController(message: ServerSynchronizationText.message(for: error)))
    }

    // MARK: - Sign-in and attachment

    /// `startOver`: the sign-in of "Start over with the server's library" (PROTOCOL §6.11 `lineage_unknown`).
    /// `library`: a kept library's own "Log in" (that library resumes if the account is its own).
    func showServerSignIn(_ presentation: SynchronizationSettingsPresentation, address: ServerAddress? = nil, username: String? = nil,
                          library: String? = nil, startOver: Bool = false) {
        guard let server = presentation.server, presentedViewController == nil else { return }
        let flow = ServerSignInFlow(accounts: server, address: address, username: username, library: library)
        present(ServerAuthenticationController(flow: flow) { [weak self] pending in
            self?.confirmServerSignIn(pending, server: server, startOver: startOver)
        }, animated: true)
    }

    /// The attachment confirmation, normal or resume (PROTOCOL §15.5): Confirm stores the sign-in, Cancel signs out. Starting over,
    /// Confirm makes this library inactive and attaches to the server's library.
    private func confirmServerSignIn(_ pending: ServerPendingSignIn, server: ServerAccounts, startOver: Bool = false) {
        let resume: Bool = if case .resume = pending.kind { true } else { false }
        let message = resume ? Appearance.text("ntp_server_resume_message")
            : String(format: Appearance.text("ntp_server_use_library_message"), pending.address.string)
        let dialog = SourceMessageController(title: Appearance.text("ntp_server_use_library_title"), message: message,
            positive: .init(title: Appearance.text("confirm_label"), identifier: "serverAttachConfirm", perform: { [weak self] in
                let scene = self?.sceneIdentifier
                Task { [weak self] in
                    do {
                        if resume { try await server.confirmResume(pending, scene: scene) }
                        else if startOver { try await server.startOver(pending, scene: scene) }
                        else { try await server.beginAttachment(pending, scene: scene) }
                    } catch { self?.showServerError(error) }
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "serverAttachCancel", perform: {
                Task { await server.discard(pending) }
            }, performAfterDismiss: true))
        dialog.allowsImplicitCancellation = false
        messages.present(dialog)
        server.onFailure = { [weak self] error in self?.showServerError(error) }
    }

    /// The empty-account question (PROTOCOL §15.5), asked while the page is visible.
    func presentServerQuestionIfNeeded(_ presentation: SynchronizationSettingsPresentation) {
        guard let server = presentation.server, case .emptyAccount? = server.question,
              presentedViewController == nil, !presentation.asksQuestion else { return }
        presentation.asksQuestion = true
        let dialog = SourceMessageController(title: Appearance.text("ntp_server_use_library_title"),
            message: Appearance.text("ntp_server_empty_account_message"),
            positive: .init(title: Appearance.text("ntp_server_use_empty_library"), identifier: "serverUseEmptyLibrary", perform: { [weak self, weak presentation] in
                let scene = self?.sceneIdentifier
                Task { await server.confirmEmptyAccount(scene: scene); presentation?.asksQuestion = false }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "serverEmptyCancel", perform: { [weak self, weak presentation] in
                Task { [weak self] in
                    do { try await server.logout(scene: nil) } catch { self?.showServerError(error) }
                    presentation?.asksQuestion = false
                }
            }, performAfterDismiss: true))
        dialog.allowsImplicitCancellation = false
        messages.present(dialog)
    }

    // MARK: - Sign in again, change login information

    /// Android's "Change login information" dialog: the username shown, the password entered again (PROTOCOL §15.4).
    func showServerPassword(_ server: ServerAccounts) {
        guard presentedViewController == nil, let library = server.page(otherProvider: false).library else { return }
        let body = FeedAuthenticationBody(credentials: .init(username: library.entry.username, password: ""))
        body.username.isEnabled = false
        let dialog = SourceMessageController(title: Appearance.text("pref_gpodnet_setlogin_information_title"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "serverPasswordConfirm", perform: { [weak self] in
                let password = body.password.text ?? ""
                body.password.text = ""
                Task { [weak self] in
                    do { try await server.signInAgain(password: password) } catch { self?.showServerError(error) }
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "serverPasswordCancel"), customBody: body)
        dialog.avoidsKeyboard = true
        present(dialog, animated: true)
    }

    // MARK: - Server libraries on this device

    func showKeptServerLibraries(_ presentation: SynchronizationSettingsPresentation) {
        guard let server = presentation.server, presentedViewController == nil else { return }
        let libraries = server.page(otherProvider: presentation.saved.account != nil).keptLibraries
        guard !libraries.isEmpty else { return }
        let body = KeptServerLibrariesBody(libraries: libraries)
        let dialog = SourceMessageController(title: Appearance.text("ntp_server_libraries_title"), message: "",
            positive: .init(title: Appearance.text("close_label"), identifier: "keptLibrariesClose"), customBody: body)
        body.onLogin = { [weak self, weak dialog] library in
            dialog?.dismiss(animated: true) { [weak self] in
                self?.showServerSignIn(presentation, address: library.address, username: library.entry.username, library: library.entry.id)
            }
        }
        body.onRemove = { [weak self, weak dialog] library in
            dialog?.dismiss(animated: true) { [weak self] in self?.confirmKeptLibraryRemoval(library, server: server) }
        }
        present(dialog, animated: true)
    }

    private func confirmKeptLibraryRemoval(_ library: ServerLibrarySummary, server: ServerAccounts) {
        var message = Appearance.text("ntp_server_remove_library_message")
        if library.unsentChanges > 0 { message += " " + Appearance.plural("ntp_server_remove_library_unsent", library.unsentChanges) }
        let dialog = SourceMessageController(title: KeptServerLibrariesBody.name(library), message: message,
            positive: .init(title: Appearance.text("ntp_server_remove_library"), identifier: "keptLibraryRemoveConfirm", perform: { [weak self] in
                Task { [weak self] in
                    do { try await server.removeKeptLibrary(library.entry.id) } catch { self?.showServerError(error) }
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "keptLibraryRemoveCancel"))
        messages.present(dialog)
    }

    // MARK: - After a switch

    /// Called by the scene for every new root screen: a switch the Synchronization page asked for in this scene, and
    /// that was applied at once, reopens that page (a switch applied later, at a pause or at launch, opens nothing).
    func reopenSynchronizationAfterSwitchIfNeeded(scene: String) {
        guard let accounts = (UIApplication.shared.delegate as? AppDelegate)?.serverAccounts,
              let switching = accounts.interactiveSwitch, switching.scene == scene else { return }
        // "Stop playback and continue" finishes a logout announced when it was made: no second toast.
        let reason = accounts.interactiveSwitchContinues ? nil : switching.reason
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            push(.settings(.main))
            openSettingsPage(.synchronization)
            if reason == .logout { showEpisodeActionMessage(Appearance.text("pref_synchronization_logout_toast")) }
        }
    }
}

/// The kept server libraries, each with "Log in" and "Remove library" (PROTOCOL §15.5).
@MainActor final class KeptServerLibrariesBody: UIView {
    var onLogin: ((ServerLibrarySummary) -> Void)?
    var onRemove: ((ServerLibrarySummary) -> Void)?
    private let stack = UIStackView()
    private var labels: [(UILabel, CGFloat, Bool)] = []

    static func name(_ library: ServerLibrarySummary) -> String {
        String(format: Appearance.text("ntp_server_library_account"), library.entry.username,
               library.address?.host ?? library.entry.serverURL)
    }

    init(libraries: [ServerLibrarySummary]) {
        super.init(frame: .zero)
        accessibilityIdentifier = "keptLibraries"
        stack.axis = .vertical; stack.alignment = .fill; stack.spacing = 0; addSubview(stack)
        for (index, library) in libraries.enumerated() {
            let title = Appearance.label(Self.name(library), size: 16)
            title.textColor = Appearance.foreground; title.accessibilityIdentifier = "keptLibrary-\(library.entry.id)"
            labels.append((title, 16, true)); stack.addArrangedSubview(title)
            var details: [String] = []
            if library.unsentChanges > 0 { details.append(Appearance.plural("ntp_server_unsent_changes", library.unsentChanges)) }
            if let last = library.lastSynchronization {
                details.append(String(format: Appearance.text("ntp_server_last_synchronized"),
                                      SynchronizationStatusDateFormatter.string(from: last.date)))
            }
            if !details.isEmpty {
                let detail = Appearance.label(details.joined(separator: "\n"), size: 14)
                detail.textColor = Appearance.secondary; detail.accessibilityIdentifier = "keptLibraryDetails-\(library.entry.id)"
                labels.append((detail, 14, false)); stack.addArrangedSubview(detail)
            }
            let login = button("synchronization_login_butLabel", identifier: "keptLibraryLogin-\(library.entry.id)") { [weak self] in
                self?.onLogin?(library)
            }
            let remove = button("ntp_server_remove_library", identifier: "keptLibraryRemove-\(library.entry.id)") { [weak self] in
                self?.onRemove?(library)
            }
            let actions = UIStackView(arrangedSubviews: [UIView(), remove, login])
            actions.axis = .horizontal; actions.spacing = 8; actions.alignment = .center
            stack.addArrangedSubview(actions)
            if index < libraries.count - 1 { stack.setCustomSpacing(16, after: actions) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The dialog's own text-button style.
    private func button(_ key: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = Appearance.text(key)
        configuration.baseForegroundColor = Appearance.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            let font = Appearance.font(14, medium: true, compatibleWith: button.traitCollection)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = font; return result
            }
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        for (label, size, medium) in labels { label.font = Appearance.font(size, medium: medium, compatibleWith: traitCollection) }
        let content = stack.systemLayoutSizeFitting(CGSize(width: max(0, size.width - 48), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: size.width, height: content.height + 16)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (label, size, medium) in labels { label.font = Appearance.font(size, medium: medium, compatibleWith: traitCollection) }
        stack.frame = bounds.inset(by: UIEdgeInsets(top: 8, left: min(24, bounds.width / 2), bottom: 8, right: min(24, bounds.width / 2)))
    }
}

/// The dialogs of a Keep at logout, previous libraries and the export choice (PROTOCOL §15.5), built in one place so the page and
/// its view tests show the same composition.
@MainActor enum ServerSynchronizationDialogs {
    /// "Logout": the question, with the changes the server has not confirmed when there are any;
    /// "Keep using this library", "Go back to the library from before you signed in" and "Cancel", stacked in that
    /// order when they do not fit side by side.
    static func logout(unconfirmed: Int, choose: @escaping (ServerLogoutChoice) -> Void) -> SourceMessageController {
        var message = Appearance.text("ntp_server_logout_message")
        if unconfirmed > 0 { message += "\n\n" + Appearance.plural("ntp_server_logout_unconfirmed", unconfirmed) }
        return SourceMessageController(title: Appearance.text("synchronization_logout"), message: message,
            positive: .init(title: Appearance.text("ntp_server_logout_keep"), identifier: "serverLogoutKeep", perform: { choose(.keep) },
                            performAfterDismiss: true),
            negative: .init(title: Appearance.text("ntp_server_logout_go_back"), identifier: "serverLogoutGoBack", perform: { choose(.goBack) },
                            performAfterDismiss: true),
            neutral: .init(title: Appearance.text("cancel_label"), identifier: "serverLogoutCancel"))
    }

    /// "Export which library?": the server's library (with its account and host), this phone's
    /// own library, and Cancel. `select` gets 0 for the server's library, 1 for this phone's.
    static func exportChoice(serverSummary: String, select: @escaping (Int) -> Void) -> SourceMessageController {
        let body = ExportLibraryChoices(choices: [
            (Appearance.text("ntp_server_export_server_library"), serverSummary, "exportServerLibrary"),
            (Appearance.text("ntp_server_export_own_library"), nil, "exportOwnLibrary"),
        ])
        let dialog = SourceMessageController(title: Appearance.text("ntp_server_export_which_title"), message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "exportChoiceCancel"), customBody: body)
        body.onSelect = { [weak dialog] index in dialog?.dismiss(animated: true) { select(index) } }
        return dialog
    }

    /// A previous library's row: its label as the title, "Export" and "Remove library" as the dialog's items, and Cancel.
    static func previousLibrary(title: String?, export: @escaping () -> Void, remove: @escaping () -> Void) -> SourceMessageController {
        let body = ExportLibraryChoices(choices: [
            (Appearance.text("ntp_server_previous_library_export"), nil, "previousLibraryExport"),
            (Appearance.text("ntp_server_remove_library"), nil, "previousLibraryRemove"),
        ])
        let dialog = SourceMessageController(title: title, message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "previousLibraryCancel"), customBody: body)
        body.onSelect = { [weak dialog] index in dialog?.dismiss(animated: true) { index == 0 ? export() : remove() } }
        return dialog
    }

    /// The four exports of a previous library.
    static func previousLibraryExports(select: @escaping (LibraryExportKind) -> Void) -> SourceMessageController {
        let kinds = LibraryExportKind.allCases
        let body = ExportLibraryChoices(choices: kinds.map { (Appearance.text($0.titleKey), nil, "previousLibraryExport-\($0)") })
        let dialog = SourceMessageController(title: Appearance.text("ntp_server_previous_library_export"), message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "previousLibraryExportCancel"), customBody: body)
        body.onSelect = { [weak dialog] index in dialog?.dismiss(animated: true) { select(kinds[index]) } }
        return dialog
    }

    /// "Force full synchronization": "This downloads your whole library from the server again (estimated %@). Continue?"
    /// (without the size when none is known), Cancel and OK.
    static func fullSynchronization(estimate: Int64?, confirm: @escaping () -> Void) -> SourceMessageController {
        let message = estimate.flatMap { $0 > 0 ? $0 : nil }.map {
            String(format: Appearance.text("ntp_server_full_confirm_estimate"), EpisodeRowPresentation.fileSize($0))
        } ?? Appearance.text("ntp_server_full_confirm")
        return SourceMessageController(title: Appearance.text("synchronization_full_sync_title"), message: message,
            positive: .init(title: Appearance.text("ok"), identifier: "fullSynchronizationConfirm", perform: confirm, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "fullSynchronizationCancel"))
    }

    /// "Remove this library from this device? Its library data and downloads will be deleted."
    static func previousLibraryRemoval(title: String?, remove: @escaping () -> Void) -> SourceMessageController {
        SourceMessageController(title: title, message: Appearance.text("ntp_server_remove_previous_library_message"),
            positive: .init(title: Appearance.text("ntp_server_remove_library"), identifier: "previousLibraryRemoveConfirm", perform: remove,
                            performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "previousLibraryRemoveCancel"))
    }
}
