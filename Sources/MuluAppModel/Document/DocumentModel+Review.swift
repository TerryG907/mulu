import Foundation

extension DocumentModel {
    // MARK: - Review (GUI_SPEC §5.8)

    /// Walks the rows (only doubtful and error rows when `onlyDoubtful`) in document order,
    /// starting after the focused row and wrapping around.
    public func startReview(onlyDoubtful: Bool) {
        let rows = draft.rows
        var queue = rows.indices.filter { i in
            !onlyDoubtful || derived.statuses[i] == .doubtful || derived.statuses[i] == .error
        }.map { rows[$0].id }
        if let f = focusedRowID, let fi = index(of: f), let k = queue.firstIndex(where: { (index(of: $0) ?? 0) > fi }) {
            queue = Array(queue[k...] + queue[..<k])
        }
        review = ReviewSession(queue: queue, position: 0, onlyDoubtful: onlyDoubtful, finished: queue.isEmpty)
        showReviewCurrent()
    }

    /// Next (+1) or previous (−1) row of the queue; rows deleted meanwhile are skipped. Moving
    /// past the last row finishes the review; moving back from there returns to it.
    public func reviewMove(_ delta: Int) {
        guard var s = review, delta != 0 else { return }
        let step = delta > 0 ? 1 : -1
        var pos = s.finished ? s.queue.count : s.position
        var remaining = abs(delta)
        while remaining > 0 {
            var next = pos + step
            while next >= 0 && next < s.queue.count && index(of: s.queue[next]) == nil { next += step }
            if next < 0 { break }
            pos = min(next, s.queue.count)
            remaining -= 1
            if pos >= s.queue.count { break }
        }
        if pos >= s.queue.count {
            s.finished = true
            s.position = s.queue.count
        } else {
            s.finished = false
            s.position = max(0, pos)
        }
        review = s
        showReviewCurrent()
    }

    /// Marks the current row as checked (one undo step) and moves to the next one. A row with an
    /// error (no page, empty title, page out of range) is not confirmed: the review stays on it
    /// and this returns false, so a fix made later is not shown as checked unseen.
    @discardableResult
    public func reviewConfirmAndAdvance() -> Bool {
        guard let s = review, let id = s.current else { return false }
        guard let i = index(of: id), derived.statuses[i] != .error else { return false }
        setConfirmed([id], true)
        reviewMove(1)
        return true
    }

    /// Rows the finished (or running) review never queued and nobody has checked: after a pass
    /// over the doubtful rows, the ones OCR typos may still hide in.
    public var reviewUnseenCount: Int {
        guard let s = review else { return 0 }
        let queued = Set(s.queue)
        return draft.rows.count { !queued.contains($0.id) && !$0.confirmed }
    }

    /// Starts a review of the rows the current review did not include (and that are not checked
    /// yet), in document order. Returns false when there are none.
    @discardableResult
    public func continueReviewWithUnseen() -> Bool {
        guard let s = review else { return false }
        let queued = Set(s.queue)
        let queue = draft.rows.filter { !queued.contains($0.id) && !$0.confirmed }.map(\.id)
        guard !queue.isEmpty else { return false }
        review = ReviewSession(queue: queue, position: 0, onlyDoubtful: false, finished: false)
        showReviewCurrent()
        return true
    }

    public func endReview() {
        review = nil
    }

    /// Selects the current row, reveals it and sends the preview to its page.
    func showReviewCurrent() {
        guard let id = review?.current else { return }
        reveal(id)
        select([id], focus: id)
    }

    /// After a draft change: a current row that no longer exists moves on to the next one.
    func normalizeReview() {
        guard var s = review, !s.finished, s.queue.indices.contains(s.position), index(of: s.queue[s.position]) == nil else { return }
        var k = s.position
        while k < s.queue.count && index(of: s.queue[k]) == nil { k += 1 }
        if k >= s.queue.count {
            s.finished = true
            s.position = s.queue.count
        } else {
            s.position = k
        }
        review = s
    }
}
