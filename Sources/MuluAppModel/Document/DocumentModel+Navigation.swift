import Foundation
import MuluCore

extension DocumentModel {
    // MARK: - Finding rows (status bar, "Next Doubtful Entry")

    /// The next row after the focused one (wrapping around) whose status is in `statuses`.
    public func nextRow(withStatus statuses: Set<RowStatus>, after id: UUID?) -> UUID? {
        let rows = draft.rows
        guard !rows.isEmpty else { return nil }
        let start = id.flatMap { index(of: $0) }.map { $0 + 1 } ?? 0
        for k in 0..<rows.count {
            let i = (start + k) % rows.count
            if statuses.contains(derived.statuses[i]) { return rows[i].id }
        }
        return nil
    }

    /// Selects, reveals and previews the next row with one of `statuses`; false when there is none.
    @discardableResult
    public func selectNextRow(withStatus statuses: Set<RowStatus>) -> Bool {
        guard let id = nextRow(withStatus: statuses, after: focusedRowID) else { return false }
        reveal(id)
        select([id], focus: id)
        return true
    }

    /// Selects the focused row and every row after it (hidden ones too), keeping the focus: the
    /// usual target of a page shift when the offset changes from one chapter on.
    @discardableResult
    public func selectToEnd() -> Bool {
        guard let f = focusedRowID, let i = index(of: f) else { return false }
        select(Set(draft.rows[i...].map(\.id)), focus: f)
        return true
    }

    // MARK: - Calibrating from one row on

    /// The focused row can anchor "calibrate from this row on": it follows the offset (no fixed
    /// page) and has a physical page.
    public func canCalibrateFrom(_ id: UUID) -> Bool {
        guard let r = row(id) else { return false }
        return r.manualPage == nil && physicalPage(of: id) != nil
    }

    /// The offset changes in the middle of the book (plates without page numbers, a second
    /// part): moves the row and every later row that follows the offset by the same amount,
    /// so the row lands on `physicalPage`, through the section shift (one undo step). Rows with
    /// a fixed page and rows before it stay; the global offset stays.
    @discardableResult
    public func calibrateFrom(_ id: UUID, physicalPage target: Int) -> Bool {
        guard canCalibrateFrom(id), target >= 1, let i = index(of: id), let current = physicalPage(of: id) else { return false }
        let delta = target - current
        guard delta != 0 else { return false }
        return edit(ActionName.calibrateFromHere) { d in
            var changed = false
            for k in i..<d.rows.count where d.rows[k].manualPage == nil && d.mapping.physicalPage(for: d.rows[k]) != nil {
                d.rows[k].sectionShift += delta
                changed = true
            }
            d.rows[i].clearDoubts(.page)
            return changed
        }
    }
}
