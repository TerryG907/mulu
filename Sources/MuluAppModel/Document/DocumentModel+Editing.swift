import Foundation
import MuluCore

/// Undo action names (GUI_SPEC §4.7): Chinese keys looked up in the app's main bundle, so the
/// keys must also be in Sources/MuluApp/Resources/Localizable.xcstrings.
enum ActionName {
    static var setTitle: String { String(localized: "修改标题") }
    static var setPage: String { String(localized: "修改页码") }
    static var pinToPreview: String { String(localized: "设为当前预览页") }
    static var clearOverride: String { String(localized: "清除手动页码") }
    static var indent: String { String(localized: "增加缩进") }
    static var outdent: String { String(localized: "减少缩进") }
    static var moveUp: String { String(localized: "上移") }
    static var moveDown: String { String(localized: "下移") }
    static var add: String { String(localized: "添加条目") }
    static var delete: String { String(localized: "删除") }
    static var offset: String { String(localized: "页码偏移") }
    static var sectionShift: String { String(localized: "分段偏移") }
    static var calibrate: String { String(localized: "校准偏移") }
    static var calibrateFromHere: String { String(localized: "从这一行起校准") }
    static var confirm: String { String(localized: "标为已核对") }
    static var importOutline: String { String(localized: "导入目录") }
    static var useRecognition: String { String(localized: "使用识别结果") }
}

extension OutlineRow {
    mutating func clearDoubts(_ scope: DoubtReason.Scope) {
        doubts.removeAll { $0.scope == scope }
    }
}

extension DocumentModel {
    // MARK: - Editing: each call is at most one undo step; returns whether the draft changed

    @discardableResult
    public func setTitle(_ id: UUID, _ title: String) -> Bool {
        guard let i = index(of: id) else { return false }
        let t = MuluTOCFormat.oneLine(title)
        guard t != MuluTOCFormat.oneLine(draft.rows[i].title) else { return false }
        return edit(ActionName.setTitle) { d in
            d.rows[i].title = t
            d.rows[i].clearDoubts(.title)
            return true
        }
    }

    /// A positive page fixes the row there; nil clears the manual page; zero or negative is refused.
    @discardableResult
    public func setPhysicalPage(_ id: UUID, _ page: Int?) -> Bool {
        guard let page else { return clearOverride([id]) }
        return pin(id, to: page, action: ActionName.setPage)
    }

    @discardableResult
    public func setPrintedPage(_ id: UUID, _ page: PrintedPageRef?) -> Bool {
        guard let i = index(of: id) else { return false }
        return edit(ActionName.setPage) { d in
            d.rows[i].printedPage = page
            d.rows[i].clearDoubts(.page)
            return true
        }
    }

    @discardableResult
    public func pinToPreviewPage(_ id: UUID) -> Bool {
        pin(id, to: previewPage, action: ActionName.pinToPreview)
    }

    private func pin(_ id: UUID, to page: Int, action: String) -> Bool {
        guard let i = index(of: id), page >= 1, page <= TOCParser.maxPage else { return false }
        return edit(action) { d in
            d.rows[i].manualPage = page
            d.rows[i].clearDoubts(.page)
            return true
        }
    }

    @discardableResult
    public func clearOverride(_ ids: Set<UUID>) -> Bool {
        edit(ActionName.clearOverride) { d in
            var changed = false
            for i in d.rows.indices where ids.contains(d.rows[i].id) && d.rows[i].manualPage != nil {
                d.rows[i].manualPage = nil
                d.rows[i].clearDoubts(.page)
                changed = true
            }
            return changed
        }
    }

    @discardableResult
    public func indent(_ ids: Set<UUID>) -> Bool {
        edit(ActionName.indent) { DraftOps.indent(&$0.rows, ids) }
    }

    @discardableResult
    public func outdent(_ ids: Set<UUID>) -> Bool {
        edit(ActionName.outdent) { DraftOps.outdent(&$0.rows, ids) }
    }

    @discardableResult
    public func moveUp(_ ids: Set<UUID>) -> Bool {
        edit(ActionName.moveUp) { DraftOps.moveUp(&$0.rows, ids) }
    }

    @discardableResult
    public func moveDown(_ ids: Set<UUID>) -> Bool {
        edit(ActionName.moveDown) { DraftOps.moveDown(&$0.rows, ids) }
    }

    /// Adds a sibling after the row's block (at the end, level 0, when `id` is nil or unknown),
    /// pointing at the preview page; selects it and asks the table to edit its title.
    @discardableResult
    public func addSibling(after id: UUID?, title: String = "") -> UUID {
        let row = newRow(title)
        var d = draft
        DraftOps.insertSibling(&d.rows, after: id.flatMap { index(of: $0) }, row)
        commit(d, action: ActionName.add, selection: [row.id], focus: .some(row.id))
        requestEdit(row.id, field: .title)
        return row.id
    }

    /// Adds a last child of the row (at the end, level 0, when `id` is unknown).
    @discardableResult
    public func addChild(of id: UUID, title: String = "") -> UUID {
        guard let i = index(of: id) else { return addSibling(after: nil, title: title) }
        let row = newRow(title)
        var d = draft
        DraftOps.insertChild(&d.rows, of: i, row)
        commit(d, action: ActionName.add, selection: [row.id], focus: .some(row.id))
        reveal(row.id)
        requestEdit(row.id, field: .title)
        return row.id
    }

    private func newRow(_ title: String) -> OutlineRow {
        OutlineRow(title: MuluTOCFormat.oneLine(title), level: 0, manualPage: max(1, previewPage))
    }

    /// Deletes the rows with their children, or (keepChildren) only the rows, lifting their
    /// children one level. Selects the row now at the first deleted position (else the last row).
    @discardableResult
    public func delete(_ ids: Set<UUID>, keepChildren: Bool = false) -> Bool {
        var d = draft
        guard let pos = DraftOps.delete(&d.rows, ids, keepChildren: keepChildren) else { return false }
        let next = d.rows.isEmpty ? nil : d.rows[min(pos, d.rows.count - 1)].id
        return commit(d, action: ActionName.delete, selection: next.map { [$0] } ?? [], focus: .some(next))
    }

    @discardableResult
    public func setConfirmed(_ ids: Set<UUID>, _ confirmed: Bool) -> Bool {
        edit(ActionName.confirm) { d in
            var changed = false
            for i in d.rows.indices where ids.contains(d.rows[i].id) && d.rows[i].confirmed != confirmed {
                d.rows[i].confirmed = confirmed
                changed = true
            }
            return changed
        }
    }

    /// Moves the pages of the rows and all their children by `delta`: fixed pages move
    /// themselves, printed pages through the section shift; rows without a page stay.
    @discardableResult
    public func shiftPages(_ ids: Set<UUID>, by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        return edit(ActionName.sectionShift) { d in
            var changed = false
            for i in DraftOps.blockIndices(d.rows, ids) {
                if let m = d.rows[i].manualPage {
                    d.rows[i].manualPage = m + delta
                } else if d.mapping.physicalPage(for: d.rows[i]) != nil {
                    d.rows[i].sectionShift += delta
                } else {
                    continue
                }
                d.rows[i].clearDoubts(.page)
                changed = true
            }
            return changed
        }
    }

    @discardableResult
    public func setOffset(_ offset: Int) -> Bool {
        guard abs(offset) <= TOCParser.maxPage, offset != draft.mapping.offset else { return false }
        var d = draft
        d.mapping.offset = offset
        return commit(d, action: ActionName.offset, offsetInfo: .some(OffsetInfo(source: .manual)))
    }

    @discardableResult
    public func setRomanOffset(_ offset: Int?) -> Bool {
        if let o = offset, abs(o) > TOCParser.maxPage { return false }
        guard offset != draft.mapping.romanOffset else { return false }
        var d = draft
        d.mapping.romanOffset = offset
        return commit(d, action: ActionName.offset)
    }

    /// offset = physicalPage − printed page − section shift of the row (an arabic printed
    /// page, not fixed): the row then lands on `physicalPage`.
    @discardableResult
    public func calibrateOffset(using id: UUID, physicalPage: Int) -> Bool {
        guard canCalibrate(using: id), physicalPage >= 1, let i = index(of: id), let printed = draft.rows[i].printedPage else { return false }
        let offset = physicalPage - printed.value - draft.rows[i].sectionShift
        guard abs(offset) <= TOCParser.maxPage else { return false }
        var d = draft
        d.mapping.offset = offset
        d.rows[i].clearDoubts(.page)
        return commit(d, action: ActionName.calibrate,
                      offsetInfo: .some(OffsetInfo(source: .calibrated, calibratedFromPage: physicalPage)))
    }

    public func replaceDraft(_ draft: OutlineDraft, actionName: String) {
        var d = draft
        d.rows = OutlineDraft.clampedLevels(d.rows)
        commit(d, action: actionName)
    }

    public func canIndent(_ ids: Set<UUID>) -> Bool {
        var rows = draft.rows
        return DraftOps.indent(&rows, ids)
    }

    public func canOutdent(_ ids: Set<UUID>) -> Bool {
        var rows = draft.rows
        return DraftOps.outdent(&rows, ids)
    }

    public func canMoveUp(_ ids: Set<UUID>) -> Bool {
        var rows = draft.rows
        return DraftOps.moveUp(&rows, ids)
    }

    public func canMoveDown(_ ids: Set<UUID>) -> Bool {
        var rows = draft.rows
        return DraftOps.moveDown(&rows, ids)
    }

    public func canCalibrate(using id: UUID) -> Bool {
        guard let r = row(id) else { return false }
        return r.printedPage?.style == .arabic && r.manualPage == nil
    }

    // MARK: - Merging new rows (recognition, import)

    /// New rows join the draft (GUI_SPEC §5.3 step 8): replace, or append / insert after the
    /// focused row's block with the insertion level added, section shifts compensating for
    /// a different offset so every new row keeps its physical page. With an empty draft every
    /// mode replaces.
    static func merge(_ incoming: [OutlineRow], mapping inMap: PageMapping, into d: OutlineDraft, mode: MergeMode,
                      after focus: Int?) -> OutlineDraft {
        if mode == .replace || d.rows.isEmpty {
            return OutlineDraft(rows: OutlineDraft.clampedLevels(incoming), mapping: inMap)
        }
        var out = d
        let position: Int
        let base: Int
        if mode == .insertAfterFocused, let f = focus, d.rows.indices.contains(f) {
            position = DraftOps.blockEnd(d.rows, f)
            base = d.rows[f].level
        } else {
            position = d.rows.count
            base = 0
        }
        if out.mapping.romanOffset == nil, let r = inMap.romanOffset { out.mapping.romanOffset = r }
        let arabicDelta = inMap.offset - out.mapping.offset
        let romanDelta: Int = {
            guard let a = inMap.romanOffset, let b = out.mapping.romanOffset else { return 0 }
            return a - b
        }()
        let adjusted = OutlineDraft.clampedLevels(incoming).map { r -> OutlineRow in
            var r = r
            r.level += base
            if r.manualPage == nil, let p = r.printedPage {
                r.sectionShift += p.style == .arabic ? arabicDelta : romanDelta
            }
            return r
        }
        out.rows.insert(contentsOf: adjusted, at: position)
        out.rows = OutlineDraft.clampedLevels(out.rows)
        return out
    }
}
