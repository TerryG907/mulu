import AppKit
import MuluCore

/// Accessory view of the import panel: "Format: Detect automatically / <five formats>".
@MainActor
final class FormatPicker {
    let view: NSView
    private let popUp: NSPopUpButton

    init() {
        popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItem(withTitle: String(localized: "自动识别"))
        for format in TOCFormat.allCases {
            popUp.addItem(withTitle: Wording.formatName(format))
        }
        let label = NSTextField(labelWithString: String(localized: "格式："))
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
    }

    /// nil = let `TOCInterop.detect` decide.
    var selectedFormat: TOCFormat? {
        let index = popUp.indexOfSelectedItem
        guard index > 0, index - 1 < TOCFormat.allCases.count else { return nil }
        return TOCFormat.allCases[index - 1]
    }
}
