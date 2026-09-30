import Foundation
import MuluCore

/// A problem of a row computed live from the current draft (never stored; GUI_SPEC §4.5).
public enum RowIssue: Sendable, Hashable {
    case emptyTitle
    case noPhysicalPage
    case pageOutOfRange(page: Int, pageCount: Int)
    case pageBeforePrevious(previous: Int)
    /// A top-level title starting with '#' is written with a full-width '＃' (in the Mulu text
    /// format a '#' at column 0 starts a comment). A warning, so the table says what the PDF gets.
    case leadingHash

    /// All but `.pageBeforePrevious` and `.leadingHash` (warnings).
    public var blocksWrite: Bool {
        switch self {
        case .pageBeforePrevious, .leadingHash: return false
        case .emptyTitle, .noPhysicalPage, .pageOutOfRange: return true
        }
    }
}

public enum RowStatus: String, Sendable, Hashable { case ok, doubtful, confirmed, error }

enum RowAnalysis {
    /// Issues of every row. `pageCount <= 0` (document not loaded) skips the range check.
    static func issues(_ draft: OutlineDraft, pageCount: Int, physical: [Int?]) -> [[RowIssue]] {
        var out: [[RowIssue]] = []
        out.reserveCapacity(draft.rows.count)
        var previous: Int? = nil
        for (i, r) in draft.rows.enumerated() {
            var list: [RowIssue] = []
            let title = MuluTOCFormat.oneLine(r.title)
            if title.isEmpty { list.append(.emptyTitle) }
            if r.level == 0 && title.hasPrefix("#") { list.append(.leadingHash) }
            if let p = physical[i] {
                if p < 1 || (pageCount > 0 && p > pageCount) {
                    list.append(.pageOutOfRange(page: p, pageCount: pageCount))
                }
                if let prev = previous, p < prev { list.append(.pageBeforePrevious(previous: prev)) }
                previous = p
            } else {
                list.append(.noPhysicalPage)
            }
            out.append(list)
        }
        return out
    }

    static func status(_ row: OutlineRow, issues: [RowIssue]) -> RowStatus {
        if issues.contains(where: \.blocksWrite) { return .error }
        if row.confirmed { return .confirmed }
        if row.doubts.contains(where: \.isDoubt) || !issues.isEmpty { return .doubtful }
        return .ok
    }
}
