import AppKit
import MuluAppModel

/// Check column: one icon per status (shape differs, not only colour); clicking toggles ✓.
final class CheckCellView: NSTableCellView {
    private let button = NSButton()
    private var rowID: UUID?
    private weak var handler: OutlineTableCoordinator?

    init(handler: OutlineTableCoordinator) {
        self.handler = handler
        super.init(frame: .zero)
        identifier = .outlineCheck
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.title = ""
        button.target = self
        button.action = #selector(clicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CheckCellView is created in code")
    }

    func configure(_ row: DisplayRow) {
        rowID = row.id
        let (symbol, color): (String, NSColor) = switch row.status {
        case .error: ("exclamationmark.triangle.fill", .systemRed)
        case .doubtful: ("questionmark.circle.fill", .systemOrange)
        case .confirmed: ("checkmark.circle.fill", .systemGreen)
        case .ok: ("circle", .tertiaryLabelColor)
        }
        let label = Wording.status(row.status)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = color
        button.setAccessibilityLabel(label)
        let reasons = Wording.reasonLines(row)
        button.setAccessibilityHelp(reasons.joined(separator: String(localized: "；")))
        toolTip = Wording.reasonTooltip(row, status: label)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let rowID else { return }
        handler?.toggleChecked(rowID)
    }
}
