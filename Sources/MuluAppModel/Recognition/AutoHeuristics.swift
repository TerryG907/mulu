// Port of Sources/mulu/AutoCommand.swift @ 04161b2 — keep in sync; v0.2 moves both callers into a shared target.
//
// Copied verbatim: AutoPolicy, HeadingCheck (Verdict, verify(offset:)), locateByHeadings,
// RomanFinding and findRomanOffset. The only changes (GUI_SPEC §3.3): access is internal instead
// of private; cancellation checks (`try Task.checkCancellation()`) between the OCR-heavy loop
// iterations, so HeadingCheck.verify, locateByHeadings and findRomanOffset throw, and
// findRomanOffset rethrows CancellationError instead of turning it into `.notFound`; and
// findRomanOffset takes the TOC pages' roman folios (`knownRoman`) instead of the whole
// TOCReadResult, whose initializer is not public (the caller passes exactly what `auto` derives
// from `read.folios`). Thresholds, order and string comparisons are unchanged.
// The decision logic of runAuto's steps 2-4 lives in RecognitionPipeline.swift (same header rule).

import Foundation
import MuluCore
import MuluOCR

func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }

/// Refusal thresholds of `mulu auto` (see the header comment).
enum AutoPolicy {
    static let minEntries = 3
    static let maxDoubtfulFraction = 0.15
    /// A book with few entries may still have one doubtful entry.
    static let doubtfulAllowance = 1
    /// Offset fallback when the page numbers alone are not conclusive (fewer than
    /// OffsetDetector's 6 agreeing samples): at least this many sampled pages must agree ...
    static let minFolioAgreementWithHeadings = 3
    /// ... and at least this many chapter headings must be checked, ALL on the page the
    /// offset gives, with no competing offset in the samples or confirmed by a heading.
    static let minHeadingsForFallback = 3
}

/// Entries whose printed page was not read (they took a neighbour's page) or breaks the
/// printed order: their heading is looked for on the body pages between the neighbouring
/// entries that have a trusted page (at most 12 pages); the first page showing it as a line
/// of its own becomes the entry's page. Part headings without a page keep the next entry's
/// page (they usually have no page of their own). Returns what was changed.
///
/// The TOC pages are never candidates (the TOC lists every heading), nor, when the TOC comes
/// before the body, any page before it.
func locateByHeadings(_ result: inout PrintedTOCResult, pageCount: Int, url: URL, tocPages: [Int]) throws -> [String] {
    let orderPrefix = "page order:"
    func trusted(_ e: PrintedTOCEntry) -> Bool {
        e.physicalPage != nil && !e.pageInherited && !e.notes.contains { $0.hasPrefix(orderPrefix) }
    }
    let targets = result.entries.indices.filter { i in
        let e = result.entries[i]
        guard e.printedPage?.style != .roman else { return false }
        if e.notes.contains(where: { $0.hasPrefix(orderPrefix) }) { return true }
        return e.pageInherited && ![.part, .subpart, .container].contains(e.heading.kind)
    }
    guard !targets.isEmpty, let locator = try? HeadingLocator(url: url) else { return [] }
    locator.band = 1.0
    var changes: [String] = []
    let tocSet = Set(tocPages)
    let tocMax = tocPages.max() ?? 0
    for i in targets {
        try Task.checkCancellation()
        var lo = result.entries[..<i].last(where: trusted)?.physicalPage ?? 1
        let hi = result.entries[(i + 1)...].first(where: trusted)?.physicalPage ?? pageCount
        if hi > tocMax { lo = max(lo, tocMax + 1) }
        guard hi >= lo, hi - lo <= 12 else { continue }
        let candidates = (lo...hi).filter { !tocSet.contains($0) }
        guard !candidates.isEmpty,
              let hits = try? locator.pages(showing: result.entries[i].title, among: candidates), let first = hits.first else { continue }
        let old = result.entries[i].physicalPage
        result.entries[i].physicalPage = first
        result.entries[i].notes.removeAll { $0.hasPrefix(orderPrefix) }
        result.entries[i].notes.append("page \(first) found from the heading on the body page (printed page not read or out of order)")
        result.entries[i].confidence = max(result.entries[i].confidence, 0.8)
        if old != first {
            changes.append("line \(result.entries[i].line) '\(MuluTOCFormat.oneLine(result.entries[i].title))' page \(old.map(String.init) ?? "?") → \(first)")
        }
    }
    return changes
}

/// Checks a page offset against the chapter headings: for up to 4 top-level entries with a
/// printed arabic page (spread over the TOC), the first page within ±3 of printed + offset
/// whose top shows the title (a chapter opens there; running heads repeat it only on later
/// pages).
struct HeadingCheck {
    let chapters: [(title: String, printed: Int)]
    let pageCount: Int
    let locator: HeadingLocator?

    init(entries: [PrintedTOCEntry], pageCount: Int, url: URL) {
        let top = entries.filter { e in
            e.level == 0 && !e.pageInherited && e.printedPage?.style == .arabic && e.title.count >= 2
                && ![.matter, .trailer, .container, .tocHeading].contains(e.heading.kind)
        }.map { (title: $0.title, printed: $0.printedPage!.value) }
        var pick: [(title: String, printed: Int)] = []
        if top.count <= 4 { pick = top } else {
            for k in 0..<4 { pick.append(top[(k * (top.count - 1)) / 3]) }
        }
        chapters = pick
        self.pageCount = pageCount
        locator = try? HeadingLocator(url: url)
    }

    struct Verdict {
        var confirmed = 0
        var shifted = 0
        /// The shift at least two shifted headings agree on.
        var consistentShift: Int?
        var checked = 0
        var summary: String {
            if checked == 0 { return "chapter headings: none to check" }
            return "chapter headings: \(confirmed) of \(checked) found on their page" + (shifted > 0 ? ", \(shifted) shifted" : "")
        }
    }

    func verify(offset: Int) throws -> Verdict {
        var v = Verdict()
        guard let locator else { return v }
        var shifts: [Int: Int] = [:]
        for c in chapters {
            try Task.checkCancellation()
            let p = c.printed + offset
            guard p >= 1, p <= pageCount else { continue }
            v.checked += 1
            func shows(_ q: Int) -> Bool {
                guard q >= 1, q <= pageCount, let lines = try? locator.topLines(page: q) else { return false }
                return HeadingLocator.matches(lines: lines, title: c.title)
            }
            if shows(p) && !shows(p - 1) {
                v.confirmed += 1
                continue
            }
            if let first = (p - 3...p + 3).first(where: shows), first != p {
                shifts[first - p, default: 0] += 1
                v.shifted += 1
            }
        }
        if let best = shifts.max(by: { $0.value < $1.value }), best.value >= 2 { v.consistentShift = best.key }
        return v
    }
}

enum RomanFinding {
    case found(Int, String)
    case notFound(String)
}

/// The roman front-matter offset. Evidence, strongest first:
///   1. heading anchors: a front-matter page (not a TOC page) whose top shows the title of a
///      roman entry ("前言" on physical page 5 for "前言 …… i" gives 5 - 1 = 4). All anchors
///      must agree; a title shown on several consecutive pages anchors on the first.
///   2. roman folios read in the header/footer bands (the TOC pages' own, then the other
///      front-matter pages): at least 2 pages must agree (RomanOffsetVoter).
/// Anything else leaves the roman entries unmapped (they are listed, not guessed).
func findRomanOffset(entries: [PrintedTOCEntry], frontPages: [Int], knownRoman: [(page: Int, value: Int)], url: URL) throws -> RomanFinding {
    let roman = entries.compactMap { e -> (title: String, value: Int)? in
        guard let p = e.printedPage, p.style == .roman else { return nil }
        return (e.title, p.value)
    }
    guard !frontPages.isEmpty else { return .notFound("no front-matter pages before the first chapter") }
    do {
        let locator = try HeadingLocator(url: url)
        var anchors: [(title: String, page: Int, offset: Int)] = []
        var ambiguous = 0
        for r in roman {
            try Task.checkCancellation()
            let hits = try locator.pages(showing: r.title, among: frontPages)
            // consecutive hits (a running head repeating the title) collapse to the first
            let starts = hits.enumerated().filter { $0.offset == 0 || hits[$0.offset - 1] != $0.element - 1 }.map(\.element)
            if starts.count == 1 { anchors.append((r.title, starts[0], starts[0] - r.value)) } else if starts.count > 1 { ambiguous += 1 }
        }
        let offs = Set(anchors.map(\.offset))
        if offs.count == 1, let o = offs.first, o >= 0 {
            let names = anchors.map { "'\($0.title)' on page \($0.page)" }.joined(separator: ", ")
            return .found(o, "heading\(anchors.count == 1 ? "" : "s") \(names)")
        }
        if offs.count > 1 {
            return .notFound("front-matter headings disagree (\(anchors.map { "'\($0.title)' on page \($0.page)" }.joined(separator: ", ")))")
        }
        let known = knownRoman
        let rr = try OffsetDetector(url: url).detectRoman(pages: frontPages, known: known)
        if let o = rr.offset { return .found(o, "roman page numbers: \(rr.reason)") }
        return .notFound(ambiguous > 0 ? "front-matter titles appear on several pages; \(rr.reason)" : rr.reason)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return .notFound("\(error)")
    }
}
