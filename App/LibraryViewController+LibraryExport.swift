import UIKit
import NotTennaPodCore

/// The four exports of the Import/Export page (PROTOCOL §11.5).
enum LibraryExportKind: CaseIterable {
    case database, opml, html, favorites

    var titleKey: String {
        switch self {
        case .database: "database_export_label"
        case .opml: "opml_export_label"
        case .html: "html_export_label"
        case .favorites: "favorites_export_label"
        }
    }
}

// Exports bound to a library (PROTOCOL §11.5): while a server library is active each export first asks "Export which
// library?"; a previous library is exported from its row on the Synchronization page. The choice
// binds the export to the library's identity; after the destination is chosen, one source is collected under the
// library gate, and the document is encoded and written without it.
extension LibraryViewController {
    /// The payload of the export attempt being made now, bound to `exportTarget` (or the open library).
    func exportPayload(_ kind: LibraryExportKind) throws -> @Sendable () async throws -> Data {
        guard let library else { throw LibraryExportError.libraryNotFound }
        guard let identity = exportTarget ?? library.identityAtOpen?.identity else { throw LibraryExportError.libraryNotFound }
        let app = UIApplication.shared.delegate as? AppDelegate
        let root = app?.libraryDirectory
        let vault = feedAuthentication?.credentialStore ?? KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds")
        return { [weak app] in
            // The open library as the graph holds it once the gate is held, never as it was when the export began.
            let source = try await LibraryExport.collect(identity: identity, root: root ?? FileManager.default.temporaryDirectory,
                                                         current: { app?.exportOpenLibrary() }, vault: vault, gate: .shared)
            // Encoded after the gate is released.
            switch kind {
            case .database: return try source.databaseData()
            case .opml: return try source.opmlData()
            case .html: return source.htmlData(favorites: false)
            case .favorites: return source.htmlData(favorites: true)
            }
        }
    }

    private func flow(_ kind: LibraryExportKind) -> DocumentExportFlow? {
        switch kind {
        case .database: databaseExportFlow
        case .opml: opmlExportFlow
        case .html: htmlExportFlow(favorites: false)
        case .favorites: htmlExportFlow(favorites: true)
        }
    }

    /// Starts an export of the library named `identity` (nil: the open library).
    func beginExport(_ kind: LibraryExportKind, identity: String?) {
        exportTarget = identity
        defer { exportTarget = nil }
        flow(kind)?.begin()
    }

    /// An export from the Import/Export page: the open library in standalone; while a server library is active, the
    /// person first chooses the server's library or this phone's own.
    func beginLibraryExport(_ kind: LibraryExportKind) {
        guard let choice = exportChoice() else { beginExport(kind, identity: nil); return }
        guard presentedViewController == nil else { return }
        messages.present(ServerSynchronizationDialogs.exportChoice(serverSummary: choice.serverSummary) { [weak self] index in
            self?.beginExport(kind, identity: index == 0 ? choice.server : choice.own)
        })
    }

    /// The two libraries of the export choice, when a server library is the active one.
    private func exportChoice() -> (server: String, serverSummary: String, own: String)? {
        guard let app = UIApplication.shared.delegate as? AppDelegate, let root = app.libraryDirectory,
              case .server(let id)? = app.libraryLocation?.reference, app.libraryLocation?.converted == nil,
              let registry = try? LibraryRegistryFile(root: root).read(), let entry = registry.library(id), entry.state == .active,
              let server = library?.identityAtOpen?.identity else { return nil }
        let own = registry.standaloneIdentity
            ?? (try? LibraryDatabaseInspection.identity(of: root.appendingPathComponent(LibraryLocation.databaseName)))?.identity
        guard let own else { return nil }
        let host = ServerAddress(stored: entry.serverURL)?.host ?? entry.serverURL
        return (server, String(format: Appearance.text("ntp_server_library_account"), entry.username, host), own)
    }
}

/// A dialog's list of choices, each a row with a title and an optional summary (the export choice, PROTOCOL §15.5; a previous
/// library's exports), in the provider dialog's row style.
@MainActor final class ExportLibraryChoices: UIView {
    var onSelect: ((Int) -> Void)?
    private var rows: [(UIControl, UILabel, UILabel?)] = []

    init(choices: [(title: String, summary: String?, identifier: String)]) {
        super.init(frame: .zero)
        for (index, choice) in choices.enumerated() {
            let row = UIControl(), title = Appearance.label(choice.title, size: 16)
            title.textColor = Appearance.foreground
            let summary = choice.summary.map { text -> UILabel in
                let label = Appearance.label(text, size: 14)
                label.textColor = Appearance.secondary
                return label
            }
            row.isAccessibilityElement = true; row.accessibilityTraits = .button
            row.accessibilityLabel = choice.title; row.accessibilityValue = choice.summary
            row.accessibilityIdentifier = choice.identifier
            row.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            row.addSubview(title)
            if let summary { row.addSubview(summary) }
            addSubview(row)
            rows.append((row, title, summary))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(size.width)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(bounds.width) }

    @discardableResult private func arrange(_ width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let inset: CGFloat = 24, textWidth = max(1, width - 2 * inset)
        for (row, title, summary) in rows {
            title.font = Appearance.font(16, compatibleWith: traitCollection)
            summary?.font = Appearance.font(14, compatibleWith: traitCollection)
            let th = ceil(title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            let sh = summary.map { ceil($0.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height) } ?? 0
            let height = max(48, th + sh + 24)
            row.frame = CGRect(x: 0, y: y, width: width, height: height)
            title.frame = CGRect(x: inset, y: (height - th - sh) / 2, width: textWidth, height: th)
            summary?.frame = CGRect(x: inset, y: title.frame.maxY, width: textWidth, height: sh)
            // The dialog forces its direction on this body; its rows' text follows it.
            let alignment: NSTextAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            title.textAlignment = alignment; summary?.textAlignment = alignment
            y += height
        }
        return y
    }
}
