import Foundation

/// One visible row of the editor table (rows under a collapsed ancestor are skipped).
public struct DisplayRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// Position in `draft.rows`.
    public let index: Int
    public let level: Int
    public let title: String
    public let printedPage: PrintedPageRef?
    public let physicalPage: Int?
    public let pageOverride: Bool
    public let sectionShift: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let status: RowStatus
    public let doubts: [DoubtReason]
    public let issues: [RowIssue]
}

public struct DraftCounts: Sendable, Hashable {
    public var rows: Int
    /// status == .doubtful
    public var doubtful: Int
    public var confirmed: Int
    /// status == .error
    public var errors: Int

    public init(rows: Int = 0, doubtful: Int = 0, confirmed: Int = 0, errors: Int = 0) {
        self.rows = rows
        self.doubtful = doubtful
        self.confirmed = confirmed
        self.errors = errors
    }
}

/// Everything derived from (draft, page count, collapsed rows); recomputed in full after each
/// change (fine for a few thousand rows).
struct DerivedState {
    var displayRows: [DisplayRow] = []
    var counts = DraftCounts()
    var indexByID: [UUID: Int] = [:]
    var physical: [Int?] = []
    var issues: [[RowIssue]] = []
    var statuses: [RowStatus] = []

    init() {}

    init(draft: OutlineDraft, pageCount: Int, collapsed: Set<UUID>) {
        let rows = draft.rows
        physical = rows.map { draft.mapping.physicalPage(for: $0) }
        issues = RowAnalysis.issues(draft, pageCount: pageCount, physical: physical)
        statuses = rows.indices.map { RowAnalysis.status(rows[$0], issues: issues[$0]) }
        indexByID.reserveCapacity(rows.count)
        for (i, r) in rows.enumerated() { indexByID[r.id] = i }
        var c = DraftCounts(rows: rows.count)
        for s in statuses {
            switch s {
            case .doubtful: c.doubtful += 1
            case .confirmed: c.confirmed += 1
            case .error: c.errors += 1
            case .ok: break
            }
        }
        counts = c
        var out: [DisplayRow] = []
        out.reserveCapacity(rows.count)
        // Rows deeper than this level are hidden (under a collapsed ancestor).
        var hideBelow = Int.max
        for (i, r) in rows.enumerated() {
            if r.level > hideBelow { continue }
            hideBelow = Int.max
            let hasChildren = i + 1 < rows.count && rows[i + 1].level > r.level
            let expanded = !collapsed.contains(r.id)
            out.append(DisplayRow(
                id: r.id, index: i, level: r.level, title: r.title, printedPage: r.printedPage, physicalPage: physical[i],
                pageOverride: r.pageOverride, sectionShift: r.sectionShift, hasChildren: hasChildren, isExpanded: expanded,
                status: statuses[i], doubts: r.doubts, issues: issues[i]))
            if hasChildren && !expanded { hideBelow = r.level }
        }
        displayRows = out
    }
}
