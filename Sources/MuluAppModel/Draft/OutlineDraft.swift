import Foundation
import MuluCore

/// The undoable unit: the rows (flat, pre-order, with levels) plus the page mapping.
///
/// Invariant (checked after every public operation): when non-empty, `rows[0].level == 0`,
/// and `0 <= rows[i].level <= rows[i-1].level + 1` for every i >= 1.
public struct OutlineDraft: Sendable, Hashable, Codable {
    public var rows: [OutlineRow]
    public var mapping: PageMapping

    public init(rows: [OutlineRow] = [], mapping: PageMapping = PageMapping()) {
        self.rows = rows
        self.mapping = mapping
    }

    public static func levelsAreValid(_ rows: [OutlineRow]) -> Bool {
        var prev = -1
        for r in rows {
            guard r.level >= 0, r.level <= prev + 1 else { return false }
            prev = r.level
        }
        return true
    }

    /// Clamps levels so the invariant holds (first row 0, each row at most one deeper than the previous).
    public static func clampedLevels(_ rows: [OutlineRow]) -> [OutlineRow] {
        var out = rows
        var prev = -1
        for i in out.indices {
            out[i].level = max(0, min(out[i].level, prev + 1))
            prev = out[i].level
        }
        return out
    }

    /// One entry per row (title normalized with MuluTOCFormat.oneLine, level, physical page, line = index + 1);
    /// nil when any row has no physical page.
    public func outputEntries() -> [TOCEntry]? {
        var out: [TOCEntry] = []
        out.reserveCapacity(rows.count)
        for (i, r) in rows.enumerated() {
            guard let p = mapping.physicalPage(for: r) else { return nil }
            out.append(TOCEntry(title: MuluTOCFormat.oneLine(r.title), level: r.level, page: p, line: i + 1))
        }
        return out
    }

    /// What would be written, row by row: the dirty flag compares these (GUI_SPEC §4.8).
    struct ProjectionItem: Hashable, Sendable {
        var title: String
        var level: Int
        var page: Int?
    }

    func projection() -> [ProjectionItem] {
        rows.map { ProjectionItem(title: MuluTOCFormat.oneLine($0.title), level: $0.level, page: mapping.physicalPage(for: $0)) }
    }
}
