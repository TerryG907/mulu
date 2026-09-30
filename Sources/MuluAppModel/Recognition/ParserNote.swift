import Foundation
import MuluOCR

/// The English notes the OCR reader and the printed-TOC parser attach to an entry, recognized
/// so the app can say them in Chinese (the verbatim text stays available as the detail). A
/// doubt's detail may hold several notes joined by "; " (and a note may itself contain "; ").
public enum ParserNote: Sendable, Hashable {
    /// The row's page was taken from the next / previous entry (its title when known).
    case noPageUsingNext(String?)
    case noPageUsingPrevious(String?)
    case noPage
    case unnumberedIndentation
    case unnumberedContext
    case levelLowered
    case pageTouchesTitle
    case pageLookAlikes
    case noTitleText
    case twoColumnSplit
    case secondColumn
    case numeralRestored(String)
    case numberingReadAs(String, String)
    case romanNumeralReadAs(String, String)
    case numberingDot
    case pageSplit(String)
    case columnRereadsDisagree
    case columnRereadKept(read: String, kept: String)
    case columnRereadInstead(read: String, before: String)
    case singleLetterRoman
    case droppedFromTitle(String)
    case pageFromGlyph(String)
    case pageFromColumn(String)
    case titleChanged(from: String, to: String)
    case titleFromRegion
    case readAsRomanI
    case readAsArabic1
    case romanPageKept(String, String, kept: String)
    case foundFromHeading(page: String)
    case pageOrder
    case unstableTitle
    case enlargedTitle
    /// Not recognized: shown only in English.
    case other(String)

    private struct Pattern: @unchecked Sendable {
        let regex: Regex<AnyRegexOutput>
        let make: @Sendable ([String?]) -> ParserNote
    }

    private static let end = #"(?=; |$)"#

    private static func pattern(_ body: String, _ make: @escaping @Sendable ([String?]) -> ParserNote) -> Pattern {
        // The patterns are constants; a typo is a programming error caught by the tests.
        Pattern(regex: try! Regex("^" + body + end), make: make)
    }

    private static func literal(_ text: String, _ note: ParserNote) -> Pattern {
        pattern(NSRegularExpression.escapedPattern(for: text), { _ in note })
    }

    /// Longest first where one pattern is a prefix of another.
    private static let patterns: [Pattern] = [
        pattern(#"no page number; using the next entry's page(?: \((?:“(.+?)”|line \d+)\))?"#) { .noPageUsingNext($0[0]) },
        pattern(#"no page number; using the previous entry's page(?: \((?:“(.+?)”|line \d+)\))?"#) { .noPageUsingPrevious($0[0]) },
        literal("no page number", .noPage),
        literal("unnumbered: level from indentation", .unnumberedIndentation),
        literal("unnumbered: level guessed from context", .unnumberedContext),
        pattern(#"level lowered from -?\d+ to -?\d+ \(no parent at level -?\d+\)"#) { _ in .levelLowered },
        literal("page number touches the title", .pageTouchesTitle),
        literal("page number repaired from OCR look-alikes (O/l/I)", .pageLookAlikes),
        literal("no title text", .noTitleText),
        literal("two-column line split", .twoColumnSplit),
        literal("second column of the line", .secondColumn),
        pattern(#"numeral lost by OCR; restored from the neighbouring headings: '(.+?)'"#) { .numeralRestored($0[0] ?? "") },
        pattern(#"numbering '(.+?)' read as (.+?)"#) { .numberingReadAs($0[0] ?? "", $0[1] ?? "") },
        pattern(#"roman numeral '(.+?)' read as (.+?)"#) { .romanNumeralReadAs($0[0] ?? "", $0[1] ?? "") },
        pattern(#"(?:dot after the numbering read as a space|stray dot after the numbering removed)"#) { _ in .numberingDot },
        pattern(#"page number (\S+) was split by OCR"#) { .pageSplit($0[0] ?? "") },
        pattern(#"column re-reads disagree: .+?"#) { _ in .columnRereadsDisagree },
        pattern(#"column re-read gave (\S+); kept (\S+)"#) { .columnRereadKept(read: $0[0] ?? "", kept: $0[1] ?? "") },
        pattern(#"column re-read (\S+) instead of (\S+)"#) { .columnRereadInstead(read: $0[0] ?? "", before: $0[1] ?? "") },
        literal("single-letter roman page number", .singleLetterRoman),
        pattern(#"dropped '(.+?)' \(the page number misread\) from the title"#) { .droppedFromTitle($0[0] ?? "") },
        pattern(#"page number (\S+) read from the glyph shape \(OCR found no text\)"#) { .pageFromGlyph($0[0] ?? "") },
        pattern(#"page number (\S+) read from the whole page-number column \(not read on its own\)"#) { .pageFromColumn($0[0] ?? "") },
        literal(TOCPageReader.unstableNote, .unstableTitle),
        literal(TOCPageReader.enlargedTitleNote, .enlargedTitle),
        literal("title read from the title region alone (the line was read without it)", .titleFromRegion),
        pattern(#"title [^:']+: '(.*?)' → '(.*?)'"#) { .titleChanged(from: $0[0] ?? "", to: $0[1] ?? "") },
        literal("read as i; the printed order says arabic 1", .readAsRomanI),
        literal("read as 1; the printed order says roman i", .readAsArabic1),
        pattern(#"roman page number read as (\S+) and (\S+); kept (\S+)"#) { .romanPageKept($0[0] ?? "", $0[1] ?? "", kept: $0[2] ?? "") },
        pattern(#"page (\S+) found from the heading on the body page.*?"#) { .foundFromHeading(page: $0[0] ?? "") },
        pattern(#"page order: .*?"#) { _ in .pageOrder },
    ]

    /// The notes of a doubt's detail, in order; unknown ones as `.other`.
    public static func parse(_ detail: String) -> [ParserNote] {
        var out: [ParserNote] = []
        var rest = Substring(detail)
        while !rest.isEmpty {
            if let (note, length) = match(rest) {
                out.append(note)
                rest = rest.dropFirst(length)
            } else if let separator = rest.range(of: "; ") {
                out.append(.other(String(rest[..<separator.lowerBound])))
                rest = rest[separator.lowerBound...]
            } else {
                out.append(.other(String(rest)))
                rest = ""
            }
            if rest.hasPrefix("; ") { rest = rest.dropFirst(2) }
        }
        return out
    }

    private static func match(_ text: Substring) -> (ParserNote, Int)? {
        for p in patterns {
            guard let m = try? p.regex.prefixMatch(in: text), !m.range.isEmpty else { continue }
            let captures = (1..<m.output.count).map { m.output[$0].substring.map(String.init) }
            return (p.make(captures), text.distance(from: m.range.lowerBound, to: m.range.upperBound))
        }
        return nil
    }

    /// The first "page N" of an OCR warning ("ocr: page 5: two-column layout …" → 5).
    public static func pageNumber(in detail: String) -> Int? {
        guard let regex = try? Regex(#"\bpage (\d+)\b"#), let m = try? regex.firstMatch(in: detail),
              m.output.count > 1, let digits = m.output[1].substring else { return nil }
        return Int(digits)
    }

    /// An advisory's English text without the advice that only makes sense on the command line
    /// ("review the TOC with --toc-out", "pass --roman-offset N …") and without the "ocr: " tag.
    public static func withoutCLIAdvice(_ detail: String) -> String {
        var text = detail
        if text.hasPrefix("ocr: ") { text.removeFirst(5) }
        for advice in ["; review the TOC with --toc-out", "; pass --roman-offset N to include them"] {
            text = text.replacingOccurrences(of: advice, with: "")
        }
        return text
    }
}
