import Foundation

/// Tree operations on the flat row list (GUI_SPEC §5.7). Pure: every function either leaves
/// `rows` untouched and returns false/nil, or changes it and keeps the level invariant.
///
/// Terms: the *block* of a row is the row plus its descendants (the rows right after it with
/// a greater level); the *heads* of a selection are the selected rows none of whose ancestors
/// is selected.
enum DraftOps {
    /// End (exclusive) of the block of row `i`.
    static func blockEnd(_ rows: [OutlineRow], _ i: Int) -> Int {
        var j = i + 1
        while j < rows.count && rows[j].level > rows[i].level { j += 1 }
        return j
    }

    /// Indices of the selected rows none of whose ancestors is selected, in document order.
    static func blockHeads(_ rows: [OutlineRow], _ ids: Set<UUID>) -> [Int] {
        var heads: [Int] = []
        var coveredUntil = 0
        for i in rows.indices where i >= coveredUntil && ids.contains(rows[i].id) {
            heads.append(i)
            coveredUntil = blockEnd(rows, i)
        }
        return heads
    }

    /// Indices of the selected rows and all their descendants, in document order.
    static func blockIndices(_ rows: [OutlineRow], _ ids: Set<UUID>) -> [Int] {
        blockHeads(rows, ids).flatMap { Array($0..<blockEnd(rows, $0)) }
    }

    /// Index of the parent of row `i` (nil for level-0 rows).
    static func parentIndex(_ rows: [OutlineRow], _ i: Int) -> Int? {
        let level = rows[i].level
        guard level > 0 else { return nil }
        var k = i - 1
        while k >= 0 {
            if rows[k].level < level { return k }
            k -= 1
        }
        return nil
    }

    /// Indices of the ancestors of row `i`, nearest first.
    static func ancestorIndices(_ rows: [OutlineRow], _ i: Int) -> [Int] {
        var out: [Int] = []
        var k = i
        while let p = parentIndex(rows, k) {
            out.append(p)
            k = p
        }
        return out
    }

    /// Each head whose level is <= the previous row's level moves one level deeper with its
    /// block (it becomes the last child of its previous sibling). Order never changes.
    @discardableResult
    static func indent(_ rows: inout [OutlineRow], _ ids: Set<UUID>) -> Bool {
        var changed = false
        for i in blockHeads(rows, ids) where i > 0 && rows[i].level <= rows[i - 1].level {
            for k in i..<blockEnd(rows, i) { rows[k].level += 1 }
            changed = true
        }
        return changed
    }

    /// Each head with level > 0 moves one level up with its block. Order never changes, so
    /// the siblings that followed it become its children (as in indented text).
    @discardableResult
    static func outdent(_ rows: inout [OutlineRow], _ ids: Set<UUID>) -> Bool {
        var changed = false
        for i in blockHeads(rows, ids) where rows[i].level > 0 {
            for k in i..<blockEnd(rows, i) { rows[k].level -= 1 }
            changed = true
        }
        return changed
    }

    /// The heads as one movable unit: consecutive siblings (same level, each starting where
    /// the previous block ends). nil when the selection is not such a group.
    static func moveUnit(_ rows: [OutlineRow], _ ids: Set<UUID>) -> (start: Int, end: Int, level: Int)? {
        let heads = blockHeads(rows, ids)
        guard let first = heads.first else { return nil }
        let level = rows[first].level
        var end = blockEnd(rows, first)
        for h in heads.dropFirst() {
            guard h == end, rows[h].level == level else { return nil }
            end = blockEnd(rows, h)
        }
        return (first, end, level)
    }

    /// Swaps the unit with the block of its previous sibling (never across parents).
    @discardableResult
    static func moveUp(_ rows: inout [OutlineRow], _ ids: Set<UUID>) -> Bool {
        guard let u = moveUnit(rows, ids), u.start > 0 else { return false }
        var k = u.start - 1
        while k >= 0 && rows[k].level > u.level { k -= 1 }
        guard k >= 0, rows[k].level == u.level else { return false }
        rows = Array(rows[..<k]) + Array(rows[u.start..<u.end]) + Array(rows[k..<u.start]) + Array(rows[u.end...])
        return true
    }

    /// Swaps the unit with the block of its next sibling (never across parents).
    @discardableResult
    static func moveDown(_ rows: inout [OutlineRow], _ ids: Set<UUID>) -> Bool {
        guard let u = moveUnit(rows, ids), u.end < rows.count, rows[u.end].level == u.level else { return false }
        let nextEnd = blockEnd(rows, u.end)
        rows = Array(rows[..<u.start]) + Array(rows[u.end..<nextEnd]) + Array(rows[u.start..<u.end]) + Array(rows[nextEnd...])
        return true
    }

    /// Inserts `row` as a sibling after the block of row `index` (at the end, level 0, when nil).
    /// Returns its index.
    @discardableResult
    static func insertSibling(_ rows: inout [OutlineRow], after index: Int?, _ row: OutlineRow) -> Int {
        var r = row
        guard let i = index, rows.indices.contains(i) else {
            r.level = 0
            rows.append(r)
            return rows.count - 1
        }
        r.level = rows[i].level
        let pos = blockEnd(rows, i)
        rows.insert(r, at: pos)
        return pos
    }

    /// Inserts `row` as the last child of row `index`. Returns its index.
    @discardableResult
    static func insertChild(_ rows: inout [OutlineRow], of i: Int, _ row: OutlineRow) -> Int {
        var r = row
        r.level = rows[i].level + 1
        let pos = blockEnd(rows, i)
        rows.insert(r, at: pos)
        return pos
    }

    /// Deletes the selected rows with their descendants, or (keepChildren) only the selected
    /// rows, lifting each one's descendants by one level. Returns the index of the first
    /// deleted row, nil when nothing matched.
    @discardableResult
    static func delete(_ rows: inout [OutlineRow], _ ids: Set<UUID>, keepChildren: Bool) -> Int? {
        if keepChildren {
            let targets = rows.filter { ids.contains($0.id) }.map(\.id)
            guard !targets.isEmpty else { return nil }
            var first: Int? = nil
            for id in targets {
                guard let i = rows.firstIndex(where: { $0.id == id }) else { continue }
                let end = blockEnd(rows, i)
                for k in (i + 1)..<max(i + 1, end) { rows[k].level -= 1 }
                rows.remove(at: i)
                first = min(first ?? i, i)
            }
            return first
        }
        let heads = blockHeads(rows, ids)
        guard let first = heads.first else { return nil }
        for h in heads.reversed() { rows.removeSubrange(h..<blockEnd(rows, h)) }
        return first
    }
}
