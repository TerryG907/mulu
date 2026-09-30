// Steps 1-4 of `mulu auto` (OCR, parse, page offset, front matter, final parse, checks),
// ported from runAuto in Sources/mulu/AutoCommand.swift @ 04161b2 — keep in sync; v0.2 moves
// both callers into a shared target. Deviations (GUI_SPEC §3.3): every refusal becomes an
// Advisory and the draft is still produced; cancellation checks between the heavy steps; and
// RecognitionRequest.detectOffset == false reads no body pages at all.
// RecognitionResult.muluText must equal the stdout of `mulu auto --dry-run` byte for byte when
// auto accepts, and autoWouldAccept must equal "auto exits 0" (checked by the parity script).

import Foundation
import MuluCore
import MuluOCR

/// Synchronous, heavy: call off the main actor. Throws CancellationError when the current task is cancelled.
public struct RecognitionPipeline: Sendable {
    public let url: URL
    public let pageCount: Int

    public init(url: URL, pageCount: Int) {
        self.url = url
        self.pageCount = pageCount
    }

    /// Progress ranges of the phases (GUI_SPEC §5.3).
    enum Span {
        static let reading = 0.00...0.60
        static let parsing = 0.60...0.62
        static let offset = 0.62...0.90
        static let headings = 0.90...0.95
        static let front = 0.95...0.97
        static let locating = 0.97...0.99
    }

    /// Reports progress with a fraction that never goes down.
    final class Tracker {
        let sink: @Sendable (RecognitionProgress) -> Void
        var last = 0.0
        init(_ sink: @escaping @Sendable (RecognitionProgress) -> Void) { self.sink = sink }
        func report(_ phase: RecognitionProgress.Phase, _ step: Int, _ total: Int, in span: ClosedRange<Double>) {
            let part = total > 0 ? min(1, max(0, Double(step) / Double(total))) : 0
            let f = max(last, span.lowerBound + part * (span.upperBound - span.lowerBound))
            last = f
            sink(RecognitionProgress(phase: phase, step: step, total: total, fraction: f))
        }
        func finish() {
            last = 1
            sink(RecognitionProgress(phase: .finishing, step: 1, total: 1, fraction: 1))
        }
    }

    /// The TOC pages of a request, deduplicated in the given order; throws RecognitionError.
    static func validatedPages(_ pages: [Int], pageCount: Int) throws -> [Int] {
        var out: [Int] = []
        for p in pages where !out.contains(p) { out.append(p) }
        guard !out.isEmpty else { throw RecognitionError.noPages }
        guard out.count <= maxTOCPageCount else { throw RecognitionError.tooManyPages(out.count) }
        if let bad = out.first(where: { $0 < 1 || $0 > pageCount }) {
            throw RecognitionError.invalidPages(OCRError.pageOutOfRange(page: bad, pageCount: pageCount).description)
        }
        return out
    }

    public func run(_ request: RecognitionRequest,
                    progress: @escaping @Sendable (RecognitionProgress) -> Void) throws -> RecognitionResult {
        let clock = ContinuousClock()
        let t0 = clock.now
        func elapsed() -> Double {
            let d = clock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let tracker = Tracker(progress)
        var advisories: [Advisory] = []
        func advise(_ kind: Advisory.Kind, blocks: Bool, _ detail: String, severity: Advisory.Severity = .warning) {
            advisories.append(Advisory(kind: kind, severity: severity, blocksAuto: blocks, detail: detail))
        }
        let bodyOCR = request.detectOffset
        let givenOffset = request.knownOffset
        if let g = givenOffset, abs(g) > TOCParser.maxPage {
            throw RecognitionError.invalidPages("offset \(g) is out of range")
        }

        // 1. OCR of the TOC pages (or the pasted text).
        let source: RecognitionResult.Source
        let tocPages: [Int]
        let rawText: String
        var ocrLines = 0
        var unstable = Set<Int>()
        var enlarged = Set<Int>()
        var knownRoman: [(page: Int, value: Int)] = []
        switch request.input {
        case .tocPages(let requested):
            source = .ocr
            tocPages = try RecognitionPipeline.validatedPages(requested, pageCount: pageCount)
            try Task.checkCancellation()
            tracker.report(.readingTOC, 0, tocPages.count, in: Span.reading)
            let read = try TOCPageReader(url: url).read(pages: tocPages) { done, total in
                try Task.checkCancellation()
                tracker.report(.readingTOC, done, total, in: Span.reading)
            }
            for w in read.warnings { advise(.ocrWarning, blocks: false, "ocr: \(w)", severity: .info) }
            rawText = read.lines.map(\.text).joined(separator: "\n") + "\n"
            ocrLines = read.lines.count
            guard !read.lines.isEmpty else {
                let spec = tocPages.map(String.init).joined(separator: ",")
                advise(.noText, blocks: true, "no text recognized on pages \(spec); are these the TOC pages?")
                return emptyResult(source, tocPages, givenOffset, advisories, elapsed(), tracker)
            }
            // OCR lines (1-based, as in rawText) whose title no other resolution read the same way.
            unstable = Set(read.lines.indices.filter { read.lines[$0].notes.contains(TOCPageReader.unstableNote) }.map { $0 + 1 })
            enlarged = Set(read.lines.indices.filter { read.lines[$0].notes.contains(TOCPageReader.enlargedTitleNote) }.map { $0 + 1 })
            knownRoman = read.folios.filter { $0.number.kind == .roman }.map { (page: $0.page, value: $0.number.value) }
        case .text(let text):
            source = .pastedText
            tocPages = []
            rawText = text
            ocrLines = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.count
            guard text.contains(where: { !$0.isWhitespace }) else {
                advise(.noText, blocks: true, "the pasted text is empty")
                return emptyResult(source, tocPages, givenOffset, advisories, elapsed(), tracker)
            }
        }
        let tocSpec = tocPages.map(String.init).joined(separator: ",")

        // 2. Parse (offset 0 first: printed pages only).
        tracker.report(.parsing, 0, 1, in: Span.parsing)
        var options = PrintedTOCOptions()
        options.pageCount = pageCount
        let printedOnly = PrintedTOCParser.parse(rawText, options: options)
        let hasRoman = printedOnly.entries.contains { $0.printedPage?.style == .roman }
        let arabic = printedOnly.entries.compactMap { e -> Int? in
            guard let p = e.printedPage, p.style == .arabic else { return nil }
            return p.value
        }
        tracker.report(.parsing, 1, 1, in: Span.parsing)
        if arabic.count < AutoPolicy.minEntries {
            advise(.fewEntries, blocks: true, "only \(arabic.count) TOC entr\(arabic.count == 1 ? "y has" : "ies have") a readable page number"
                + " (need \(AutoPolicy.minEntries)); check --toc-pages")
        }
        let lowShare = Double(printedOnly.lowConfidenceEntries.count) / Double(max(1, printedOnly.entries.count))
        if lowShare > 0.5 {
            advise(.notTOCLike, blocks: true, "\(printedOnly.lowConfidenceEntries.count) of \(printedOnly.entries.count) lines on pages \(tocSpec) do not read like"
                + " TOC entries; check --toc-pages")
        }

        // 3. Page offset.
        try Task.checkCancellation()
        let offset: Int
        var offsetInfo: OffsetInfo
        var leadingRun: (offset: Int, pages: [Int])? = nil
        if let givenOffset {
            offset = givenOffset
            offsetInfo = OffsetInfo(source: .given)
            if bodyOCR {
                tracker.report(.checkingHeadings, 0, 1, in: Span.headings)
                let v = try HeadingCheck(entries: printedOnly.entries, pageCount: pageCount, url: url).verify(offset: givenOffset)
                offsetInfo.evidence = OffsetEvidence(headingsChecked: v.checked, headingsConfirmed: v.confirmed)
                if v.confirmed < 2, let d = v.consistentShift, d != 0 {
                    advise(.offsetHeadingsDisagree, blocks: false,
                           "\(v.shifted) chapter headings sit \(abs(d)) page\(abs(d) == 1 ? "" : "s") \(d > 0 ? "later" : "earlier") than"
                            + " --offset \(signed(givenOffset)) puts them; offset \(signed(givenOffset + d)) would match them")
                }
                tracker.report(.checkingHeadings, 1, 1, in: Span.headings)
            }
        } else if !bodyOCR {
            offset = 0
            offsetInfo = OffsetInfo(source: .none)
            advise(.offsetUncertain, blocks: true, "the page offset was not detected (detection off); placed at +0")
        } else {
            let total = OffsetDetector.samplePages(pageCount: pageCount, count: OffsetDetector.Options().samples).count
            var seen = 0
            tracker.report(.detectingOffset, 0, total, in: Span.offset)
            let r = try OffsetDetector(url: url).detect { _ in
                try Task.checkCancellation()
                seen += 1
                tracker.report(.detectingOffset, min(seen, total), total, in: Span.offset)
            }
            try Task.checkCancellation()
            var evidence = OffsetEvidence(agreeing: r.agreeing, samples: r.samples, confidence: r.confidence, reason: r.reason)
            if !r.unrenderable.isEmpty {
                advise(.ocrWarning, blocks: false,
                       "offset detection skipped \(r.unrenderable.count) sampled page\(r.unrenderable.count == 1 ? "" : "s") that could not be rendered ("
                        + r.unrenderable.prefix(5).map(String.init).joined(separator: ", ") + ")", severity: .info)
            }
            tracker.report(.checkingHeadings, 0, 1, in: Span.headings)
            let check = HeadingCheck(entries: printedOnly.entries, pageCount: pageCount, url: url)
            leadingRun = r.leadingRun
            // Headings confirming a competing offset mean the offset changes inside the book.
            func competitorConfirmed(_ chosen: Int) throws -> Int? {
                var others = r.votes.filter { $0.offset != chosen && $0.count >= 2 }.prefix(2).map(\.offset)
                if let c = r.conflict, c.offset != chosen, !others.contains(c.offset) { others.insert(c.offset, at: 0) }
                for o in others {
                    if try check.verify(offset: o).confirmed > 0 { return o }
                }
                return nil
            }
            // The fallback's conditions, evaluated lazily in auto's order (each heading check reads pages).
            func fallbackVerdict(_ guess: Int) throws -> HeadingCheck.Verdict? {
                guard r.conflict == nil, r.agreeing >= AutoPolicy.minFolioAgreementWithHeadings else { return nil }
                let v = try check.verify(offset: guess)
                guard v.checked >= AutoPolicy.minHeadingsForFallback, v.confirmed == v.checked else { return nil }
                guard try competitorConfirmed(guess) == nil else { return nil }
                return v
            }
            if r.status == .ok, let off = r.offset {
                // Cross-check with the chapter headings: a confident but wrong offset is the worst
                // outcome, so a clear disagreement blocks auto.
                let v = try check.verify(offset: off)
                evidence.headingsChecked = v.checked
                evidence.headingsConfirmed = v.confirmed
                if v.confirmed < 2, let d = v.consistentShift, d != 0 {
                    advise(.offsetHeadingsDisagree, blocks: true,
                           "the page numbers say offset \(signed(off)) but \(v.shifted) chapter headings sit \(abs(d)) page\(abs(d) == 1 ? "" : "s")"
                            + " \(d > 0 ? "later" : "earlier") (offset \(signed(off + d))); check one body page and pass --offset N")
                }
                offset = off
                offsetInfo = OffsetInfo(source: .detected, evidence: evidence)
                if let c = r.conflict, c.offset != off {
                    advise(.offsetMayChange, blocks: false,
                           "some sampled pages give offset \(signed(c.offset)) (\(c.count) page\(c.count == 1 ? "" : "s")); the offset may change inside the book",
                           severity: .info)
                }
            } else if let guess = r.bestGuess, let v = try fallbackVerdict(guess) {
                // The page numbers alone are not conclusive (too few readable folios), but they do
                // not contradict each other, and EVERY checked chapter heading (at least 3) sits
                // on the page the best guess gives: two independent signals.
                offset = guess
                evidence.headingsChecked = v.checked
                evidence.headingsConfirmed = v.confirmed
                offsetInfo = OffsetInfo(source: .pageNumbersAndHeadings, evidence: evidence)
            } else {
                var why = r.reason
                if let c = r.conflict, !why.contains("offset \(c.offset)"), !why.contains("inside the book"), !why.contains("near the end") {
                    why += "; some sampled pages give offset \(signed(c.offset)) (the offset may change inside the book)"
                }
                offset = r.bestGuess ?? 0
                offsetInfo = OffsetInfo(source: r.bestGuess != nil ? .bestGuess : .none, evidence: evidence)
                advise(.offsetUncertain, blocks: true,
                       "cannot determine the page offset confidently (\(why)); check one body page and pass --offset N")
            }
            tracker.report(.checkingHeadings, 1, 1, in: Span.headings)
        }

        // Where the TOC sits, and the whole TOC past the end (auto's checks after the offset).
        var firstBody: Int? = nil
        if let lo = arabic.min(), let hi = arabic.max() {
            let first = lo + offset
            let lastBody = hi + offset
            firstBody = first
            let bodyKinds: Set<HeadingKind> = [.part, .subpart, .chapter, .section, .dotted, .arabic, .cnEnum, .appendix]
            let firstNumbered = printedOnly.entries.first { bodyKinds.contains($0.heading.kind) && $0.printedPage?.style == .arabic && !$0.pageInherited }
                .map { $0.printedPage!.value + offset } ?? first
            // The first sampled pages agree on another offset: fine for front matter numbered on
            // its own, but not when that run reaches the first chapter.
            if givenOffset == nil, let lr = leadingRun, let last = lr.pages.last, last >= firstNumbered {
                advise(.offsetMayChange, blocks: true,
                       "the first sampled pages (\(lr.pages.map(String.init).joined(separator: ", "))) give offset \(signed(lr.offset)), not \(signed(offset)),"
                        + " and they reach the first chapter (page \(firstNumbered)): the offset changes inside the book; pass --offset N after checking")
            }
            if let tocMin = tocPages.min(), let tocMax = tocPages.max() {
                let tocAtBack = lastBody < tocMin
                if !tocAtBack && firstNumbered <= tocMax {
                    advise(.firstChapterBeforeTOC, blocks: true,
                           "offset \(signed(offset)) puts the first chapter on page \(firstNumbered), not after the TOC pages (\(tocSpec)); pass --offset N")
                }
            }
            if lastBody > pageCount {
                let beyond = arabic.filter { $0 + offset > pageCount }.count
                if beyond * 2 > arabic.count {
                    advise(.entriesBeyondLastPage, blocks: true,
                           "offset \(signed(offset)) puts \(beyond) of \(arabic.count) entries past the last page (\(pageCount)); pass --offset N")
                }
            }
        }

        // Roman front matter: physical = roman value + romanOffset.
        var romanOffset: Int? = nil
        if hasRoman {
            if bodyOCR, let firstBody {
                try Task.checkCancellation()
                tracker.report(.frontMatter, 0, 1, in: Span.front)
                let tocSet = Set(tocPages)
                let front = Array(1..<max(1, min(firstBody, pageCount + 1))).filter { !tocSet.contains($0) }
                switch try findRomanOffset(entries: printedOnly.entries, frontPages: front, knownRoman: knownRoman, url: url) {
                case .found(let ro, _):
                    romanOffset = ro
                case .notFound(let why):
                    advise(.romanUnresolved, blocks: false, "roman front-matter entries left out: \(why); pass --roman-offset N to include them")
                }
                tracker.report(.frontMatter, 1, 1, in: Span.front)
            } else {
                advise(.romanUnresolved, blocks: false, bodyOCR
                    ? "roman front-matter entries left out: no body page to anchor the front matter"
                    : "roman front-matter entries left out: the front matter was not searched (detection off)")
            }
        }

        // 4. Final parse with physical pages, then the checks.
        try Task.checkCancellation()
        options.offset = offset
        options.romanOffset = romanOffset
        var result = PrintedTOCParser.parse(rawText, options: options)
        if bodyOCR {
            tracker.report(.locatingHeadings, 0, 1, in: Span.locating)
            _ = try locateByHeadings(&result, pageCount: pageCount, url: url, tocPages: tocPages)
            tracker.report(.locatingHeadings, 1, 1, in: Span.locating)
        }
        try Task.checkCancellation()
        let muluText = result.muluText(header: true, annotate: true)
        let entryLines = Set(result.entries.flatMap(\.lines))
        for w in result.warnings where !entryLines.contains(w.line) {
            advise(.parserWarning, blocks: false, w.description, severity: .info)
        }
        let built = DraftBuilder.rows(from: result, mapping: PageMapping(offset: offset, romanOffset: romanOffset),
                                      unstable: unstable, enlarged: enlarged)
        let entries = result.tocEntries
        let allowed = max(AutoPolicy.doubtfulAllowance, Int(AutoPolicy.maxDoubtfulFraction * Double(result.entries.count)))
        if built.doubtful.count > allowed {
            let lines = built.doubtful.prefix(8).map { "\($0)" }.joined(separator: ", ")
            advise(.tooManyDoubtful, blocks: true,
                   "\(built.doubtful.count) of \(result.entries.count) entries are doubtful (low confidence, title unreadable, out of page order or unmapped;"
                    + " lines \(lines)\(built.doubtful.count > 8 ? ", …" : "")); review the TOC with --toc-out")
        }
        if entries.count < AutoPolicy.minEntries && !advisories.contains(where: { $0.kind == .fewEntries }) {
            advise(.fewEntries, blocks: true, "only \(entries.count) entries could be mapped to a page")
        }
        let accept = !advisories.contains(where: \.blocksAuto) && entries.count >= AutoPolicy.minEntries
        tracker.finish()
        return RecognitionResult(
            source: source, tocPages: tocPages, rows: built.rows, mapping: PageMapping(offset: offset, romanOffset: romanOffset),
            offsetInfo: offsetInfo, advisories: advisories, ocrLines: ocrLines, doubtfulCount: built.doubtful.count,
            autoWouldAccept: accept, muluText: muluText, seconds: elapsed())
    }

    private func emptyResult(_ source: RecognitionResult.Source, _ tocPages: [Int], _ givenOffset: Int?, _ advisories: [Advisory],
                             _ seconds: Double, _ tracker: Tracker) -> RecognitionResult {
        tracker.finish()
        return RecognitionResult(
            source: source, tocPages: tocPages, rows: [], mapping: PageMapping(offset: givenOffset ?? 0),
            offsetInfo: OffsetInfo(source: givenOffset != nil ? .given : .none), advisories: advisories, ocrLines: 0,
            doubtfulCount: 0, autoWouldAccept: false, muluText: "", seconds: seconds)
    }
}
