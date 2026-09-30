import AppKit
import MuluAppModel

/// Page column: the printed page in small grey type ("印 12"), a pin for manually fixed pages,
/// and the editable physical page (a red dash when the row has none).
final class PageCellView: NSTableCellView {
    private let printed = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let field = NSTextField()
    /// The row shown; kept while the field is being edited (the edit belongs to that row).
    private(set) var rowID: UUID?

    init(handler: OutlineTableCoordinator) {
        super.init(frame: .zero)
        identifier = .outlinePage

        printed.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        printed.textColor = .secondaryLabelColor
        printed.lineBreakMode = .byTruncatingHead
        printed.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: String(localized: "手动固定的页码"))
        pin.contentTintColor = .secondaryLabelColor
        pin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize, weight: .regular)

        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.cell?.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(
            string: "—", attributes: [.foregroundColor: NSColor.systemRed, .font: field.font as Any])
        field.delegate = handler
        field.setAccessibilityLabel(String(localized: "页码"))
        textField = field

        let stack = NSStackView(views: [printed, pin, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageCellView is created in code")
    }

    func configure(_ row: DisplayRow, tooltip: String) {
        let editing = field.currentEditor() != nil
        if !editing { rowID = row.id }
        if let page = row.printedPage {
            // A section shift (the offset changed from some chapter on) is shown, not hidden in
            // the tooltip: "印 12 ·+2".
            printed.stringValue = row.sectionShift != 0 && !row.pageOverride
                ? String(localized: "印 \(page.display) ·\(Wording.signed(row.sectionShift))")
                : String(localized: "印 \(page.display)")
            printed.isHidden = false
        } else {
            printed.isHidden = true
        }
        pin.isHidden = !row.pageOverride
        let text = row.physicalPage.map(String.init) ?? ""
        if !editing, field.stringValue != text {
            field.stringValue = text
        }
        toolTip = tooltip
        field.setAccessibilityHelp(tooltip)
    }
}
