import UIKit
import OSLog
import NotTennaPodCore

// Starting while data is still locked. iOS may launch the app before the first unlock after a restart: for a
// finished background download, or a widget or Control Center button. Protected files and Keychain items cannot be
// read then, so the graph's start waits for them (no alert, no empty library) and is tried again when protected data
// becomes available or a scene becomes active. Every start, retry and restart goes through `LibraryStartup`.

/// What follows a widget command, handed out of the dispatcher.
@MainActor private final class WidgetCommandFollowUp { var step: (@MainActor () async -> Void)? }

/// What a start that waited hands to the start that succeeded.
struct LibraryStartupHandoff {
    /// The system relaunched the app for background download events while the start waited: the downloads start once
    /// it succeeds, as they would have at launch.
    var backgroundEvents = false
    /// A start succeeded in this process: later starts are restarts (no launch fixtures run again).
    var hasStarted = false
    /// The widget's and the control's commands on the graph's player (`PlayerWidgetIntentRouter.bound`).
    var widgetCommands: PlayerWidgetIntentRouter.Commands?
}

extension AppDelegate {
    /// How long a widget or Control Center button pressed while the start waits stays pending: it runs if the library
    /// opens soon after (the person unlocks right away), never minutes later; its intent returns by then either way.
    static let pendingWidgetCommandLifetime: Duration = .seconds(30)

    func makeLibraryStartup() -> LibraryStartup {
        let startup = LibraryStartup(.init(build: { [weak self] in
            guard let self else { return }
            try startLibraryGraph(restart: startupHandoff.hasStarted)
        }, retire: { [weak self] in
            // Nothing reaches what a failed start built; widget buttons wait for the next start.
            self?.retireLibraryGraph()
        }, discard: { [weak self] in
            // The routes waiting for a screen are not the failed graph's: they stay for the start that succeeds.
            await self?.stopLibraryGraph(keepingPendingRoutes: true)
        }, protectedDataAvailable: {
            UIApplication.shared.isProtectedDataAvailable
        }, resolved: { [weak self] state, previous in
            self?.libraryStartupResolved(state, previous: previous)
        }, resumeParked: { [weak self] in
            self?.resumeParkedDownloads()
        }))
        PlayerWidgetIntentRouter.perform = Self.orderedWidgetRouter(startup: startup, lifetime: Self.pendingWidgetCommandLifetime) {
            [weak self] in self?.startupHandoff.widgetCommands
        }
        return startup
    }

    /// The first unlock after a restart (or any unlock): a start that waited for protected data is tried again; once
    /// started, downloads parked because they could not read their files are tried once more.
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        libraryStartup.protectedDataBecameAvailable()
    }

    /// The screen a scene shows while the library is not started: a wait while protected data is unavailable, or the
    /// error of a start that failed while it was available, over an empty library as before; nil once started.
    func libraryStartupRoot() -> UIViewController? {
        switch libraryStartup.presented {
        case .started: return nil
        case .failed:
            return LibraryViewController(library: nil, startupError: libraryStartup.failure, downloads: nil, playback: nil,
                                         timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
                                         mobileNetworkPreferences: nil, usage: nil)
        case .notStarted, .starting, .waitingForUnlock: return LibraryStartupWaitingController()
        }
    }

    /// Each download parked for access gets one new attempt, with background time while the app is in the background
    /// (adopting a finished download is work the person asked for).
    /// The event is recorded even with nothing parked: an attempt denied just before it, still unwinding, then gets its
    /// one new attempt too.
    private func resumeParkedDownloads() {
        guard let downloads else { return }
        let parked = !downloads.parkedForAccess.isEmpty
        downloads.resumeParked()
        if parked, UIApplication.shared.applicationState == .background { backgroundWork.enterBackground() }
    }

    /// The router of every widget and Control Center button: applied through the startup owner's one ordered
    /// dispatcher, in the order they arrived; before the start succeeds a button waits, at most `lifetime` (its intent
    /// then returns), and one whose intent was cancelled or whose time ran out is never applied. What follows a
    /// widget button (its settle wait, then the write) runs after it, outside the dispatcher, so a later button (a
    /// Control Center Pause after a widget Play) is never held behind it.
    static func orderedWidgetRouter(startup: LibraryStartup, lifetime: Duration,
                                    commands: @escaping @MainActor () -> PlayerWidgetIntentRouter.Commands?)
        -> @MainActor (PlayerWidgetCommand, PlayerWidgetIntentRouter.Source) async throws -> Void {
        { command, source in
            let followUp = WidgetCommandFollowUp()
            try await startup.runCommand(before: ContinuousClock.now.advanced(by: lifetime)) {
                followUp.step = try await commands()?(command, source)
            }
            await followUp.step?()
        }
    }

    /// After every attempt: the screens show the new state. A start that had not succeeded and now did does what an
    /// activation does with the library, so the work that arrived meanwhile runs once on the live screen; a failed
    /// start only shows its error, and that work waits for the next success.
    private func libraryStartupResolved(_ state: LibraryStartup.State, previous: LibraryStartup.State) {
        let log = Logger(subsystem: "org.nottennapod.app", category: "Libraries")
        switch state {
        case .started:
            startupHandoff.hasStarted = true
        case .waitingForUnlock:
            if previous != state { log.notice("The library waits until protected data is available") }
        case .failed:
            if previous != state { log.error("The library could not start") }
        case .notStarted, .starting: break
        }
        // Waiting again, or failed again: nothing new to show.
        if state == previous, state != .started { return }
        for scene in UIApplication.shared.connectedScenes {
            (scene.delegate as? SceneDelegate)?.installRoot(scene: scene)
        }
        // Launch and restarts after a switch or an import keep their own flow.
        guard state == .started, previous != .notStarted, previous != .started else { return }
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            (scene.delegate as? SceneDelegate)?.libraryBecameActive(scene)
        }
        // Live transfers name their libraries' current folders (a Keep may have finished during this start).
        Task { await BackgroundMediaDownloads.shared.normalizeLiveTasks() }
        if startupHandoff.backgroundEvents, let downloads {
            startupHandoff.backgroundEvents = false
            Task { [weak self] in
                try? await downloads.start()
                if UIApplication.shared.applicationState == .background { self?.backgroundWork.enterBackground() }
            }
        }
    }
}

/// While the library waits for protected data: the app's background with a spinner and "Please wait…", never an
/// error or an empty library. Replaced as soon as the start resolves, usually within a moment of unlocking.
@MainActor final class LibraryStartupWaitingController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = Appearance.label(Appearance.text("please_wait"), size: 16)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Appearance.background
        view.accessibilityIdentifier = "libraryStartupWaiting"
        spinner.color = Appearance.accent
        spinner.startAnimating()
        spinner.isAccessibilityElement = false
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = Appearance.font(16, compatibleWith: traitCollection)
        let stack = UIStackView(arrangedSubviews: [spinner, message])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
            guard let self else { return }
            message.font = Appearance.font(16, compatibleWith: traitCollection)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: message)
    }
}
