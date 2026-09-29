import Foundation
import MuluCore
import MuluOCR

// mulu auto <book.pdf> --toc-pages 5-7 -o out.pdf [--offset N] [--roman-offset N]
//                      [--toc-out toc.txt] [--dry-run] [--json] [--quiet]
//
// The whole pipeline in one command:
//   1. OCR the printed TOC pages (same engine as `mulu ocr-toc`).
//   2. Parse the printed lines (same parser as `mulu toc parse`): levels, printed pages.
//   3. Page offset: --offset N, or detected from the page numbers printed on sampled body
//      pages (same as `mulu detect-offset`). Roman front-matter pages: --roman-offset N,
//      or voted from the roman folios of the TOC pages and the other front-matter pages;
//      when that is not conclusive the roman entries are left out (with a warning).
//   4. Checks, then `mulu apply` (incremental update: every original byte kept).
//
// It REFUSES (exit 2, no output file, reason on stderr) instead of guessing when
//   - the offset cannot be detected confidently (pass --offset N after checking a page).
//     Confident = what `mulu detect-offset` accepts (>= 6 agreeing samples, >= 40%, no
//     competing offset). The one fallback: >= 3 agreeing samples, NO competing offset in
//     the samples (OffsetReport.conflict), >= 3 chapter headings checked and ALL of them on
//     the page the offset gives, and no heading confirming a competing offset,
//   - the offset puts the first chapter on or before the TOC pages, or past the last page
//     (a TOC printed after the body, with every entry before it, is fine),
//   - fewer than 3 entries could be read,
//   - more than 15% of the entries are doubtful: low OCR/parse confidence, a title that the
//     200/300/400 dpi readings disagree on (or that was read only from an enlarged crop),
//     printed page out of order, or no physical page
//     (roman front matter excepted). This holds with --offset too: it is about the scan.
// With --toc-out the TOC draft is written even on a refusal (printed pages when the offset
// is unknown), so it can be corrected by hand and applied with `mulu apply`.
// A report of each step goes to stdout (--json: one JSON object instead); warnings go to
// stderr.

let autoUsage = """
      mulu auto <book.pdf> --toc-pages 5-7 -o <out.pdf> [--offset N] [--roman-offset N] [--toc-out toc.txt] [--dry-run] [--json]
    """

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

private struct AutoReport {
    var steps: [String] = []
    var json: [String: String] = [:]  // key -> raw JSON value
    var quietStdout = false
    /// --dry-run prints the TOC on stdout, so the steps go to stderr.
    var toStderr = false

    mutating func step(_ s: String) {
        steps.append(s)
        if quietStdout { return }
        if toStderr { FileHandle.standardError.write(Data("mulu: \(s)\n".utf8)) } else { print(s) }
    }
}

private func autoWarn(_ s: String) {
    let oneLine = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardError.write(Data("mulu: warning: \(oneLine)\n".utf8))
}

private func seconds(since t0: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock().now - t0
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Writes `bytes` next to `path` and renames it into place (never a partial file).
private func writeAtomically(_ bytes: [UInt8], to path: String) {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).mulu-\(getpid())-\(UUID().uuidString).tmp")
    do {
        try Data(bytes).write(to: tmp, options: [.withoutOverwriting])
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(path): \(error.localizedDescription)")
    }
    if rename(tmp.path, url.path) != 0 {
        let err = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(path): \(err)")
    }
}

private func sameFile(_ a: String, _ b: String) -> Bool {
    let ua = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath()
    let ub = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath()
    if ua.path == ub.path { return true }
    if let x = fileIdentity(a), let y = fileIdentity(b), x == y { return true }
    return false
}

private func checkOutputPath(_ out: String, input: String, what: String) {
    if sameFile(out, input) { fail("\(what) path is the input file; refusing to modify the input") }
    let dir = URL(fileURLWithPath: out).standardizedFileURL.deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
        fail("\(dir.path): output directory does not exist")
    }
    // Checked before the (slow) OCR: an -o that is a directory, or a directory we cannot write.
    var outIsDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: out, isDirectory: &outIsDir), outIsDir.boolValue {
        fail("cannot write \(out): it is a directory (\(what) must name a file)")
    }
    if access(dir.path, W_OK) != 0 {
        fail("cannot write \(out): no permission to create files in \(dir.path)")
    }
}

private func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }

func runAuto(_ args: [String]) -> Never {
    var positional: [String] = []
    var opts: [String: String] = [:]
    let valued: Set<String> = ["--toc-pages", "-o", "--output", "--offset", "--roman-offset", "--toc-out"]
    let flags: Set<String> = ["--dry-run", "--json", "--quiet"]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" { positional += args[(i + 1)...]; break }
        if a.hasPrefix("--"), let eq = a.firstIndex(of: "="), valued.contains(String(a[..<eq])) {
            opts[String(a[..<eq])] = String(a[a.index(after: eq)...])
        } else if valued.contains(a) {
            i += 1
            guard i < args.count else { fail("\(a) needs a value") }
            opts[a] = args[i]
        } else if flags.contains(a) {
            opts[a] = ""
        } else if a.hasPrefix("-") && a != "-" {
            fail("unknown option \(a)\nusage:\n\(autoUsage)")
        } else {
            positional.append(a)
        }
        i += 1
    }
    guard positional.count == 1 else { fail("usage:\n\(autoUsage)") }
    let pdfPath = positional[0]
    guard let tocSpec = opts["--toc-pages"] else {
        fail("auto needs --toc-pages (the physical pages of the printed table of contents, e.g. 5-7)")
    }
    let dryRun = opts["--dry-run"] != nil
    let outPath = opts["-o"] ?? opts["--output"]
    guard dryRun || (outPath.map { !$0.isEmpty } ?? false) else { fail("auto needs -o <out.pdf> (or --dry-run)") }
    func intOpt(_ name: String) -> Int? {
        guard let s = opts[name] else { return nil }
        guard let v = Int(s), abs(v) <= TOCParser.maxPage else { fail("\(name) must be an integer, got '\(s)'") }
        return v
    }
    let givenOffset = intOpt("--offset")
    let givenRoman = intOpt("--roman-offset")
    let tocOut = opts["--toc-out"]
    let jsonOut = opts["--json"] != nil
    var report = AutoReport()
    report.quietStdout = jsonOut || opts["--quiet"] != nil
    report.toStderr = dryRun

    // Fail fast on everything that does not need OCR.
    if let outPath, !dryRun { checkOutputPath(outPath, input: pdfPath, what: "output") }
    if let tocOut {
        checkOutputPath(tocOut, input: pdfPath, what: "--toc-out")
        if let outPath, !dryRun, sameFile(tocOut, outPath) { fail("--toc-out and -o name the same file") }
    }
    let input = readFile(pdfPath)
    let pageCount: Int
    do {
        let doc = try PDFFile(bytes: input)
        if doc.isEncrypted { fail("\(pdfPath): the PDF is encrypted; refusing to modify it") }
        pageCount = try doc.pageRefs().count
    } catch {
        fail("\(pdfPath): \(error)")
    }
    let url = URL(fileURLWithPath: pdfPath)
    let tocPages: [Int]
    do { tocPages = try parsePageList(tocSpec, pageCount: pageCount) } catch { fail("--toc-pages: \(error)") }
    guard tocPages.count <= maxTOCPageCount else {
        fail("--toc-pages \(tocSpec) names \(tocPages.count) pages; a printed TOC is rarely longer than \(maxTOCPageCount) pages"
            + " (each takes about 2.5 s of OCR). Check the range, or run `mulu ocr-toc` in parts and `mulu toc parse`")
    }
    report.step("mulu auto: \(pdfPath) (\(pageCount) pages)")

    /// Writes the TOC draft (if asked) and refuses.
    func refuse(_ reason: String, draft: String?) -> Never {
        if let tocOut, let draft {
            writeAtomically(Array(draft.utf8), to: tocOut)
            FileHandle.standardError.write(Data("mulu: TOC draft written to \(tocOut) for review\n".utf8))
        }
        if jsonOut {
            report.json["status"] = "\"refused\""
            report.json["reason"] = JSONText.quote(reason)
            printAutoJSON(report)
        }
        fail("refusing to write an outline: \(reason)")
    }

    // 1. OCR of the TOC pages.
    var t0 = ContinuousClock().now
    let read: TOCReadResult
    do {
        read = try TOCPageReader(url: url).read(pages: tocPages)
    } catch {
        fail("\(pdfPath): OCR of pages \(tocSpec) failed: \(error)")
    }
    for w in read.warnings { autoWarn("ocr: \(w)") }
    let rawText = read.lines.map(\.text).joined(separator: "\n") + "\n"
    report.step(String(format: "1. OCR of TOC page%@ %@: %d lines (%.1f s)", tocPages.count == 1 ? "" : "s", tocSpec,
                       read.lines.count, seconds(since: t0)))
    report.json["ocr_lines"] = String(read.lines.count)
    guard !read.lines.isEmpty else { refuse("no text recognized on pages \(tocSpec); are these the TOC pages?", draft: nil) }

    // 2. Parse (offset 0 first: printed pages only).
    var options = PrintedTOCOptions()
    options.pageCount = pageCount
    let printedOnly = PrintedTOCParser.parse(rawText, options: options)
    let hasRoman = printedOnly.entries.contains { $0.printedPage?.style == .roman }
    let arabic = printedOnly.entries.compactMap { e -> Int? in
        guard let p = e.printedPage, p.style == .arabic else { return nil }
        return p.value
    }
    let levels = (printedOnly.entries.map(\.level).max() ?? -1) + 1
    report.step("2. parsed \(printedOnly.entries.count) entries in \(levels) level\(levels == 1 ? "" : "s")"
        + " (\(printedOnly.lowConfidenceEntries.count) low-confidence, \(printedOnly.orderViolations.count) out of page order)")
    report.json["entries"] = String(printedOnly.entries.count)
    report.json["levels"] = String(levels)
    func printedDraft() -> String {
        "# Mulu TOC draft from `mulu auto`: pages are the PRINTED page numbers (the offset is unknown).\n"
            + "# Find the offset (physical page of printed page 1, minus 1), then:\n"
            + "#   mulu apply \(pdfPath) <this file> --offset N -o out.pdf\n"
            + printedOnly.muluText(header: false, annotate: true)
    }
    guard arabic.count >= AutoPolicy.minEntries else {
        refuse("only \(arabic.count) TOC entr\(arabic.count == 1 ? "y has" : "ies have") a readable page number"
            + " (need \(AutoPolicy.minEntries)); check --toc-pages", draft: printedDraft())
    }
    // Most lines doubtful already: not a TOC page (body text), or unreadable. Checked before
    // the (slower) offset detection.
    let lowShare = Double(printedOnly.lowConfidenceEntries.count) / Double(max(1, printedOnly.entries.count))
    if lowShare > 0.5 {
        refuse("\(printedOnly.lowConfidenceEntries.count) of \(printedOnly.entries.count) lines on pages \(tocSpec) do not read like"
            + " TOC entries; check --toc-pages", draft: printedDraft())
    }

    // 3. Page offset.
    let offset: Int
    var leadingRun: (offset: Int, pages: [Int])? = nil
    if let givenOffset {
        offset = givenOffset
        report.step("3. page offset \(signed(offset)) (given with --offset)")
        report.json["offset_source"] = "\"given\""
        let v = HeadingCheck(entries: printedOnly.entries, pageCount: pageCount, url: url).verify(offset: givenOffset)
        report.step("   " + v.summary)
        if v.confirmed < 2, let d = v.consistentShift, d != 0 {
            autoWarn("\(v.shifted) chapter headings sit \(abs(d)) page\(abs(d) == 1 ? "" : "s") \(d > 0 ? "later" : "earlier") than"
                + " --offset \(signed(givenOffset)) puts them; offset \(signed(givenOffset + d)) would match them")
        }
    } else {
        t0 = ContinuousClock().now
        let r: OffsetReport
        do { r = try OffsetDetector(url: url).detect() } catch { fail("\(pdfPath): offset detection failed: \(error)") }
        report.json["offset_confidence"] = String(format: "%.3f", r.confidence)
        report.json["offset_agreeing"] = String(r.agreeing)
        report.json["offset_samples"] = String(r.samples)
        let check = HeadingCheck(entries: printedOnly.entries, pageCount: pageCount, url: url)
        leadingRun = r.leadingRun
        if !r.unrenderable.isEmpty {
            autoWarn("offset detection skipped \(r.unrenderable.count) sampled page\(r.unrenderable.count == 1 ? "" : "s") that could not be rendered ("
                + r.unrenderable.prefix(5).map(String.init).joined(separator: ", ") + ")")
        }
        // Headings confirming a competing offset mean the offset changes inside the book.
        func competitorConfirmed(_ chosen: Int) -> Int? {
            var others = r.votes.filter { $0.offset != chosen && $0.count >= 2 }.prefix(2).map(\.offset)
            if let c = r.conflict, c.offset != chosen, !others.contains(c.offset) { others.insert(c.offset, at: 0) }
            return others.first { check.verify(offset: $0).confirmed > 0 }
        }
        if r.status == .ok, let off = r.offset {
            // Cross-check with the chapter headings: a confident but wrong offset is the worst
            // outcome, so a clear disagreement refuses.
            let v = check.verify(offset: off)
            if v.confirmed < 2, let d = v.consistentShift, d != 0 {
                refuse("the page numbers say offset \(signed(off)) but \(v.shifted) chapter headings sit \(abs(d)) page\(abs(d) == 1 ? "" : "s")"
                    + " \(d > 0 ? "later" : "earlier") (offset \(signed(off + d))); check one body page and pass --offset N", draft: printedDraft())
            }
            offset = off
            report.step(String(format: "3. page offset %@ detected: %d of %d sampled pages agree (confidence %.2f, %.1f s)",
                               signed(off), r.agreeing, r.samples, r.confidence, seconds(since: t0)))
            report.step("   " + v.summary)
            report.json["offset_source"] = "\"detected\""
            report.json["offset_headings_confirmed"] = String(v.confirmed)
        } else if let guess = r.bestGuess, r.conflict == nil, r.agreeing >= AutoPolicy.minFolioAgreementWithHeadings,
                  case let v = check.verify(offset: guess), v.checked >= AutoPolicy.minHeadingsForFallback,
                  v.confirmed == v.checked, competitorConfirmed(guess) == nil {
            // The page numbers alone are not conclusive (too few readable folios), but they do
            // not contradict each other, and EVERY checked chapter heading (at least 3) sits
            // on the page the best guess gives: two independent signals. Never used when the
            // sampled pages support a competing offset (see OffsetReport.conflict).
            offset = guess
            report.step(String(format: "3. page offset %@: page numbers inconclusive (%d of %d sampled pages agree) but %d chapter headings"
                               + " confirm it (%.1f s)", signed(guess), r.agreeing, r.samples, v.confirmed, seconds(since: t0)))
            report.json["offset_source"] = "\"page numbers + headings\""
            report.json["offset_headings_confirmed"] = String(v.confirmed)
        } else {
            var why = r.reason
            if let c = r.conflict, !why.contains("offset \(c.offset)"), !why.contains("inside the book"), !why.contains("near the end") {
                why += "; some sampled pages give offset \(signed(c.offset)) (the offset may change inside the book)"
            }
            refuse("cannot determine the page offset confidently (\(why)); check one body page and pass --offset N",
                   draft: printedDraft())
        }
    }
    report.json["offset"] = String(offset)
    let firstBody = arabic.min()! + offset
    let lastBody = arabic.max()! + offset
    // Where the TOC sits: before the body (usual), or after it (TOC at the back of the book,
    // French / Japanese style: every entry before the TOC pages). Front matter printed before
    // the TOC (前言 on page 3 of a book numbered from the cover) is fine; the first numbered
    // entry (a part / chapter / section) must not land on or before the TOC pages.
    let bodyKinds: Set<HeadingKind> = [.part, .subpart, .chapter, .section, .dotted, .arabic, .cnEnum, .appendix]
    let firstNumbered = printedOnly.entries.first { bodyKinds.contains($0.heading.kind) && $0.printedPage?.style == .arabic && !$0.pageInherited }
        .map { $0.printedPage!.value + offset } ?? firstBody
    let tocAtBack = lastBody < tocPages.min()!
    // The first sampled pages agree on another offset: fine for front matter numbered on its
    // own, but not when that run reaches the first chapter (the offset changes in the body).
    if givenOffset == nil, let lr = leadingRun, let last = lr.pages.last, last >= firstNumbered {
        refuse("the first sampled pages (\(lr.pages.map(String.init).joined(separator: ", "))) give offset \(signed(lr.offset)), not \(signed(offset)),"
            + " and they reach the first chapter (page \(firstNumbered)): the offset changes inside the book; pass --offset N after checking",
               draft: printedDraft())
    }
    if tocAtBack {
        report.step("   the TOC is printed after the body (every entry is before page \(tocPages.min()!))")
    } else if firstNumbered <= tocPages.max()! {
        refuse("offset \(signed(offset)) puts the first chapter on page \(firstNumbered), not after the TOC pages (\(tocSpec)); pass --offset N",
               draft: printedDraft())
    }
    if lastBody > pageCount {
        // One misread page number is caught by the order check below; the whole TOC beyond
        // the end means a wrong offset.
        let beyond = arabic.filter { $0 + offset > pageCount }.count
        if beyond * 2 > arabic.count {
            refuse("offset \(signed(offset)) puts \(beyond) of \(arabic.count) entries past the last page (\(pageCount)); pass --offset N",
                   draft: printedDraft())
        }
    }

    // Roman front matter: physical = roman value + romanOffset.
    var romanOffset = givenRoman
    if hasRoman && romanOffset == nil {
        let tocSet = Set(tocPages)
        let front = Array(1..<max(1, min(firstBody, pageCount + 1))).filter { !tocSet.contains($0) }
        switch findRomanOffset(entries: printedOnly.entries, frontPages: front, read: read, url: url) {
        case .found(let ro, let why):
            romanOffset = ro
            report.step("   front matter: roman page \(signed(ro)) (\(why))")
        case .notFound(let why):
            autoWarn("roman front-matter entries left out: \(why); pass --roman-offset N to include them")
        }
    } else if let givenRoman {
        report.step("   front matter: roman page \(signed(givenRoman)) (given with --roman-offset)")
    }
    if let romanOffset { report.json["roman_offset"] = String(romanOffset) }

    // 4. Final parse with physical pages, then the checks.
    options.offset = offset
    options.romanOffset = romanOffset
    var result = PrintedTOCParser.parse(rawText, options: options)
    let located = locateByHeadings(&result, pageCount: pageCount, url: url, tocPages: tocPages)
    if !located.isEmpty {
        report.step("   pages found from the headings on the body pages: " + located.joined(separator: "; "))
    }
    let muluText = result.muluText(header: true, annotate: true)
    var reported = Set<String>()
    for w in result.warnings {
        autoWarn(w.description)
        reported.insert(w.description)
    }
    let violations = Set(result.orderViolations)
    // OCR lines (1-based, as in rawText) whose title no other resolution read the same way.
    let unstable = Set(read.lines.indices.filter { read.lines[$0].notes.contains(TOCPageReader.unstableNote) }.map { $0 + 1 })
    let enlarged = Set(read.lines.indices.filter { read.lines[$0].notes.contains(TOCPageReader.enlargedTitleNote) }.map { $0 + 1 })
    var doubtful: [PrintedTOCEntry] = []
    for e in result.entries {
        let romanLeftOut = e.physicalPage == nil && e.printedPage?.style == .roman && romanOffset == nil
        if e.lines.contains(where: unstable.contains) {
            autoWarn("line \(e.line): title '\(MuluTOCFormat.oneLine(e.title))' read differently at 200, 300 and 400 dpi")
            if !romanLeftOut { doubtful.append(e) }
            continue
        }
        if e.lines.contains(where: enlarged.contains) {
            autoWarn("line \(e.line): title '\(MuluTOCFormat.oneLine(e.title))' was read only from an enlarged crop of the title; check it")
            if !romanLeftOut { doubtful.append(e) }
            continue
        }
        let low = e.confidence < options.lowConfidence
        if low {
            let notes = e.notes.filter { !reported.contains("line \(e.line): \($0)") }
            autoWarn("line \(e.line): low confidence \(String(format: "%.2f", e.confidence)) for '\(MuluTOCFormat.oneLine(e.title))'"
                + (notes.isEmpty ? "" : ": " + notes.joined(separator: "; ")))
        }
        if !romanLeftOut && (low || violations.contains(e.line) || e.physicalPage == nil) { doubtful.append(e) }
    }
    let entries = result.tocEntries
    let allowed = max(AutoPolicy.doubtfulAllowance, Int(AutoPolicy.maxDoubtfulFraction * Double(result.entries.count)))
    report.json["doubtful"] = String(doubtful.count)
    report.json["bookmarks"] = String(entries.count)
    report.step("4. checks: \(entries.count) bookmarks, \(doubtful.count) doubtful (limit \(allowed))"
        + (result.entries.count > entries.count ? ", \(result.entries.count - entries.count) left out" : ""))
    if doubtful.count > allowed {
        let lines = doubtful.prefix(8).map { "\($0.line)" }.joined(separator: ", ")
        refuse("\(doubtful.count) of \(result.entries.count) entries are doubtful (low confidence, title unreadable, out of page order or unmapped;"
            + " lines \(lines)\(doubtful.count > 8 ? ", …" : "")); review the TOC with --toc-out", draft: muluText)
    }
    guard entries.count >= AutoPolicy.minEntries else {
        refuse("only \(entries.count) entries could be mapped to a page", draft: muluText)
    }
    if let tocOut { writeAtomically(Array(muluText.utf8), to: tocOut) }

    if dryRun {
        if !jsonOut { print(muluText, terminator: "") }
        report.json["status"] = "\"dry-run\""
        if jsonOut { printAutoJSON(report) }
        exit(0)
    }

    // 5. Apply (incremental update).
    let applied: ApplyResult
    do {
        applied = try Mulu.apply(pdf: input, tocText: muluText, offset: 0)
    } catch {
        fail("\(error)")
    }
    guard applied.output.count > input.count, Array(applied.output.prefix(input.count)) == input else {
        fail("internal error: the output does not start with the original bytes; nothing written")
    }
    writeAtomically(applied.output, to: outPath!)
    report.step("5. wrote \(outPath!): \(applied.itemCount) bookmarks, \(applied.appendedByteCount) bytes appended;"
        + " the original \(input.count) bytes are unchanged")
    report.json["status"] = "\"ok\""
    report.json["output"] = JSONText.quote(outPath!)
    report.json["input_size"] = String(input.count)
    report.json["output_size"] = String(applied.output.count)
    report.json["items"] = String(applied.itemCount)
    if jsonOut { printAutoJSON(report) }
    exit(0)
}

/// Entries whose printed page was not read (they took a neighbour's page) or breaks the
/// printed order: their heading is looked for on the body pages between the neighbouring
/// entries that have a trusted page (at most 12 pages); the first page showing it as a line
/// of its own becomes the entry's page. Part headings without a page keep the next entry's
/// page (they usually have no page of their own). Returns what was changed.
///
/// The TOC pages are never candidates (the TOC lists every heading), nor, when the TOC comes
/// before the body, any page before it.
private func locateByHeadings(_ result: inout PrintedTOCResult, pageCount: Int, url: URL, tocPages: [Int]) -> [String] {
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
private struct HeadingCheck {
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

    func verify(offset: Int) -> Verdict {
        var v = Verdict()
        guard let locator else { return v }
        var shifts: [Int: Int] = [:]
        for c in chapters {
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

private enum RomanFinding {
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
private func findRomanOffset(entries: [PrintedTOCEntry], frontPages: [Int], read: TOCReadResult, url: URL) -> RomanFinding {
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
        let known = read.folios.filter { $0.number.kind == .roman }.map { (page: $0.page, value: $0.number.value) }
        let rr = try OffsetDetector(url: url).detectRoman(pages: frontPages, known: known)
        if let o = rr.offset { return .found(o, "roman page numbers: \(rr.reason)") }
        return .notFound(ambiguous > 0 ? "front-matter titles appear on several pages; \(rr.reason)" : rr.reason)
    } catch {
        return .notFound("\(error)")
    }
}

private func printAutoJSON(_ r: AutoReport) {
    let order = ["status", "reason", "output", "input_size", "output_size", "items", "ocr_lines", "entries", "levels", "offset",
                 "offset_source", "offset_confidence", "offset_agreeing", "offset_samples", "roman_offset", "bookmarks", "doubtful"]
    var parts: [String] = []
    for k in order { if let v = r.json[k] { parts.append("\(JSONText.quote(k)):\(v)") } }
    parts.append("\"steps\":[" + r.steps.map(JSONText.quote).joined(separator: ",") + "]")
    print("{" + parts.joined(separator: ",") + "}")
}
