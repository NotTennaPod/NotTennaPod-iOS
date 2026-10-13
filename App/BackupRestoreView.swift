import UIKit

/// Shared source settings shell (`preferences_import_export.xml`): Database, OPML, then HTML.
/// Absent capabilities are not shown as inert buttons.
@MainActor final class BackupRestoreView: UIView {
    private struct Row { let button: UIButton, heading: UILabel, detail: UILabel; var toggle: PreferenceSwitchView? = nil }
    /// `SwitchPreferenceCompat` row: state derived from the stored folder; tapping asks the owner.
    struct Switch { let isOn: Bool; let toggle: () -> Void }
    private var sections: [(category: UILabel, rows: [Row])] = []
    init(importAction: @escaping () -> Void, exportAction: (() -> Void)? = nil, databaseExportAction: (() -> Void)? = nil,
         databaseImportAction: (() -> Void)? = nil, htmlExportAction: (() -> Void)? = nil, favoritesExportAction: (() -> Void)? = nil,
         automaticExport: Switch? = nil) {
        super.init(frame: .zero)
        var database: [(String, String, String, () -> Void)] = []
        if let databaseExportAction { database.append(("database_export_label", "database_export_summary", "databaseExport", databaseExportAction)) }
        // Source order: export, automatic export, import.
        if let automaticExport {
            database.append(("automatic_database_export_label", "automatic_database_export_summary", "automaticDatabaseExport", automaticExport.toggle))
        }
        if let databaseImportAction { database.append(("database_import_label", "database_import_summary", "databaseImport", databaseImportAction)) }
        if !database.isEmpty { addSection("database", database) }
        if let automaticExport, let index = sections.last?.rows.firstIndex(where: { $0.button.accessibilityIdentifier == "automaticDatabaseExport" }) {
            let toggle = PreferenceSwitchView(); toggle.isOpaque = false; toggle.backgroundColor = .clear
            toggle.isOn = automaticExport.isOn; toggle.isUserInteractionEnabled = false
            let row = sections[sections.count - 1].rows[index]
            row.button.addSubview(toggle)
            row.button.accessibilityValue = automaticExport.isOn ? Appearance.text("on") : Appearance.text("off")
            sections[sections.count - 1].rows[index].toggle = toggle
        }
        var opml: [(String, String, String, () -> Void)] = []
        if let exportAction { opml.append(("opml_export_label", "opml_export_summary", "opmlExport", exportAction)) }
        opml.append(("opml_import_label", "opml_import_summary", "opmlImportPreference", importAction))
        addSection("opml", opml)
        var html: [(String, String, String, () -> Void)] = []
        if let htmlExportAction { html.append(("html_export_label", "html_export_summary", "htmlExport", htmlExportAction)) }
        if let favoritesExportAction { html.append(("favorites_export_label", "favorites_export_summary", "favoritesExport", favoritesExportAction)) }
        if !html.isEmpty { addSection("html", html) }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func addSection(_ title: String, _ rows: [(String, String, String, () -> Void)]) {
        let category = Appearance.label(Appearance.text(title), size: 14, bold: true)
        category.textColor = Appearance.accent; addSubview(category)
        sections.append((category, rows.map { makeRow($0.0, $0.1, $0.2, $0.3) }))
    }
    private func makeRow(_ title: String, _ summary: String, _ id: String, _ action: @escaping () -> Void) -> Row {
        let button = UIButton(type: .custom), heading = Appearance.label(Appearance.text(title), size: 16)
        let detail = Appearance.label(Appearance.text(summary), size: 14); detail.textColor = Appearance.secondary
        button.accessibilityIdentifier = id; button.accessibilityLabel = Appearance.text(title)
        button.accessibilityHint = Appearance.text(summary)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        heading.isUserInteractionEnabled = false; detail.isUserInteractionEnabled = false
        button.addSubview(heading); button.addSubview(detail); addSubview(button)
        return Row(button: button, heading: heading, detail: detail)
    }
    /// A switch row keeps the source 84-point trailing widget area (NavigationSettingsView switch rows).
    private func textWidth(_ row: Row, _ width: CGFloat) -> CGFloat { row.toggle == nil ? width : max(0, width - 68) }
    private func rowHeight(_ row: Row, width: CGFloat) -> CGFloat {
        let width = textWidth(row, width)
        return max(72, row.heading.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            + row.detail.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 24)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, size.width - 32)
        let height = sections.reduce(CGFloat(0)) { total, section in
            total + 48 + section.rows.reduce(0) { $0 + rowHeight($1, width: width) }
        }
        return CGSize(width: size.width, height: height)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); let width = max(0, bounds.width - 32)
        var y: CGFloat = 0
        for section in sections {
            section.category.frame = CGRect(x: 16, y: y, width: width, height: 48); y += 48
            for row in section.rows {
                let text = textWidth(row, width)
                let h = row.heading.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height
                let d = row.detail.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height
                row.button.frame = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight(row, width: width))
                let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                row.heading.frame = CGRect(x: rtl && row.toggle != nil ? 84 : 16, y: 12, width: text, height: h)
                row.detail.frame = CGRect(x: rtl && row.toggle != nil ? 84 : 16, y: 12 + h, width: text, height: d)
                row.toggle?.frame = CGRect(x: rtl ? 16 : bounds.width - 68, y: (row.button.bounds.height - 32) / 2, width: 52, height: 32)
                y += row.button.bounds.height
            }
        }
    }
}
