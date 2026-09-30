import AppKit
import MuluAppModel

/// Title column: indentation by level, a disclosure triangle for rows with children, an
/// editable single-line text field, and (for doubtful and error rows) the first reason in grey
/// after the title, so the reason is visible without hovering.
final class TitleCellView: NSTableCellView {
    private let disclosure = NSButton()
    private let field = NSTextField()
    private let note = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint?
    /// The row shown; kept while the field is being edited (the edit belongs to that row).
    private(set) var rowID: UUID?
    private weak var handler: OutlineTableCoordinator?

    init(handler: OutlineTableCoordinator) {
        self.handler = handler
        super.init(frame: .zero)
        identifier = .outlineTitle

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked(_:))
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = String(localized: "（无标题）")
        field.delegate = handler
        field.setAccessibilityLabel(String(localized: "标题"))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        textField = field

        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.cell?.usesSingleLineMode = true
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.required, for: .horizontal)
        note.setAccessibilityElement(false)  // the reasons are in the check button's help

        addSubview(disclosure)
        addSubview(field)
        addSubview(note)
        let indent = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        self.indent = indent
        NSLayoutConstraint.activate([
            indent,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 3),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            note.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TitleCellView is created in code")
    }

    func configure(_ row: DisplayRow) {
        let editing = field.currentEditor() != nil
        if !editing { rowID = row.id }
        indent?.constant = 2 + CGFloat(row.level) * 16
        disclosure.isHidden = !row.hasChildren
        disclosure.state = row.isExpanded ? .on : .off
        let shown = Wording.shortTitle(row.title)
        disclosure.setAccessibilityLabel(row.isExpanded
            ? String(localized: "折叠「\(shown)」")
            : String(localized: "展开「\(shown)」"))
        field.font = row.level == 0
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if !editing, field.stringValue != row.title {
            field.stringValue = row.title
        }
        field.setAccessibilityHelp(String(localized: "第 \(row.level + 1) 级"))

        let reason = row.status == .doubtful || row.status == .error ? Wording.reasonLines(row).first : nil
        note.stringValue = reason ?? ""
        note.isHidden = reason == nil
        note.textColor = row.status == .error ? .systemRed : .secondaryLabelColor
        note.toolTip = reason
    }

    @objc private func disclosureClicked(_ sender: NSButton) {
        guard let rowID else { return }
        handler?.toggleExpanded(rowID, allRows: NSEvent.modifierFlags.contains(.option))
    }
}
