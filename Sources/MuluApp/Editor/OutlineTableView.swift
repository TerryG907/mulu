import AppKit

extension NSUserInterfaceItemIdentifier {
    static let outlineTitle = NSUserInterfaceItemIdentifier("mulu.outline.title")
    static let outlinePage = NSUserInterfaceItemIdentifier("mulu.outline.page")
    static let outlineCheck = NSUserInterfaceItemIdentifier("mulu.outline.check")
    static let outlineRow = NSUserInterfaceItemIdentifier("mulu.outline.row")
}

/// `NSTableView` subclass that routes table-only keys (Tab, Return, brackets, Space, ⌫, arrows in
/// review) to the coordinator, and keeps single clicks from starting inline edits: editing starts
/// only with Return, a double-click or an edit request from the model.
final class OutlineTableView: NSTableView {
    weak var handler: OutlineTableCoordinator?

    static func make(handler: OutlineTableCoordinator) -> OutlineTableView {
        let table = OutlineTableView()
        table.handler = handler

        let title = NSTableColumn(identifier: .outlineTitle)
        title.title = String(localized: "标题")
        title.minWidth = 160
        title.resizingMask = .autoresizingMask

        let page = NSTableColumn(identifier: .outlinePage)
        page.title = String(localized: "页码")
        page.width = 112
        page.minWidth = 90
        page.maxWidth = 160
        page.headerCell.alignment = .right

        let check = NSTableColumn(identifier: .outlineCheck)
        check.title = String(localized: "核对")
        check.width = 44
        check.minWidth = 36
        check.maxWidth = 60
        check.headerCell.alignment = .center

        table.addTableColumn(title)
        table.addTableColumn(page)
        table.addTableColumn(check)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = handler
        table.delegate = handler
        table.target = handler
        table.doubleAction = #selector(OutlineTableCoordinator.rowDoubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = handler
        menu.autoenablesItems = false
        table.menu = menu
        table.setAccessibilityLabel(String(localized: "目录条目"))
        return table
    }

    override func keyDown(with event: NSEvent) {
        if handler?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        handler?.clickBegan()
        super.mouseDown(with: event)
        handler?.clickEnded(clickCount: event.clickCount)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextField {
            return handler?.allowsFieldEditing ?? false
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// Right-clicking an unselected row selects it, so menu commands act on what was clicked.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}
