import Foundation

/// physical page = printed page + offset (+ the row's section shift); roman front-matter
/// pages use `romanOffset` (nil: they have no physical page). Part of the undoable draft.
public struct PageMapping: Sendable, Hashable, Codable {
    public var offset: Int
    public var romanOffset: Int?

    public init(offset: Int = 0, romanOffset: Int? = nil) {
        self.offset = offset
        self.romanOffset = romanOffset
    }

    /// GUI_SPEC §4.3. Not clamped to the document: out-of-range pages are row issues.
    public func physicalPage(for row: OutlineRow) -> Int? {
        if let m = row.manualPage { return m }
        guard let p = row.printedPage else { return nil }
        switch p.style {
        case .arabic:
            return p.value + offset + row.sectionShift
        case .roman:
            guard let r = romanOffset else { return nil }
            return p.value + r + row.sectionShift
        }
    }
}
