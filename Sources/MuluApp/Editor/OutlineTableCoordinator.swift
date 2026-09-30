import AppKit
import MuluAppModel
import MuluCore

/// Data source, delegate, key handler and inline-edit controller of the outline table.
///
/// Sync rules (GUI_SPEC §6.4, §11): the table reloads only when the model's `revision` moves, and
/// when the row identities are unchanged it reconfigures the existing cells in place so an edit in
/// progress survives. Selection flows both ways with a guard flag against feedback loops.
///
/// Inline edits are tied to the row's id, recorded when the edit starts, never to a table index:
/// a reload while a field is being edited (undo, a row moved or deleted, a row collapsed) ends
/// the edit first and commits the typed text to the row it was typed for.
@MainActor
final class OutlineTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuDelegate {

    let session: DocumentSession
    private var model: DocumentModel { session.model }
    private weak var table: OutlineTableView?

    private var rows: [DisplayRow] = []
    private var indexByID: [UUID: Int] = [:]
    private var lastRevision: Int?
    private var lastSelection: Set<UUID>?
    private var lastEditSerial: Int?
    private var lastReviewCurrent: UUID?

    /// The inline edit in progress: which row and column the field was opened for.
    private struct ActiveEdit {
        let id: UUID
        let column: NSUserInterfaceItemIdentifier
        weak var field: NSTextField?
    }
    private var activeEdit: ActiveEdit?

    private var isApplyingSelection = false
    private var selectionChangedDuringClick = false
    private var editingCancelled = false
    /// True only while the coordinator itself starts an inline edit.
    private(set) var allowsFieldEditing = false

    init(session: DocumentSession) {
        self.session = session
        super.init()
    }

    func attach(_ table: OutlineTableView) {
        self.table = table
        rows = model.displayRows
        rebuildIndex()
        lastRevision = model.revision
        table.reloadData()
    }

    // MARK: - Model → table

    func update(revision: Int, selection: Set<UUID>, focus: UUID?, editRequest: EditRequest?, reviewCurrent: UUID?) {
        guard table != nil else { return }
        var reloaded = false
        if revision != lastRevision {
            lastRevision = revision
            refreshRows()
            reloaded = true
        }
        let reviewChanged = reviewCurrent != lastReviewCurrent
        if reviewChanged {
            lastReviewCurrent = reviewCurrent
            refreshRowBackgrounds()
        }
        let selectionChanged = selection != lastSelection
        if reloaded || selectionChanged {
            lastSelection = selection
            applySelection(selection, focus: focus, scroll: selectionChanged && !reviewChanged)
        }
        if reviewChanged, let reviewCurrent, let row = indexByID[reviewCurrent] {
            // Centred, so the row is never at the very edge of the visible area.
            scrollRowToCenter(row)
            announceReviewRow(reviewCurrent)
        }
        if let editRequest, editRequest.serial != lastEditSerial {
            lastEditSerial = editRequest.serial
            // After a reload the row views do not exist yet, and a freshly created table is not
            // in a window yet: start editing once it is (give up after half a second).
            Task { @MainActor [weak self] in
                for _ in 0..<10 {
                    guard let self, let table = self.table else { return }
                    if table.window != nil {
                        self.beginEditing(editRequest.rowID, field: editRequest.field)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    private func refreshRows() {
        guard let table else { return }
        let newRows = model.displayRows
        let sameIdentities = newRows.count == rows.count && zip(newRows, rows).allSatisfy { $0.id == $1.id }
        if !sameIdentities {
            // The cells are about to show other rows: end the edit while they still show the old
            // ones, and commit the text (after this SwiftUI update) to the row it was typed for.
            endActiveEditBeforeReload()
        }
        rows = newRows
        rebuildIndex()
        if sameIdentities {
            reconfigureAvailableRows()
        } else {
            table.reloadData()
        }
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
    }

    private func reconfigureAvailableRows() {
        guard let table else { return }
        table.enumerateAvailableRowViews { rowView, index in
            guard index < rows.count else { return }
            (rowView as? OutlineRowView)?.apply(status: rows[index].status, isReviewCurrent: rows[index].id == lastReviewCurrent)
            for column in 0..<rowView.numberOfColumns {
                if let cell = rowView.view(atColumn: column) as? NSView {
                    configure(cell, row: index)
                }
            }
        }
    }

    private func refreshRowBackgrounds() {
        table?.enumerateAvailableRowViews { rowView, index in
            guard index < rows.count else { return }
            (rowView as? OutlineRowView)?.apply(status: rows[index].status, isReviewCurrent: rows[index].id == lastReviewCurrent)
        }
    }

    private func configure(_ cell: NSView, row index: Int) {
        let row = rows[index]
        switch cell {
        case let title as TitleCellView:
            title.configure(row)
        case let page as PageCellView:
            page.configure(row, tooltip: Wording.pageTooltip(row, mapping: model.draft.mapping))
        case let check as CheckCellView:
            check.configure(row)
        default:
            break
        }
    }

    private func applySelection(_ selection: Set<UUID>, focus: UUID?, scroll: Bool) {
        guard let table else { return }
        let indexes = IndexSet(selection.compactMap { indexByID[$0] })
        if table.selectedRowIndexes != indexes {
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }
        if scroll, let focus, let row = indexByID[focus] {
            table.scrollRowToVisible(row)
        }
    }

    /// Scrolls so the row sits in the middle of the visible area (as far as the ends allow).
    private func scrollRowToCenter(_ row: Int) {
        guard let table, let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView
        let rect = table.rect(ofRow: row)
        let visible = clip.documentVisibleRect
        guard visible.height > 0 else {
            table.scrollRowToVisible(row)
            return
        }
        var origin = clip.bounds.origin
        origin.y += rect.midY - visible.midY
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// VoiceOver: the review position, the row and its first reason.
    private func announceReviewRow(_ id: UUID) {
        guard let review = model.review, let row = rows.first(where: { $0.id == id }) else { return }
        let position = min(review.position + 1, review.queue.count)
        let reason = Wording.reasonLines(row).first ?? ""
        let text = String(localized: "审阅 \(position)/\(review.queue.count)：\(Wording.shortTitle(row.title))。\(reason)")
        guard let element: Any = table?.window ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < rows.count else { return nil }
        let cell: NSView
        switch identifier {
        case .outlineTitle:
            cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TitleCellView ?? TitleCellView(handler: self)
        case .outlinePage:
            cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PageCellView ?? PageCellView(handler: self)
        case .outlineCheck:
            cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CheckCellView ?? CheckCellView(handler: self)
        default:
            return nil
        }
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: .outlineRow, owner: self) as? OutlineRowView ?? {
            let view = OutlineRowView()
            view.identifier = .outlineRow
            return view
        }()
        if row < rows.count {
            rowView.apply(status: rows[row].status, isReviewCurrent: rows[row].id == lastReviewCurrent)
        }
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let table else { return }
        selectionChangedDuringClick = true
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        let focusRow = table.selectedRow
        let focus = focusRow >= 0 && focusRow < rows.count ? rows[focusRow].id : nil
        lastSelection = ids
        model.select(ids, focus: focus)
    }

    // MARK: - Clicks

    func clickBegan() {
        selectionChangedDuringClick = false
    }

    /// Clicking the row that is already selected still re-jumps the preview (GUI_SPEC §5.5).
    func clickEnded(clickCount: Int) {
        guard let table, clickCount == 1, !selectionChangedDuringClick else { return }
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        model.select(model.selection.isEmpty ? [rows[row].id] : model.selection, focus: rows[row].id)
    }

    @objc func rowDoubleClicked(_ sender: Any?) {
        guard let table, session.canEdit else { return }
        let row = table.clickedRow
        let column = table.clickedColumn
        guard row >= 0, row < rows.count, column >= 0 else { return }
        switch table.tableColumns[column].identifier {
        case .outlineTitle: beginEditing(rows[row].id, field: .title)
        case .outlinePage: beginEditing(rows[row].id, field: .page)
        default: break
        }
    }

    func toggleExpanded(_ id: UUID, allRows: Bool) {
        session.commitEditing()
        if allRows {
            if model.isExpanded(id) { model.collapseAll() } else { model.expandAll() }
        } else {
            model.toggleExpanded(id)
        }
    }

    func toggleChecked(_ id: UUID) {
        session.commitEditing()
        guard session.canEdit, let row = model.displayRows.first(where: { $0.id == id }) else { return }
        guard row.status != .error else {
            NSSound.beep()
            return
        }
        model.setConfirmed([id], row.status != .confirmed)
    }

    // MARK: - Keys

    /// Table-only keys (GUI_SPEC §6.7); menu shortcuts are handled by `MuluCommands`.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard session.canEdit else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = event.keyCode

        if model.review != nil, flags.isEmpty {
            switch code {
            case KeyCode.down: model.reviewMove(1); return true
            case KeyCode.up: model.reviewMove(-1); return true
            case KeyCode.returnKey, KeyCode.enter:
                // An error row cannot be checked: fix it first (⌘E edits the title).
                if !model.reviewConfirmAndAdvance() { NSSound.beep() }
                return true
            case KeyCode.escape: model.endReview(); return true
            default: break
            }
        }

        if flags.isEmpty {
            switch code {
            case KeyCode.returnKey, KeyCode.enter:
                session.editTitle()
                return true
            case KeyCode.tab:
                session.indent()
                return true
            case KeyCode.delete, KeyCode.forwardDelete:
                session.delete(keepChildren: false)
                return true
            case KeyCode.space:
                session.toggleConfirmed()
                return true
            case KeyCode.right:
                expandOrDescend()
                return true
            case KeyCode.left:
                collapseOrAscend()
                return true
            default:
                break
            }
        }
        if flags == .shift, code == KeyCode.tab {
            session.outdent()
            return true
        }
        if flags.isDisjoint(with: [.command, .option, .control]) {
            switch event.characters {
            case "]": session.shiftPages(by: 1); return true
            case "[": session.shiftPages(by: -1); return true
            case "}": session.shiftPages(by: 10); return true
            case "{": session.shiftPages(by: -10); return true
            default: break
            }
        }
        return false
    }

    private func expandOrDescend() {
        guard let id = session.focusID, let index = indexByID[id] else { return }
        let row = rows[index]
        guard row.hasChildren else { return }
        if !row.isExpanded {
            model.setExpanded(id, true)
        } else if index + 1 < rows.count {
            let child = rows[index + 1].id
            model.select([child], focus: child)
        }
    }

    private func collapseOrAscend() {
        guard let id = session.focusID, let index = indexByID[id] else { return }
        let row = rows[index]
        if row.hasChildren, row.isExpanded {
            model.setExpanded(id, false)
        } else if let parent = rows[..<index].last(where: { $0.level < row.level }) {
            model.select([parent.id], focus: parent.id)
        }
    }

    // MARK: - Inline editing

    func beginEditing(_ id: UUID, field: EditRequest.Field) {
        guard let table, session.canEdit, let row = indexByID[id], table.window != nil else { return }
        let column = field == .title ? 0 : 1
        table.scrollRowToVisible(row)
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        allowsFieldEditing = true
        table.editColumn(column, row: row, with: nil, select: true)
        allowsFieldEditing = false
        let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView
        if let textField = cell?.textField, textField.currentEditor() != nil {
            activeEdit = ActiveEdit(id: id, column: table.tableColumns[column].identifier, field: textField)
        }
    }

    /// A text field of this table whose field editor is active, however its edit started.
    private func editingFieldInTable() -> NSTextField? {
        guard let table, let editor = table.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isDescendant(of: table) else { return nil }
        return field
    }

    /// The row a field belongs to: the one its edit was started for (never a table index, which
    /// may point at another row after a reload).
    private func editTarget(of field: NSTextField) -> (id: UUID, column: NSUserInterfaceItemIdentifier)? {
        if let edit = activeEdit, edit.field === field { return (edit.id, edit.column) }
        switch field.superview {
        case let cell as TitleCellView: return cell.rowID.map { ($0, .outlineTitle) }
        case let cell as PageCellView: return cell.rowID.map { ($0, .outlinePage) }
        default: return nil
        }
    }

    /// Before the cells are reused for other rows: abort the field editor (the cell must not keep
    /// the typed text for another row) and commit the text to its own row once this SwiftUI
    /// update is over (the model must not change during it).
    private func endActiveEditBeforeReload() {
        let edit = activeEdit ?? editingFieldInTable().flatMap { field in
            editTarget(of: field).map { ActiveEdit(id: $0.id, column: $0.column, field: field) }
        }
        activeEdit = nil
        guard let edit, let field = edit.field, let editor = field.currentEditor() else { return }
        let text = editor.string
        editingCancelled = true
        field.abortEditing()
        if let table, let window = table.window, window.firstResponder !== table {
            window.makeFirstResponder(table)
        }
        editingCancelled = false
        let id = edit.id
        let column = edit.column
        Task { @MainActor [weak self] in
            self?.commit(text, id: id, column: column, field: nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let table, let field = control as? NSTextField, let target = editTarget(of: field) else { return false }

        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            editingCancelled = true
            activeEdit = nil
            field.abortEditing()
            if let superview = field.superview, let row = indexByID[target.id] {
                configure(superview, row: row)
            }
            table.window?.makeFirstResponder(table)
            editingCancelled = false
            return true
        case #selector(NSResponder.insertNewline(_:)):
            table.window?.makeFirstResponder(table)
            return true
        case #selector(NSResponder.insertTab(_:)):
            table.window?.makeFirstResponder(table)
            if target.column == .outlineTitle { beginEditing(target.id, field: .page) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            table.window?.makeFirstResponder(table)
            if target.column == .outlinePage { beginEditing(target.id, field: .title) }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !editingCancelled, let field = notification.object as? NSTextField,
              let target = editTarget(of: field) else { return }
        if activeEdit?.field === field { activeEdit = nil }
        commit(field.stringValue, id: target.id, column: target.column, field: field)
    }

    /// Commits typed text to the row `id` (unknown rows are ignored: deleted meanwhile).
    private func commit(_ text: String, id: UUID, column: NSUserInterfaceItemIdentifier, field: NSTextField?) {
        guard let row = model.row(id) else { return }
        switch column {
        case .outlineTitle:
            guard MuluTOCFormat.oneLine(text) != MuluTOCFormat.oneLine(row.title) else { return }
            if !model.setTitle(id, text) {
                field?.stringValue = row.title
            }
        case .outlinePage:
            let current = model.physicalPage(of: id).map(String.init) ?? ""
            let entered = PageNumberInput.normalize(text)
            guard entered != current else { return }
            if entered.isEmpty {
                if !model.setPhysicalPage(id, nil) { field?.stringValue = current }
            } else if let page = Int(entered), page > 0 {
                if !model.setPhysicalPage(id, page) { field?.stringValue = current }
            } else {
                NSSound.beep()
                field?.stringValue = current
            }
        default:
            break
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0, session.canEdit else { return }
        let targets = session.targetIDs
        let single = session.focusID != nil
        let none = NSEvent.ModifierFlags()

        // The table's own keys are shown next to the items (they only fire while the menu is open).
        menu.addItem(item("编辑标题", #selector(menuEditTitle), enabled: single, key: "\r", modifiers: none))
        menu.addItem(item("设为当前预览页", #selector(menuPin), enabled: single, key: "l"))
        menu.addItem(item("从这一行起按当前预览页校准", #selector(menuCalibrateFromHere),
                          enabled: session.canCalibrateFromHere, key: "l", modifiers: [.command, .option]))
        menu.addItem(item("清除手动页码", #selector(menuClearOverride), enabled: !targets.isEmpty))
        menu.addItem(.separator())
        menu.addItem(item("页码 +1", #selector(menuPagePlus), enabled: !targets.isEmpty, key: "]", modifiers: none))
        menu.addItem(item("页码 −1", #selector(menuPageMinus), enabled: !targets.isEmpty, key: "[", modifiers: none))
        menu.addItem(item("选中本行到末尾", #selector(menuSelectToEnd), enabled: single))
        menu.addItem(.separator())
        menu.addItem(item("添加同级条目", #selector(menuAddSibling), enabled: true, key: "\r"))
        menu.addItem(item("添加子条目", #selector(menuAddChild), enabled: single, key: "\r", modifiers: [.command, .shift]))
        menu.addItem(item("增加缩进", #selector(menuIndent), enabled: model.canIndent(targets), key: "\t", modifiers: none))
        menu.addItem(item("减少缩进", #selector(menuOutdent), enabled: model.canOutdent(targets), key: "\u{19}", modifiers: none))
        menu.addItem(.separator())
        let confirmTitle: String.LocalizationValue = session.targetsAllConfirmed ? "取消核对" : "标为已核对"
        menu.addItem(item(confirmTitle, #selector(menuToggleConfirmed), enabled: !targets.isEmpty, key: " ", modifiers: none))
        menu.addItem(.separator())
        menu.addItem(item("删除", #selector(menuDelete), enabled: !targets.isEmpty, key: "\u{8}", modifiers: none))
        menu.addItem(item("删除但保留子项", #selector(menuDeleteKeepChildren), enabled: !targets.isEmpty,
                          key: "\u{8}", modifiers: [.command, .option]))
    }

    /// The items carry the table's plain keys (↩, Space, ⌫, brackets) for display. Once the menu
    /// has closed (and the chosen item's action has been sent) they are dropped, so a stale menu
    /// can never answer a key press meant for the table or a text field.
    func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            menu.removeAllItems()
        }
    }

    private func item(_ title: String.LocalizationValue, _ action: Selector, enabled: Bool,
                      key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func menuEditTitle() { session.editTitle() }
    @objc private func menuPin() { session.pinToPreviewPage() }
    @objc private func menuCalibrateFromHere() { session.calibrateFromHere() }
    @objc private func menuClearOverride() { session.clearOverride() }
    @objc private func menuPagePlus() { session.shiftPages(by: 1) }
    @objc private func menuPageMinus() { session.shiftPages(by: -1) }
    @objc private func menuSelectToEnd() { session.selectToEnd() }
    @objc private func menuAddSibling() { session.addSibling() }
    @objc private func menuAddChild() { session.addChild() }
    @objc private func menuIndent() { session.indent() }
    @objc private func menuOutdent() { session.outdent() }
    @objc private func menuToggleConfirmed() { session.toggleConfirmed() }
    @objc private func menuDelete() { session.delete(keepChildren: false) }
    @objc private func menuDeleteKeepChildren() { session.delete(keepChildren: true) }
}
