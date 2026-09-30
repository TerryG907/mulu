import Foundation
import MuluCore
import MuluOCR

/// Turns a parsed printed TOC into draft rows. Every entry becomes a row, including those
/// `mulu auto` leaves out (unmapped roman front matter): they carry `.noPage`.
enum DraftBuilder {
    struct Built {
        var rows: [OutlineRow]
        /// Source lines of the entries `mulu auto` counts as doubtful, in entry order.
        var doubtful: [Int]
    }

    static let locatedNote = "found from the heading on the body page"

    /// `unstable` / `enlarged`: 1-based OCR lines whose title the title vote flagged.
    static func rows(from result: PrintedTOCResult, mapping: PageMapping, unstable: Set<Int>, enlarged: Set<Int>) -> Built {
        let violations = Set(result.orderViolations)
        var rows: [OutlineRow] = []
        var doubtful: [Int] = []
        // Notes point at other entries by parser input line ("(line 6)"), a number the app never
        // shows: name the entry instead.
        var titleByLine: [Int: String] = [:]
        for e in result.entries {
            for l in e.lines where titleByLine[l] == nil { titleByLine[l] = MuluTOCFormat.oneLine(e.title) }
        }
        for var e in result.entries {
            e.notes = e.notes.map { namingLines($0, titleByLine) }
            // The same classification as `mulu auto` (GUI_SPEC §4.5): an unstable title only,
            // else an enlarged-crop title only, else low confidence, page order, no page.
            let romanLeftOut = e.physicalPage == nil && e.printedPage?.style == .roman && mapping.romanOffset == nil
            var doubts: [DoubtReason] = []
            if e.lines.contains(where: unstable.contains) {
                doubts.append(DoubtReason(kind: .unstableTitle, detail: TOCPageReader.unstableNote))
                if !romanLeftOut { doubtful.append(e.line) }
            } else if e.lines.contains(where: enlarged.contains) {
                doubts.append(DoubtReason(kind: .enlargedTitle, detail: TOCPageReader.enlargedTitleNote))
                if !romanLeftOut { doubtful.append(e.line) }
            } else {
                let low = e.confidence < result.options.lowConfidence
                let order = violations.contains(e.line)
                if low {
                    doubts.append(DoubtReason(kind: .lowConfidence, detail: e.notes.map(MuluTOCFormat.oneLine).joined(separator: "; "),
                                              confidence: e.confidence))
                }
                if order {
                    let note = e.notes.last { $0.hasPrefix("page order:") } ?? "page order"
                    doubts.append(DoubtReason(kind: .pageOrder, detail: note))
                }
                if e.physicalPage == nil {
                    doubts.append(DoubtReason(kind: .noPage, detail: e.notes.last ?? "no page"))
                }
                if !romanLeftOut && (low || order || e.physicalPage == nil) { doubtful.append(e.line) }
            }
            if let note = e.notes.last(where: { $0.contains(locatedNote) }) {
                doubts.append(DoubtReason(kind: .locatedFromHeading, detail: note))
            }
            var printed: PrintedPageRef? = nil
            if let p = e.printedPage {
                switch p.style {
                case .arabic: printed = PrintedPageRef(style: .arabic, value: p.value, display: p.display)
                case .roman: printed = PrintedPageRef(style: .roman, value: p.value, display: p.display)
                case .prefixed: printed = nil  // appendix pagination ("A1"): never mapped
                }
            }
            var row = OutlineRow(title: e.title, level: e.level, printedPage: printed, doubts: doubts)
            // A page the printed number does not give (found from a heading on a body page, or
            // taken over from a neighbour in another numbering) is kept as a fixed page.
            if let phys = e.physicalPage, mapping.physicalPage(for: row) != phys {
                row.manualPage = phys
            }
            rows.append(row)
        }
        return Built(rows: OutlineDraft.clampedLevels(rows), doubtful: doubtful)
    }

    /// "… (line 6)" → "… (“第二章 方法”)" when line 6 belongs to an entry with a title.
    static func namingLines(_ note: String, _ titleByLine: [Int: String]) -> String {
        guard note.contains("(line ") else { return note }
        var out = ""
        var rest = Substring(note)
        while let open = rest.range(of: "(line ") {
            out += rest[..<open.lowerBound]
            let tail = rest[open.upperBound...]
            let digits = tail.prefix { $0.isASCII && $0.isNumber }
            let afterDigits = tail.dropFirst(digits.count)
            if let n = Int(digits), afterDigits.first == ")", let title = titleByLine[n], !title.isEmpty {
                out += "(“\(title)”)"
                rest = afterDigits.dropFirst()
            } else {
                out += rest[open]
                rest = tail
            }
        }
        return out + rest
    }
}
