import UIKit
import NotTennaPodCore

/// `edit_text_dialog.xml` for an address: one field with the "RSS address" hint, an inline error
/// below it, URI keyboard. Used by Add podcast by RSS address and Edit feed URL.
@MainActor final class AddressInputBody: UIView, SourceMessageBodyViewport, SourceMessageEditingBody, UITextFieldDelegate {
    let field = UITextField()
    private let border = UIView()
    private let error = UILabel()
    var onSizeChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var minimumMessageViewportHeight: CGFloat { 56 + 8 }
    var editingControl: UIView? { field.isFirstResponder ? field : nil }
    func messageBodyDidScroll() {}
    init(text: String, hint: String?, identifier: String) {
        super.init(frame: .zero)
        field.text = text; field.placeholder = hint; field.accessibilityIdentifier = identifier
        field.accessibilityLabel = hint
        field.keyboardType = .URL; field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.returnKeyType = .done; field.textColor = Appearance.foreground; field.tintColor = Appearance.accent
        field.clearButtonMode = .never; field.delegate = self
        border.layer.cornerRadius = 4; border.isUserInteractionEnabled = false
        error.textColor = Appearance.color(0xb3261e, 0xf2b8b5); error.numberOfLines = 0; error.isHidden = true
        error.accessibilityIdentifier = "rssAddressError"
        addSubview(border); addSubview(field); addSubview(error)
        field.addAction(UIAction { [weak self] _ in self?.refreshBorder() }, for: [.editingDidBegin, .editingDidEnd])
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: AddressInputBody, _) in
            view.refreshFonts(); view.setNeedsLayout(); view.onSizeChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    var text: String { field.text ?? "" }
    /// Focus the field (caret after the text) once the dialog is on screen.
    var focusesOnAppear = true
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusesOnAppear else { return }
        focusesOnAppear = false
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            field.becomeFirstResponder()
            field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        }
    }
    /// TextInputLayout.setError: the message stays until the next confirmation.
    func showError(_ message: String?) {
        error.text = message; error.isHidden = message == nil
        field.accessibilityValue = nil
        refreshBorder(); setNeedsLayout(); onSizeChange?()
        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { onReturn?(); return false }
    private func refreshFonts() {
        field.font = Appearance.font(16, compatibleWith: traitCollection)
        error.font = Appearance.font(12, compatibleWith: traitCollection)
        refreshBorder()
    }
    private func refreshBorder() {
        let color: UIColor = !error.isHidden ? error.textColor : (field.isFirstResponder ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.38))
        border.layer.borderWidth = field.isFirstResponder || !error.isHidden ? 2 : 1
        border.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }
    private func fieldHeight() -> CGFloat { max(56, ceil((field.font?.lineHeight ?? 19) + 32)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let errorHeight = error.isHidden ? 0 : error.sizeThatFits(CGSize(width: max(0, size.width - 64), height: .greatestFiniteMagnitude)).height + 4
        return CGSize(width: size.width, height: 16 + fieldHeight() + errorHeight + 8)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        border.frame = CGRect(x: 24, y: 16, width: max(0, bounds.width - 48), height: fieldHeight())
        field.textAlignment = rtl ? .right : .left
        field.frame = border.frame.insetBy(dx: 16, dy: 0)
        error.textAlignment = rtl ? .right : .left
        let errorHeight = error.sizeThatFits(CGSize(width: max(0, bounds.width - 64), height: .greatestFiniteMagnitude)).height
        error.frame = CGRect(x: 40, y: border.frame.maxY + 4, width: max(0, bounds.width - 64), height: errorHeight)
    }
}

/// `select_country_dialog.xml`: a filled exposed-dropdown field with the "Select country" hint and the
/// current country's name. Focusing the field clears it and opens the list; typing filters it.
@MainActor final class CountrySelectionBody: UIView, SourceMessageBodyViewport, SourceMessageEditingBody, UITextFieldDelegate {
    let field = UITextField()
    private let fill = UIView()
    private let hint = UILabel()
    private let list = UIScrollView()
    private var rows: [UIButton] = []
    private let countries: DiscoveryCountries
    var onSizeChange: (() -> Void)?
    var minimumMessageViewportHeight: CGFloat { 96 }
    var editingControl: UIView? { field.isFirstResponder ? field : nil }
    func messageBodyDidScroll() {}
    private var dropDownOpen = false

    init(countries: DiscoveryCountries, current: String?) {
        self.countries = countries
        super.init(frame: .zero)
        fill.backgroundColor = Appearance.color(0xe1e3e6, 0x343b40); fill.layer.cornerRadius = 4
        fill.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]; fill.isUserInteractionEnabled = false
        hint.text = Appearance.text("select_country"); hint.textColor = Appearance.accent
        field.text = current; field.accessibilityIdentifier = "selectCountryField"
        field.accessibilityLabel = Appearance.text("select_country")
        field.autocorrectionType = .no; field.returnKeyType = .done; field.textColor = Appearance.foreground
        field.tintColor = Appearance.accent; field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.filter() }, for: .editingChanged)
        list.accessibilityIdentifier = "selectCountryList"; list.isHidden = true
        list.backgroundColor = Appearance.navigation; list.layer.cornerRadius = 4
        [fill, hint, field, list].forEach(addSubview)
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: CountrySelectionBody, _) in
            view.refreshFonts(); view.setNeedsLayout(); view.onSizeChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    var text: String { field.text ?? "" }
    private func refreshFonts() {
        field.font = Appearance.font(16, compatibleWith: traitCollection)
        hint.font = Appearance.font(12, compatibleWith: traitCollection)
        rows.forEach { $0.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection) }
    }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Focusing clears the field and opens the whole list.
        field.text = ""; dropDownOpen = true; filter()
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { field.resignFirstResponder(); return false }
    private func filter() {
        rows.forEach { $0.removeFromSuperview() }
        rows = countries.matches(text).enumerated().map { index, name in
            let row = UIButton(type: .system)
            row.setTitle(name, for: .normal); row.tintColor = Appearance.foreground
            row.contentHorizontalAlignment = .leading; row.titleLabel?.lineBreakMode = .byTruncatingTail
            row.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
            row.accessibilityIdentifier = "selectCountryOption-\(index)"
            row.addAction(UIAction { [weak self] _ in self?.choose(name) }, for: .touchUpInside)
            list.addSubview(row); return row
        }
        list.isHidden = !dropDownOpen || rows.isEmpty
        setNeedsLayout(); onSizeChange?()
    }
    private func choose(_ name: String) {
        field.text = name; dropDownOpen = false; list.isHidden = true
        field.resignFirstResponder(); setNeedsLayout(); onSizeChange?()
    }
    private func rowHeight() -> CGFloat { max(48, ceil(Appearance.font(16, compatibleWith: traitCollection).lineHeight + 24)) }
    private func fieldHeight() -> CGFloat { max(56, ceil((field.font?.lineHeight ?? 19) + (hint.font?.lineHeight ?? 14) + 20)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let listHeight = list.isHidden ? 0 : min(CGFloat(rows.count), 5) * rowHeight()
        return CGSize(width: size.width, height: 20 + fieldHeight() + listHeight + 20)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = max(0, bounds.width - 40)
        fill.frame = CGRect(x: 20, y: 20, width: width, height: fieldHeight())
        hint.textAlignment = rtl ? .right : .left; field.textAlignment = rtl ? .right : .left
        let hintHeight = hint.font?.lineHeight ?? 14
        hint.frame = CGRect(x: 36, y: 28, width: max(0, width - 32), height: hintHeight)
        field.frame = CGRect(x: 36, y: hint.frame.maxY, width: max(0, width - 32), height: fill.frame.maxY - hint.frame.maxY - 4)
        let height = rowHeight()
        list.frame = CGRect(x: 20, y: fill.frame.maxY, width: width, height: min(CGFloat(rows.count), 5) * height)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 16, y: CGFloat(index) * height, width: max(0, width - 32), height: height)
            row.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        }
        list.contentSize = CGSize(width: width, height: CGFloat(rows.count) * height)
    }
}
