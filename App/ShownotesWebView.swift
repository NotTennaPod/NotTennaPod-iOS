import UIKit
import WebKit
import NotTennaPodCore

@MainActor
final class ShownotesWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    var showLinkMenu: ((String, ShownotesWebView) -> Void)?
    var shareSelection: ((String, ShownotesWebView) -> Void)?
    var openLink: ((String) -> Void)?
    var selectTimecode: ((Int32) -> Void)?
    var failure: ((Error) -> Void)?
    var restoreScrollOffset: (() -> CGFloat)?
    var willPerformTextService: (() -> Void)?
    private var documentGeneration = UUID()
    private var loaded: Content?
    private var renderedHTML: String?
    private struct Content: Equatable {
        let description: String?
        let duration: Int32
    }

    // iOS may end WebKit's content process at any time, mostly while the app is in the background. The notes are
    // then rebuilt from the held description when a person can see them, at the position they were read at.
    /// Automatic rebuilds per visit. A rebuild's own load never refills it, even one that ends right after finishing;
    /// a new visit (or Retry) does. After that the notes say they could not be displayed.
    static let recoveryLimit = 2
    private enum PendingLoad { case recovery, newContent }
    /// The document is gone with its process: it is rendered when the notes are shown in an active scene.
    private var pendingLoad: PendingLoad?
    private var recoveries = 0
    /// Whether the notes were shown in an active scene when last checked (a change to shown starts a visit).
    private var shown = false
    /// Rendered readiness of the current document; its scroll position is the reading position from then on.
    private var documentReady = false
    /// The reading position in the current document, recorded one main-queue turn late: WebKit resets the scroll
    /// view when its process ends, before it reports the end, and that reset must not replace the position. It
    /// belongs to the document, which equivalent updates (the same formatted notes) keep.
    private var checkpoint: (document: UUID, offset: CGFloat)?
    private var pendingCheckpoint: CGFloat?
    /// The position for the next rendered readiness instead of the owner's saved one (rebuilt notes).
    private var pendingScrollTarget: CGFloat?
    /// Changes only when other notes take these notes' place (not for equivalent updates or rebuilds).
    private var notesRevision = 0
    private var appearancePending = false, appearanceRequest = 0
    private var selectionClearPending = false, selectionClearRequest = 0
    private var readingObservation: NSKeyValueObservation?
    private var sceneObservers: [NSObjectProtocol] = []
    private var unavailableView: ShownotesUnavailableView?
    private(set) var processTerminations = 0
    var isAwaitingLoad: Bool { pendingLoad != nil }
    var isDocumentReady: Bool { documentReady }
    var showsUnavailableState: Bool { unavailableView != nil }
    var isAppearancePending: Bool { appearancePending }
    var isSelectionClearPending: Bool { selectionClearPending }
    private var documentAlive: Bool { renderedHTML != nil && pendingLoad == nil && unavailableView == nil }
    /// Set by the screen owner while something opaque covers these notes (the expanded player over episode details).
    /// Covered notes are not shown; uncovering them is a new visit.
    var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            if isCovered { shown = false } else { visibilityMayHaveChanged() }
        }
    }
    enum Script { case appearance, clearSelection, readSelection }
    #if DEBUG
    /// Debug builds only, for tests: takes the place of WebKit for the owned scripts, to make one fail or wait as
    /// WebKit can. Release builds have no such hook.
    var evaluateScriptForTesting: (@MainActor (ShownotesWebView, Script, String, [String: Any]) async throws -> Any?)?
    #endif
    /// The one evaluator of the owned scripts, in the notes' isolated world.
    private func evaluate(_ script: Script, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        #if DEBUG
        if let evaluateScriptForTesting { return try await evaluateScriptForTesting(self, script, body, arguments) }
        #endif
        return try await callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }
    private static let fontCSS: String = {
        guard let url = Bundle.main.url(forResource: "Roboto-Regular", withExtension: "ttf"),
              let data = try? Data(contentsOf: url) else { preconditionFailure("Required shownotes font missing") }
        return "@font-face { font-family: AntennaPodShownotes; src: url(data:font/ttf;base64,\(data.base64EncodedString())); font-weight: 100 900; } body { font-family: AntennaPodShownotes, sans-serif; font-size: 16px; }"
    }()

    private static func imageSelectionScript() -> WKUserScript {
        WKUserScript(source: """
            document.addEventListener('pointerdown', event => {
                if (!event.isTrusted) return;
                const path = event.composedPath();
                const anchor = path.find(node => node instanceof HTMLAnchorElement);
                const image = path.some(node => node instanceof HTMLImageElement) ||
                    !!anchor?.querySelector('img');
                document.documentElement.style.setProperty('--ap-image-selection', image ? 'none' : 'auto');
            }, {capture: true, passive: true});
            document.addEventListener('keydown', () => {
                document.documentElement.style.setProperty('--ap-image-selection', 'auto');
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
    }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        // WebKit otherwise starts selecting an image (or nearby text) when its
        // callout is disabled. Limit that suppression to image-initiated input.
        // A text or keyboard interaction restores normal selection across the
        // entire document, including image alt text and mixed-anchor text.
        configuration.userContentController.addUserScript(Self.imageSelectionScript())
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        selectionMessages.owner = self
        configuration.userContentController.add(selectionMessages, contentWorld: .defaultClient, name: "apSelection")
        isOpaque = false
        backgroundColor = Appearance.background
        scrollView.backgroundColor = Appearance.background
        scrollView.contentInsetAdjustmentBehavior = .never
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: ShownotesWebView, _: UITraitCollection) in
            // Notes waiting to be rebuilt are rendered at the new scale when they are shown.
            if view.pendingLoad == nil && view.unavailableView == nil { view.render() }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShownotesWebView, _: UITraitCollection) in
            view.updateAppearance()
        }
        readingObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readingPositionChanged() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { sceneObservers.forEach(NotificationCenter.default.removeObserver) }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system === UIMenuSystem.context, selectionInMainFrame,
              !super.canPerformAction(#selector(cut(_:)), withSender: nil) else { return }
        func commands(_ element: UIMenuElement) -> [UICommand] {
            if let command = element as? UICommand { return [command] }
            return (element as? UIMenu)?.children.flatMap(commands) ?? []
        }
        let providers = [builder.menu(for: .speech), builder.menu(for: .services)].compactMap { $0 }.flatMap(commands)
        selectionProviders = providers.enumerated().compactMap { index, command -> ShownotesSelectionToolbar.Action? in
            guard let target = target(forAction: command.action, withSender: self) as? UIResponder,
                  target.canPerformAction(command.action, withSender: self) else { return nil }
            return ShownotesSelectionToolbar.Action(id: "provider-\(index)", title: command.title, requiresOverflow: true) { [weak self, weak target] in
                guard let self, let target,
                      target.canPerformAction(command.action, withSender: self) else { return }
                self.hideSelectionToolbar(retire: true)
                self.willPerformTextService?()
                command.performWithSender(self, target: target)
            }
        }
        selectionToolbar?.configure(selectionActions)
        // The public native presenter pages this source row on Duo despite space
        // for its source typography. Keep WebKit's range; own only the toolbar.
        builder.replaceChildren(ofMenu: .root) { _ in [] }
    }

    private let selectionMessages = ShownotesSelectionMessages()
    private var selectionInMainFrame = true
    private var selectionToolbarSuppressed = false
    private var selectionProviders: [ShownotesSelectionToolbar.Action] = []
    private var selectionToolbar: ShownotesSelectionToolbar?

    fileprivate func selectionChanged(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["document"] as? String == documentGeneration.uuidString else { return }
        if body["type"] as? String == "ready" {
            guard message.frameInfo.isMainFrame else { return }
            if let target = pendingScrollTarget ?? restoreScrollOffset?() {
                let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let offset = min(maximum, max(0, target))
                scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            }
            pendingScrollTarget = nil
            documentReady = true
            checkpoint = (documentGeneration, scrollView.contentOffset.y)
            replayPendingHousekeeping()
            return
        }
        if body["type"] as? String == "interaction" {
            selectionInMainFrame = message.frameInfo.isMainFrame
            selectionToolbarSuppressed = false
            hideSelectionToolbar(); return
        }
        // An unrelated child frame's resize/scroll cannot retire the main range.
        guard message.frameInfo.isMainFrame, selectionInMainFrame, !selectionToolbarSuppressed else { return }
        guard body["type"] as? String == "selection",
              let text = body["text"] as? String, !text.isEmpty,
              let values = body["rects"] as? [[Double]], let window else {
            hideSelectionToolbar(); return
        }
        let fragments = values.compactMap { value -> CGRect? in
            guard value.count == 4, value.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
        }
        guard !fragments.isEmpty else { hideSelectionToolbar(); return }
        let toolbar = selectionToolbar ?? ShownotesSelectionToolbar()
        selectionToolbar = toolbar; toolbar.source = self; toolbar.fragments = fragments
        toolbar.configure(selectionActions)
        if toolbar.superview !== window { toolbar.frame = window.bounds; window.addSubview(toolbar) }
        toolbar.setNeedsLayout()
    }

    private var selectionActions: [ShownotesSelectionToolbar.Action] {
        [
            .init(id: "copy", title: Appearance.text("copy_label")) { [weak self] in
                self?.copy(nil); self?.hideSelectionToolbar(retire: true)
            },
            .init(id: "share", title: Appearance.text("share_label")) { [weak self] in
                self?.hideSelectionToolbar(retire: true); Task { await self?.performSelectionAction(.share) }
            },
            .init(id: "all", title: Appearance.text("select_all_label")) { [weak self] in
                self?.selectionToolbar?.collapseOverflow(); self?.selectAll(nil)
            },
            .init(id: "search", title: Appearance.text("web_search_label")) { [weak self] in
                self?.hideSelectionToolbar(retire: true); Task { await self?.performSelectionAction(.webSearch) }
            }
        ] + selectionProviders
    }

    private func hideSelectionToolbar(retire: Bool = false) {
        if retire { selectionToolbarSuppressed = true }
        selectionToolbar?.removeFromSuperview(); selectionToolbar = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { hideSelectionToolbar() }
        sceneObservers.forEach(NotificationCenter.default.removeObserver); sceneObservers = []
        if let scene = window?.windowScene {
            sceneObservers = [
                NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.shown = false }
                },
                // Returning to the scene is a new visit; changes that could not be applied while away are applied now.
                NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.visibilityMayHaveChanged()
                        self?.replayPendingHousekeeping()
                    }
                }
            ]
        }
        visibilityMayHaveChanged()
    }

    enum SelectionAction { case share, webSearch }

    /// Share or Web search of the selected text, which a person asked for: if the selection cannot be read any more
    /// (its document ended with WebKit's process), say so plainly instead of showing WebKit's internal error.
    struct SelectionUnavailable: LocalizedError {
        let errorDescription: String?
        @MainActor init() { errorDescription = Appearance.text("shownotes_selection_unavailable") }
    }

    func performSelectionAction(_ action: SelectionAction) async {
        let notes = notesRevision, document = documentGeneration
        var text = ""
        if documentAlive {
            do { text = try await evaluate(.readSelection, "return getSelection().toString();") as? String ?? "" }
            catch { text = "" }
        }
        // Other notes took these notes' place, or they left the screen: the request went with them.
        guard notes == notesRevision, window != nil else { return }
        // The same notes, but the selection is gone (its document ended, or nothing is selected any more).
        guard document == documentGeneration, !text.isEmpty else { failure?(SelectionUnavailable()); return }
        switch action {
        case .share: shareSelection?(text, self)
        case .webSearch: openLink?(Self.webSearchURL(for: text).absoluteString)
        }
    }

    static func webSearchURL(for text: String) -> URL {
        // Safari registers this search route; it chooses the user's search provider.
        // Encode the entire query, including +, &, #, newlines and non-ASCII text.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return URL(string: "x-web-search://?" + text.addingPercentEncoding(withAllowedCharacters: unreserved)!)!
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // WebKit hides Select All for an existing range by platform convention.
        // The source shownotes toolbar keeps it available after selecting a word.
        if action == #selector(selectAll(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Default WebKit body margin, renderer padding, paragraph margin and a
    /// complete line. Publisher styles can need more; the document stays scrollable.
    func readableViewportHeight(width: CGFloat) -> CGFloat {
        let paragraph = 8 + CGFloat(Int(8 * traitCollection.displayScale)) + 16 + defaultLineHeight
        guard loaded?.description?.isEmpty != false else { return paragraph }
        // The fixed empty-message paragraph is centered with a 16px top margin.
        // Its shrink-to-fit width is the half viewport remaining after left:50%.
        let empty = (Appearance.text("no_shownotes_label") as NSString).boundingRect(
            with: CGSize(width: max(1, width / 2), height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: defaultFont], context: nil)
        return max(paragraph, ceil(empty.height) + 32)
    }

    var defaultLineHeight: CGFloat {
        ceil(defaultFont.lineHeight)
    }

    private var defaultFont: UIFont {
        guard let font = UIFont(name: "Roboto-Regular", size: 16) else {
            preconditionFailure("Required shownotes font missing")
        }
        return font
    }

    func show(_ episode: LibraryEpisode) {
        let content = Content(description: episode.details.description, duration: episode.details.media?.durationMilliseconds ?? .max)
        guard loaded != content else { return }
        loaded = content
        let html = try? formattedHTML(content)
        // Equivalent notes (the same formatted document) keep their document, range and reading position, and a
        // rebuild that waits or is under way keeps its position and budget.
        if let html, html == renderedHTML { return }
        // Other notes never take this description's reading position, and loading them is not a rebuild.
        notesRevision += 1
        pendingScrollTarget = nil; recoveries = 0
        if pendingLoad != nil || unavailableView != nil {
            // The previous document ended with its process: these notes load once they can be seen.
            renderedHTML = nil
            hideUnavailable(); pendingLoad = .newContent
            updateShown(); loadIfShown()
            return
        }
        render(html: html)
    }

    /// Explicit player page navigation resets the source description viewport.
    /// Keep this separate from unchanged-content updates and foreground return.
    func scrollToTopForPageNavigation() {
        hideSelectionToolbar(retire: true)
        scrollView.setContentOffset(.zero, animated: false)
        // Also when these notes are rebuilt later: page navigation always shows their top.
        checkpoint = (documentGeneration, 0)
        if pendingScrollTarget != nil || pendingLoad != nil { pendingScrollTarget = 0 }
        guard loaded != nil else { return }
        selectionClearPending = true
        clearSelection()
    }

    /// Where a person reads these notes, for a view built again for them (`restoreReadingOffset`).
    var readingOffset: CGFloat {
        if let pendingScrollTarget { return pendingScrollTarget }
        if documentReady { return scrollView.contentOffset.y }
        return checkpoint.flatMap { $0.document == documentGeneration ? $0.offset : nil } ?? 0
    }

    /// The position to show at the next rendered readiness (a page rebuilt with the notes it showed).
    func restoreReadingOffset(_ offset: CGFloat) { pendingScrollTarget = offset }

    private func clearSelection() {
        // A document still to be rebuilt has no range; the rebuilt one starts without one.
        guard documentAlive else { return }
        selectionClearRequest += 1
        let request = selectionClearRequest, document = documentGeneration.uuidString
        Task { [weak self] in
            guard let self else { return }
            let cleared = await housekeeping(.clearSelection, """
                if (globalThis.apShownotesDocument !== documentID) return false;
                getSelection()?.removeAllRanges();
                return true;
                """, ["documentID": document])
            if cleared, request == selectionClearRequest { selectionClearPending = false }
        }
    }

    private func updateAppearance() {
        // UIKit also changes appearance while capturing background snapshots.
        // Recolor the owned stylesheet without replacing the document/range.
        appearancePending = true
        // A document still to be rebuilt is rendered in the colours current then.
        guard documentAlive else { return }
        appearanceRequest += 1
        let request = appearanceRequest, document = documentGeneration.uuidString
        let foreground = cssColor(Appearance.foreground), accent = cssColor(Appearance.accent)
        Task { [weak self] in
            guard let self else { return }
            let applied = await housekeeping(.appearance, """
                if (globalThis.apShownotesDocument !== documentID) return false;
                document.documentElement.style.setProperty('--ap-foreground', foreground);
                document.documentElement.style.setProperty('--ap-accent', accent);
                return true;
                """, ["documentID": document, "foreground": foreground, "accent": accent])
            if applied, request == appearanceRequest { appearancePending = false }
        }
    }

    /// Recolouring and clearing a range are housekeeping nobody asked for: when the document cannot apply one (its
    /// process ended or is suspended, or it is being replaced), nothing is shown to a person. The change stays pending
    /// and is applied again at the next rendered readiness or scene activation, without reloading the notes.
    private func housekeeping(_ script: Script, _ body: String, _ arguments: [String: Any]) async -> Bool {
        do { return try await evaluate(script, body, arguments) as? Bool == true }
        catch { return false }
    }

    private func replayPendingHousekeeping() {
        if appearancePending { updateAppearance() }
        if selectionClearPending { clearSelection() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateAppearance()
        if selectionClearPending { clearSelection() }
    }

    /// WebKit ended the content process (iOS reclaims it, mostly in the background). Handling this keeps WebKit from
    /// reloading by itself, which cannot rebuild notes loaded from a string. Everything of the old document is stale;
    /// the notes are rebuilt from the held description when shown, at the position read before the process ended.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processTerminations += 1
        let target = pendingScrollTarget ?? checkpoint.flatMap { $0.document == documentGeneration ? $0.offset : nil }
        // renderedHTML stays: it names the notes the ended document showed, which equivalent updates keep.
        documentGeneration = UUID()
        documentReady = false
        selectionToolbarSuppressed = false; selectionInMainFrame = true; selectionProviders = []
        hideSelectionToolbar()
        appearancePending = false; selectionClearPending = false
        guard loaded != nil, renderedHTML != nil, unavailableView == nil else { return }
        pendingScrollTarget = target
        if pendingLoad == nil { pendingLoad = .recovery }
        updateShown(); loadIfShown()
    }

    /// Owners call this when paging, scrolling or layout may have shown or hidden these notes.
    func visibilityMayHaveChanged() {
        // Healthy notes have nothing to rebuild and no budget to refill.
        guard pendingLoad != nil || unavailableView != nil || recoveries > 0 else { return }
        updateShown(); loadIfShown()
    }

    /// Shown means a person can see part of the notes: in a foreground-active scene, not hidden and not clipped away.
    /// A pager neighbour, or the player's notes behind its cover, is in a window but not shown.
    var isShownInActiveScene: Bool {
        guard !isCovered, let window, window.windowScene?.activationState == .foregroundActive else { return false }
        var visible = bounds
        var view: UIView = self
        while let parent = view.superview {
            if view.isHidden || view.alpha < 0.01 { return false }
            visible = view.convert(visible, to: parent)
            if parent.clipsToBounds || parent === window { visible = visible.intersection(parent.bounds) }
            if visible.isNull || visible.isEmpty { return false }
            view = parent
        }
        return view === window && !window.isHidden
    }

    private func updateShown() {
        let now = isShownInActiveScene
        if now && !shown {
            // A new visit permits another attempt, also after the notes could not be displayed.
            recoveries = 0
            if unavailableView != nil { hideUnavailable(); pendingLoad = .recovery }
        }
        shown = now
    }

    private func loadIfShown() {
        guard let pending = pendingLoad, shown else { return }
        if pending == .recovery {
            guard recoveries < Self.recoveryLimit else { showUnavailable(); return }
            recoveries += 1
        }
        pendingLoad = nil
        render(force: true)
    }

    private func showUnavailable() {
        pendingLoad = nil
        guard unavailableView == nil else { return }
        let state = ShownotesUnavailableView { [weak self] in self?.retry() }
        unavailableView = state
        addSubview(state); state.frame = bounds
        scrollView.accessibilityElementsHidden = true
        UIAccessibility.post(notification: .layoutChanged, argument: state.message)
    }

    private func hideUnavailable() {
        guard let unavailableView else { return }
        unavailableView.removeFromSuperview(); self.unavailableView = nil
        scrollView.accessibilityElementsHidden = false
    }

    private func retry() {
        hideUnavailable(); recoveries = 0; pendingLoad = .recovery
        updateShown(); loadIfShown()
    }

    private func readingPositionChanged() {
        guard documentReady else { return }
        let scheduled = pendingCheckpoint != nil
        pendingCheckpoint = scrollView.contentOffset.y
        guard !scheduled else { return }
        let document = documentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, let offset = pendingCheckpoint else { return }
            pendingCheckpoint = nil
            guard document == documentGeneration, documentReady else { return }
            checkpoint = (document, offset)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        unavailableView?.frame = bounds
    }

    private func formattedHTML(_ content: Content) throws -> String {
        let style = ShownotesFormatter.Style(foreground: "var(--ap-foreground)",
            accent: "var(--ap-accent)", padding: Int(8 * traitCollection.displayScale))
        return try ShownotesFormatter.format(content.description, durationMilliseconds: content.duration,
            noShownotesLabel: Appearance.text("no_shownotes_label"), style: style)
    }

    /// `force` rebuilds a document that ended with its process, whose notes are unchanged.
    private func render(html formatted: String? = nil, force: Bool = false) {
        guard let loaded else { return }
        do {
            // Source ItemDescriptionFragment compares cleaned HTML, so metadata
            // changes that leave the notes unchanged preserve scroll and ranges.
            // Owned appearance variables are updated in the existing document.
            let html = try formatted ?? formattedHTML(loaded)
            guard force || renderedHTML != html else { return }
            // Android treats the whole anchor as an image hit when it contains
            // an image, including a hold on that anchor's text portion.
            let defaults = " :root { --ap-foreground: \(cssColor(Appearance.foreground)); --ap-accent: \(cssColor(Appearance.accent)); }"
                + " img, a:has(img) { -webkit-touch-callout: none; -webkit-user-select: var(--ap-image-selection, auto); }"
            // The 3.2 MB inlined font joins the finished document instead of passing through the HTML parser
            //. WebKit only accepts it inline: a page from https://127.0.0.1 may not load app URLs.
            let document = try ShownotesFormatter.webKitDocument(html, defaultFontCSS: defaults, leadingCSS: Self.fontCSS)
            renderedHTML = html
            documentGeneration = UUID()
            documentReady = false; selectionClearPending = false
            hideUnavailable()
            selectionToolbarSuppressed = false; selectionInMainFrame = true; selectionProviders = []
            hideSelectionToolbar()
            configuration.userContentController.removeAllUserScripts()
            configuration.userContentController.addUserScript(Self.imageSelectionScript())
            configuration.userContentController.addUserScript(WKUserScript(source: """
                (() => {
                    globalThis.apShownotesDocument = '\(documentGeneration.uuidString)';
                    let down = false, scheduled = false;
                    const send = value => window.webkit.messageHandlers.apSelection.postMessage({document: '\(documentGeneration.uuidString)', ...value});
                    // didFinish can precede the viewport reset. The document
                    // reports rendered readiness without retaining an offscreen
                    // WebView in an awaiting native task.
                    window.addEventListener('load', () => requestAnimationFrame(() => requestAnimationFrame(() => send({type: 'ready'}))), {once: true});
                    const update = () => {
                        scheduled = false;
                        const selection = getSelection();
                        if (down || !selection || selection.isCollapsed || !selection.rangeCount || document.activeElement?.matches('input, textarea, [contenteditable=true]')) {
                            send({type: 'hide'}); return;
                        }
                        const viewport = visualViewport;
                        const scale = viewport?.scale || 1, x = viewport?.offsetLeft || 0, y = viewport?.offsetTop || 0;
                        const rects = Array.from(selection.getRangeAt(0).getClientRects()).filter(r => r.width && r.height)
                            .map(r => [(r.x - x) * scale, (r.y - y) * scale, r.width * scale, r.height * scale]);
                        send({type: 'selection', text: selection.toString(), rects});
                    };
                    const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(update); } };
                    document.addEventListener('selectionchange', schedule);
                    document.addEventListener('keydown', () => send({type: 'interaction'}), true);
                    document.addEventListener('pointerdown', () => { down = true; send({type: 'interaction'}); }, true);
                    document.addEventListener('pointerup', () => { down = false; schedule(); }, true);
                    document.addEventListener('pointercancel', () => { down = false; schedule(); }, true);
                    window.addEventListener('scroll', schedule, true);
                    window.addEventListener('resize', schedule);
                    visualViewport?.addEventListener('resize', schedule);
                    visualViewport?.addEventListener('scroll', schedule);
                })();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
            loadHTMLString(document, baseURL: URL(string: "https://127.0.0.1"))
        } catch { failure?(error) }
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        hideSelectionToolbar(retire: true)
        guard let destination = elementInfo.linkURL?.absoluteString else {
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { UIMenu(children: $0) })
            return
        }
        // WebKit falls back to its data-detector preview for HTTP links when
        // given nil. An empty configuration consumes this app-owned interaction.
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: []) })
        if let email = ShownotesLinkMenu.emailClipboardText(for: destination) {
            UIPasteboard.general.string = email
        } else {
            showLinkMenu?(destination, self)
        }
    }

    /// A popover must anchor within the visible viewport, not outside a large
    /// source rectangle that consumes nearly the whole tablet window.
    var linkShareAnchorRect: CGRect {
        var visible = bounds
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: self)) }
            ancestor = view.superview
        }
        if let window { visible = visible.intersection(window.convert(window.bounds, to: self)) }
        let rect = visible.isNull || visible.isEmpty ? bounds : visible
        return CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1)
    }

    private func cssColor(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return "rgba(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())),\(alpha))"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let destination = navigationAction.request.url?.absoluteString else { return .allow }
        if let time = ShownotesFormatter.timecodeMilliseconds(for: destination) { selectTimecode?(time) }
        else { openLink?(destination) }
        return .cancel
    }
}

/// The notes' own state when WebKit could not keep them after its automatic rebuilds: what happened and Retry, in
/// the place and type of the "no shownotes" message. It scrolls when the notes area is smaller than its content.
@MainActor final class ShownotesUnavailableView: UIScrollView {
    let message = UILabel()
    let retry = UIButton(type: .system)

    init(retry action: @escaping () -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "shownotesUnavailableState"
        backgroundColor = Appearance.background
        contentInsetAdjustmentBehavior = .never
        message.text = Appearance.text("shownotes_unavailable_label")
        message.numberOfLines = 0; message.textAlignment = .center; message.textColor = Appearance.foreground
        message.accessibilityIdentifier = "shownotesUnavailable"
        message.isAccessibilityElement = true; message.accessibilityLabel = message.text; message.accessibilityTraits = .staticText
        retry.setTitle(Appearance.text("retry_label"), for: .normal); retry.tintColor = Appearance.accent
        retry.accessibilityIdentifier = "shownotesRetry"
        retry.accessibilityLabel = Appearance.text("retry_label"); retry.accessibilityTraits = .button
        retry.addAction(UIAction { _ in action() }, for: .touchUpInside)
        [message, retry].forEach(addSubview)
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ShownotesUnavailableView, _) in
            view.refreshFonts(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refreshFonts() {
        message.font = Appearance.font(16, compatibleWith: traitCollection)
        retry.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - 32)
        let text = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        message.frame = CGRect(x: 16, y: 16, width: width, height: ceil(text.height))
        let button = retry.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let buttonWidth = min(width, max(88, ceil(button.width) + 16)), buttonHeight = max(44, ceil(button.height))
        retry.frame = CGRect(x: (bounds.width - buttonWidth) / 2, y: message.frame.maxY + 8, width: buttonWidth, height: buttonHeight)
        contentSize = CGSize(width: bounds.width, height: retry.frame.maxY + 16)
    }
}

@MainActor private final class ShownotesSelectionMessages: NSObject, WKScriptMessageHandler {
    weak var owner: ShownotesWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.selectionChanged(message)
    }
}
