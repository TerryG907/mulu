import Foundation

/// A page number as printed in the book's TOC: arabic (body) or roman (front matter).
public struct PrintedPageRef: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable { case arabic, roman }
    public var style: Style
    public var value: Int
    /// "12" or "iv" as printed.
    public var display: String

    public init(style: Style, value: Int, display: String? = nil) {
        self.style = style
        self.value = value
        self.display = display ?? (style == .arabic ? String(value) : PrintedPageRef.roman(value))
    }

    /// Lower-case roman numeral ("iv"); the decimal digits for values outside 1...3999.
    static func roman(_ n: Int) -> String {
        guard n >= 1, n <= 3999 else { return String(n) }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var rest = n
        var out = ""
        for (v, s) in table {
            while rest >= v {
                out += s
                rest -= v
            }
        }
        return out
    }
}

/// Why a row needs a human look (set by recognition or import, stored in the row, undoable).
public struct DoubtReason: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case unstableTitle, enlargedTitle, lowConfidence, pageOrder, noPage,
             locatedFromHeading, unresolvedDestination, importWarning
    }
    /// What an edit must touch to resolve the reason (GUI_SPEC §4.5): `setTitle` clears
    /// `.title`, any page edit clears `.page`; `.both` only goes away by confirming the row.
    public enum Scope: String, Sendable, Hashable, Codable { case title, page, both }

    public var kind: Kind
    /// Verbatim English note; may be empty.
    public var detail: String
    /// `.lowConfidence` only.
    public var confidence: Double?

    public init(kind: Kind, detail: String = "", confidence: Double? = nil) {
        self.kind = kind
        self.detail = detail
        self.confidence = confidence
    }

    public var scope: Scope {
        switch kind {
        case .unstableTitle, .enlargedTitle: return .title
        case .lowConfidence, .importWarning: return .both
        case .pageOrder, .noPage, .locatedFromHeading, .unresolvedDestination: return .page
        }
    }

    /// False for `.locatedFromHeading` (a hint, not a doubt).
    public var isDoubt: Bool { kind != .locatedFromHeading }
}

/// One outline entry of the draft. The draft is a flat list in display (pre-order) order;
/// `level` gives the hierarchy (GUI_SPEC §4.2).
public struct OutlineRow: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var title: String
    /// 0-based.
    public var level: Int
    /// The page printed in the TOC (recognition, pasted text, pdfdir import).
    public var printedPage: PrintedPageRef?
    /// Extra offset of this row (section offset), added to the mapping's offset.
    public var sectionShift: Int
    /// A physical page (1-based) fixed by hand; it ignores the offsets.
    public var manualPage: Int?
    public var doubts: [DoubtReason]
    /// A human checked this row.
    public var confirmed: Bool

    public var pageOverride: Bool { manualPage != nil }

    public init(id: UUID = UUID(), title: String, level: Int, printedPage: PrintedPageRef? = nil,
                sectionShift: Int = 0, manualPage: Int? = nil, doubts: [DoubtReason] = [], confirmed: Bool = false) {
        self.id = id
        self.title = title
        self.level = level
        self.printedPage = printedPage
        self.sectionShift = sectionShift
        self.manualPage = manualPage
        self.doubts = doubts
        self.confirmed = confirmed
    }
}
