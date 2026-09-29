import Foundation

// Printed-TOC parser: turns the lines of a printed table of contents (typed, pasted from
// an online bookstore, or OCR'd from scanned TOC pages) into a Mulu TOC.
//
// PIPELINE
//   1. Page token. Each line is split into title + trailing page number (PageTokenizer):
//      arabic / full-width digits, Roman numerals, ranges ("12-15" → 12), brackets
//      ("(12)" "【12】"), "p. 12", "第12页", appendix pagination ("A1", never mapped),
//      dot leaders (…… ····· ..... —— ____) stripped. OCR repairs, all flagged: O/0
//      l/1 I/1 |/1 inside a number, "2S"/"B0" after leaders, "4.0" → 40 in Chinese
//      titles, a page read twice ("6 O<TAB>60"), stray punctuation or letters around
//      the page, random Latin letters glued to CJK text (misread leaders).
//   2. Line assembly.
//      - A line that is only a page number ("12", "- 3 -", "iii") attaches to the
//        pageless entry right above it; otherwise it is dropped with a warning (it is
//        usually the TOC page's own running page number).
//      - A pageless line followed by an unnumbered line is merged with it when the
//        first line looks cut off: it ends with a connective (与 和 及 的 、 , and of
//        the ...), a hyphen or an unclosed bracket; the next line starts lower-case; or
//        it is as wide as the lines that carry dot leaders.
//      - Two-column lines ("第一章 …… 1    第五章 …… 88") are split when the first
//        half ends with a leader-separated page and the second half is numbered; the
//        left column is read first.
//      - The TOC page's own heading (目录 / Contents without a page) and pageless lines
//        repeated verbatim (running headers) are dropped with a warning.
//      - Any other pageless entry takes the page of the next entry (flagged).
//   3. Levels. Each title's numbering is classified (HeadingClassifier) and given a
//      rank; an entry's level is the number of open ancestors with a smaller rank
//      (a rank stack), so absent levels collapse and siblings realign:
//          rank 0    part      第一篇 第一部分 第一编 上篇 Part I Book One Unit 2;
//                              appendix 附录A Appendix A
//          rank 0.5  subpart   第一分编 第一分册
//          rank 1    chapter   第一章 第1章 第一回 第一讲 Chapter 1 Lecture 3; also
//                              "1 Title" when "1.1" entries follow it (it heads them)
//          rank 2    section   第一节 考点一 Section 4 §4
//          rank 4+   dotted    1.1 → 4, 1.1.1 → 5, 1.1.1.1 → 6 (A.1 counts as dotted)
//          rank 8  一、   rank 9  （一）   rank 10  1. / 1、   rank 11  (1) ①
//      Front/back matter (前言 序 目录 参考文献 索引 后记 Preface Index ...) is level 0;
//      when it sits between the first and last chapter (e.g. 参考文献 after every
//      chapter) it is treated like a chapter trailer. Trailers (本章小结 习题 思考题
//      Summary Exercises ...) become children of the enclosing chapter, or of the
//      section for 本节… / 习题1-1. A bare 附录/Appendices groups the appendix
//      entries after it.
//      Unnumbered entries (including numbering OCR garbled beyond recognition): when
//      lines sit in indentation columns (leading spaces, or the x-position passed by
//      OCR) and deeper columns hold finer numbering, an unnumbered entry takes the rank
//      of the numbering in its column and joins the rank stack. With no numbering to
//      calibrate, each column is one level. Without indentation, an unnumbered entry
//      right after a part/chapter/section heading is its child and later ones are its
//      siblings. Finally a level may exceed the previous one by at most 1 (clamped,
//      flagged).
//   4. Checks. Printed arabic pages must be non-decreasing: the longest non-decreasing
//      subsequence is kept and every entry outside it is flagged with its line
//      number. Roman pages are checked separately.
//   5. Pages. physical = printed + offset. Roman (front-matter) pages are mapped only
//      with a front-matter offset (physical = value + romanOffset); otherwise they are
//      flagged and left out of the Mulu TOC (written as comments). Front matter before
//      chapter 1 printed "1"/"11"/"111" while chapter 1 starts on page ≤ 3 is read as
//      the misrecognised "i"/"ii"/"iii".
//   Every entry carries a confidence in 0...1 and the notes that lowered it; nothing is
//   dropped silently.

public struct PrintedTOCLine: Sendable, Equatable {
    public var text: String
    /// Horizontal position of the line's first character in any consistent unit (e.g.
    /// points from the left edge of the text block). nil: measured from leading
    /// whitespace (space = 1, TAB = 4, U+3000 = 2).
    public var indent: Double?
    public var lineNumber: Int

    public init(text: String, indent: Double? = nil, lineNumber: Int) {
        self.text = text
        self.indent = indent
        self.lineNumber = lineNumber
    }
}

public struct PrintedTOCOptions: Sendable, Equatable {
    /// physical page = printed arabic page + offset
    public var offset: Int = 0
    /// physical page = Roman page value + romanOffset; nil leaves front matter unmapped.
    public var romanOffset: Int? = nil
    /// Number of pages in the PDF, when known: pages beyond it are flagged.
    public var pageCount: Int? = nil
    /// Indents closer than this are the same column (same unit as PrintedTOCLine.indent).
    public var indentTolerance: Double = 1.5
    /// Entries below this confidence are reported as warnings.
    public var lowConfidence: Double = 0.75

    public init(offset: Int = 0, romanOffset: Int? = nil, pageCount: Int? = nil, indentTolerance: Double = 1.5, lowConfidence: Double = 0.75) {
        self.offset = offset
        self.romanOffset = romanOffset
        self.pageCount = pageCount
        self.indentTolerance = indentTolerance
        self.lowConfidence = lowConfidence
    }
}

public struct PrintedTOCEntry: Sendable, Equatable {
    public var title: String
    public var level: Int
    public var heading: Heading
    public var printedPage: PrintedPage?
    /// 1-based physical page; nil when it cannot be mapped (flagged in notes).
    public var physicalPage: Int?
    /// Source line numbers (more than one when a wrapped title was merged).
    public var lines: [Int]
    public var confidence: Double
    public var notes: [String]
    /// The page was taken from a neighbouring entry.
    public var pageInherited: Bool

    public var line: Int { lines.first ?? 0 }
}

public struct PrintedTOCWarning: Sendable, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public struct PrintedTOCResult: Sendable {
    public var entries: [PrintedTOCEntry]
    /// Dropped lines, order violations, unmapped or out-of-range pages.
    public var warnings: [PrintedTOCWarning]
    public var options: PrintedTOCOptions

    /// Entries below `options.lowConfidence`.
    public var lowConfidenceEntries: [PrintedTOCEntry] {
        entries.filter { $0.confidence < options.lowConfidence }
    }

    /// Line numbers of entries whose printed page breaks the non-decreasing order.
    public var orderViolations: [Int] {
        entries.filter { $0.notes.contains(where: { $0.hasPrefix(PrintedTOCParser.orderNotePrefix) }) }.map(\.line)
    }

    /// Mean confidence (1 for an empty result).
    public var meanConfidence: Double {
        entries.isEmpty ? 1 : entries.map(\.confidence).reduce(0, +) / Double(entries.count)
    }

    /// The entries that have a physical page, as Mulu TOC entries (levels re-clamped so
    /// the list is valid even when unmapped entries are left out).
    public var tocEntries: [TOCEntry] {
        var out: [TOCEntry] = []
        var prev = -1
        for e in entries {
            guard let p = e.physicalPage else { continue }
            let level = min(e.level, prev + 1)
            out.append(TOCEntry(title: e.title, level: level, page: p, line: e.line))
            prev = level
        }
        return out
    }

    /// Mulu TOC text. With `annotate`, low-confidence and unmapped entries get a
    /// `# ?` comment line above them so they are easy to review.
    public func muluText(header: Bool = true, annotate: Bool = true) -> String {
        var out = ""
        if header {
            let sign = options.offset >= 0 ? "+" : "-"
            out += "# Mulu TOC from a printed TOC: physical page = printed page \(sign) \(abs(options.offset))"
            if let r = options.romanOffset { out += "; front matter: roman page + \(r)" }
            out += "\n"
        }
        var prev = -1
        for e in entries {
            let tag = "line \(e.lines.map(String.init).joined(separator: "+"))"
            guard let p = e.physicalPage else {
                if annotate {
                    let why = e.notes.last ?? "no page"
                    out += "# ? \(tag): \(MuluTOCFormat.oneLine(e.title)) [\(e.printedPage?.display ?? "no page")] left out: \(MuluTOCFormat.oneLine(why))\n"
                }
                continue
            }
            if annotate && e.confidence < options.lowConfidence {
                let why = e.notes.isEmpty ? "" : ": " + e.notes.map(MuluTOCFormat.oneLine).joined(separator: "; ")
                out += "# ? \(tag) (confidence \(String(format: "%.2f", e.confidence)))\(why)\n"
            }
            let level = min(e.level, prev + 1)
            out += MuluTOCFormat.line(title: e.title, level: level, page: p) + "\n"
            prev = level
        }
        return out
    }

    /// Machine-readable dump: [{title, level, kind, printed, page, confidence, lines, notes}].
    public var json: String {
        if entries.isEmpty { return "[]" }
        let rows = entries.map { e -> String in
            let printed = e.printedPage.map { JSONText.quote($0.display) } ?? "null"
            let page = e.physicalPage.map(String.init) ?? "null"
            let notes = "[" + e.notes.map(JSONText.quote).joined(separator: ", ") + "]"
            return "  {\"title\": \(JSONText.quote(e.title)), \"level\": \(e.level), \"kind\": \"\(e.heading.kind.rawValue)\", "
                + "\"printed\": \(printed), \"page\": \(page), \"confidence\": \(String(format: "%.2f", e.confidence)), "
                + "\"lines\": [\(e.lines.map(String.init).joined(separator: ", "))], \"notes\": \(notes)}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}

public enum PrintedTOCParser {
    static let orderNotePrefix = "page order:"

    /// Parses printed-TOC text (one entry per line; indentation from leading whitespace).
    public static func parse(_ text: String, options: PrintedTOCOptions = PrintedTOCOptions()) -> PrintedTOCResult {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        let raw = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        let lines = raw.enumerated().map { PrintedTOCLine(text: String($0.element), lineNumber: $0.offset + 1) }
        return parse(lines: lines, options: options)
    }

    // MARK: - internals

    struct Item {
        var title: String
        var page: PrintedPage?
        var indent: Double
        var lines: [Int]
        var width: Int
        var conf = 1.0
        var notes: [String] = []
        var heading = Heading(kind: .none)
        var inherited = false
        var level = 0
        var pageOnly = false
        /// The page follows dot leaders or sits in a page column (TAB / wide gap).
        var strong = false

        mutating func penalize(_ factor: Double, _ note: String) {
            conf *= factor
            if !note.isEmpty { notes.append(note) }
        }
    }

    static func measureIndent(_ s: String) -> (Double, String) {
        var indent = 0.0
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "\t" { indent += 4 } else if c == "\u{3000}" { indent += 2 } else if c.isWhitespace { indent += 1 } else { break }
            idx = s.index(after: idx)
        }
        return (indent, String(s[idx...]))
    }

    /// "12", "- 3 -", "· 12 ·", "iii", "(4)" → the page; nil for anything else.
    static func pageOnlyLine(_ s: String) -> PrintedPage? {
        let deco: Set<Character> = ["-", "—", "–", "·", "•", ".", "*", "(", ")", "（", "）", "[", "]", "【", "】", "~", "～", "_", "|", "/"]
        let core = s.trimmingCharacters(in: .whitespaces).drop(while: { deco.contains($0) || $0.isWhitespace })
        var t = String(core)
        while let l = t.last, deco.contains(l) || l.isWhitespace { t.removeLast() }
        guard !t.isEmpty, t.count <= 6 else { return nil }
        if t.allSatisfy(TOCChars.isDigit), let v = Int(TOCChars.halfWidth(t)), v > 0 {
            return PrintedPage(style: .arabic, value: v, raw: t, separation: .alone)
        }
        if let r = TOCChars.romanValue(t), r <= 200 {
            return PrintedPage(style: .roman, value: r, raw: t, separation: .alone)
        }
        return nil
    }

    static let numberedKinds: Set<HeadingKind> = [.part, .subpart, .chapter, .section, .appendix, .dotted, .arabic, .cnEnum, .cnParen, .arabicParen]

    /// Splits "第一章 绪论 …… 1    第五章 结论 …… 88" into two lines.
    static func splitColumns(_ text: String) -> [String] {
        guard text.count <= 400 else { return [text] }
        let cs = Array(text)
        var i = 0
        while i < cs.count {
            // find a whitespace run
            guard cs[i].isWhitespace else { i += 1; continue }
            var j = i
            while j < cs.count && cs[j].isWhitespace { j += 1 }
            let gap = j - i
            if i > 0 && j < cs.count {
                let left = String(cs[0..<i]), right = String(cs[j...])
                let l = PageTokenizer.split(left)
                // The left half must be a whole entry: a title with at least two letters,
                // then a page after a run of leaders (or a wide gap).
                var b = i
                while b > 0 && cs[b - 1].isWhitespace { b -= 1 }
                while b > 0 && (TOCChars.isDigit(cs[b - 1]) || cs[b - 1].isWhitespace) { b -= 1 }
                var leaders = 0
                while b > 0 && (TOCChars.isLeader(cs[b - 1]) || cs[b - 1].isWhitespace) {
                    if TOCChars.isLeader(cs[b - 1]) { leaders += 1 }
                    b -= 1
                }
                let letters = l.title.filter { $0.isLetter || TOCChars.isCJK($0) }.count
                if let lp = l.page, lp.style == .arabic, letters >= 2,
                   (lp.separation == .leader && leaders >= 2) || (gap >= 3 && lp.separation == .space) {
                    let r = PageTokenizer.split(right)
                    let rk = HeadingClassifier.classify(r.title).kind
                    if r.page != nil, !r.title.isEmpty, numberedKinds.contains(rk) || rk == .matter {
                        return [left] + splitColumns(right)
                    }
                }
            }
            i = j
        }
        return [text]
    }

    static let connectiveEnds: Set<Character> = ["与", "和", "及", "的", "、", "，", ",", ":", "：", ";", "；", "(", "（", "—", "-", "–", "/", "&", "《", "“", "对", "在", "之", "以", "暨", "兼", "或", "其"]
    static let connectiveWords: Set<String> = ["and", "or", "of", "the", "a", "an", "to", "in", "for", "with", "on", "at", "by", "from", "as", "its", "their", "into", "versus", "vs", "vs.", "&", "about", "between", "under", "over", "through", "toward", "towards", "via"]

    static func looksCutOff(_ title: String) -> Bool {
        guard let last = title.last else { return false }
        if connectiveEnds.contains(last) { return true }
        if let w = title.split(separator: " ").last, connectiveWords.contains(w.lowercased()) { return true }
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）"), ("《", "》"), ("“", "”"), ("[", "]")]
        for (o, c) in pairs where title.filter({ $0 == o }).count > title.filter({ $0 == c }).count { return true }
        // A dangling ordinal: "交通与住房的第2" (次革命 on the next line).
        let cs = Array(title)
        var k = cs.count
        while k > 0 && (TOCChars.isDigit(cs[k - 1]) || TOCChars.isCNNumeral(cs[k - 1])) { k -= 1 }
        if k < cs.count && k > 1 && cs[k - 1] == "第" { return true }
        return false
    }

    /// First line of a footnote printed at the foot of a TOC page: "*带星号的章节为选读内容",
    /// "†本章部分内容曾发表于…", "注：…", "¹ …". An optional-section marker in front of a
    /// numbering ("*1.5 …", "※第五节 …") is not one.
    static func isFootnoteStart(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return false }
        for p in ["注：", "注:", "注 ", "注释：", "说明：", "资料来源", "数据来源", "Note:", "Notes:", "Source:", "Sources:"] where t.hasPrefix(p) {
            return true
        }
        let markers: Set<Character> = ["*", "＊", "†", "‡", "※", "§", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        let circled = f.unicodeScalars.first.map { (0x2460...0x2473).contains($0.value) } ?? false
        guard markers.contains(f) || circled else { return false }
        let rest = String(t.drop(while: { markers.contains($0) || $0.isWhitespace || (circled && $0 == f) }))
        guard rest.count >= (circled ? 12 : 4) else { return false }
        let k = HeadingClassifier.classify(rest).kind
        return !numberedKinds.contains(k) && ![.matter, .trailer, .container, .tocHeading].contains(k)
    }

    /// Lines that cannot be TOC entries, removed before assembly (each with a warning):
    ///   - a list of figures / tables (图表目录, List of Figures, or a run of "图1-1 …" lines);
    ///   - footnotes at the foot of a TOC page (only in a TOC whose pages are in a column or
    ///     after leaders, so the footnotes stand out by having none);
    ///   - the TOC page's own heading without a page (目录, 目录（续）, Contents, a
    ///     "Chapter … Page" column header), and a lone page number right before such a
    ///     heading (the folio of the previous TOC page), so a title wrapped across the page
    ///     break still joins its continuation.
    static func dropNonEntries(_ parsed: inout [Item], columnStyle: Bool, warnings: inout [PrintedTOCWarning]) {
        func span(_ a: Int, _ b: Int) -> String {
            let x = parsed[a].lines.first!, y = parsed[b].lines.last!
            return x == y ? "line \(x)" : "lines \(x)-\(y)"
        }
        var k = 0
        while k < parsed.count {
            let it = parsed[k]
            if it.pageOnly { k += 1; continue }
            func figureEntry(_ j: Int) -> Bool { j < parsed.count && !parsed[j].pageOnly && HeadingClassifier.isFigureEntry(parsed[j].title) }
            // list of figures
            let heading = it.page == nil && HeadingClassifier.isFigureListHeading(it.title) && figureEntry(k + 1) && figureEntry(k + 2)
            if heading || (figureEntry(k) && figureEntry(k + 1) && figureEntry(k + 2)) {
                var j = k + 1
                while j < parsed.count && (parsed[j].pageOnly || HeadingClassifier.isFigureEntry(parsed[j].title)
                                           || HeadingClassifier.isFigureListHeading(parsed[j].title)) { j += 1 }
                while j - 1 > k && parsed[j - 1].pageOnly { j -= 1 }
                warnings.append(PrintedTOCWarning(line: it.lines[0], message: "list of figures or tables skipped (\(span(k, j - 1)), '\(MuluTOCFormat.oneLine(it.title))' …): not part of the table of contents"))
                parsed.removeSubrange(k..<j)
                continue
            }
            // footnotes
            if columnStyle && !it.strong && isFootnoteStart(it.title) {
                var j = k + 1
                let stop: Set<HeadingKind> = [.part, .subpart, .chapter, .section, .dotted, .cnEnum, .cnParen, .appendix, .matter, .container, .tocHeading]
                while j < parsed.count && !parsed[j].pageOnly && !parsed[j].strong
                        && !stop.contains(HeadingClassifier.classify(parsed[j].title).kind) { j += 1 }
                for m in k..<j {
                    warnings.append(PrintedTOCWarning(line: parsed[m].lines[0], message: "footnote at the foot of a TOC page skipped: '\(MuluTOCFormat.oneLine(parsed[m].title))'"))
                }
                parsed.removeSubrange(k..<j)
                continue
            }
            // the TOC page's own heading (and the folio of the page before it)
            if it.page == nil, HeadingClassifier.classify(it.title).kind == .tocHeading,
               k + 1 < parsed.count, !parsed[k + 1].pageOnly {
                var from = k
                if k > 0, parsed[k - 1].pageOnly, k > 1, !parsed[k - 2].pageOnly {
                    warnings.append(PrintedTOCWarning(line: parsed[k - 1].lines[0], message: "lone page number '\(parsed[k - 1].page!.raw)' ignored (the TOC page's own page number)"))
                    from = k - 1
                }
                warnings.append(PrintedTOCWarning(line: it.lines[0], message: "TOC heading '\(MuluTOCFormat.oneLine(it.title))' skipped"))
                parsed.removeSubrange(from...k)
                k = from
                continue
            }
            k += 1
        }
    }

    /// Numbering OCR damaged beyond the per-line repairs, fixed from the neighbouring
    /// entries of the same kind (each fix is flagged):
    ///   - "第章 两汉" (numeral lost; 一 and 二 are thin strokes): the number follows from the
    ///     previous and next headings of that kind ("第三章" … "第五章" → 第四章; right after a
    ///     higher heading, next - 1). Both neighbours must agree when both exist.
    ///   - "（一定投的原理" (closing bracket lost), in a TOC with other （一） entries.
    static func repairNumberingInContext(_ items: inout [Item]) {
        let higher: [HeadingKind: Set<HeadingKind>] = [
            .chapter: [.part, .subpart], .section: [.part, .subpart, .chapter], .part: [], .subpart: [.part],
        ]
        for i in items.indices {
            let h = items[i].heading
            guard h.numbers.isEmpty, h.ocrCorrected, let up = higher[h.kind] else { continue }
            func neighbour(_ step: Int) -> (value: Int?, boundary: Bool, chinese: Bool?) {
                var j = i + step
                while j >= 0 && j < items.count {
                    let k = items[j].heading.kind
                    if up.contains(k) { return (nil, true, nil) }
                    if k == h.kind, let v = items[j].heading.numbers.first {
                        let t = items[j].title
                        let chinese = t.firstIndex(of: "第").map { t.index(after: $0) < t.endIndex && TOCChars.isCNNumeral(t[t.index(after: $0)]) }
                        return (v, false, chinese)
                    }
                    j += step
                }
                return (nil, false, nil)
            }
            let prev = neighbour(-1), next = neighbour(1)
            var value: Int? = nil
            let fromPrev: Int? = prev.value.map { $0 + 1 } ?? (prev.boundary || i == 0 ? 1 : nil)
            let fromNext: Int? = next.value.map { $0 - 1 }
            if let a = fromPrev, let b = fromNext { value = a == b ? a : nil } else { value = fromPrev ?? fromNext }
            guard let v = value, v >= 1, let fixed = HeadingClassifier.insertOrdinal(items[i].title, value: v,
                                                                                     chinese: prev.chinese ?? next.chinese ?? true) else { continue }
            items[i].notes.append("numeral lost by OCR; restored from the neighbouring headings: '\(fixed)'")
            items[i].title = fixed
            items[i].heading.numbers = [v]
        }
        let parenCount = items.filter { $0.heading.kind == .cnParen }.count
        if parenCount >= 2 {
            for i in items.indices where items[i].heading.kind == .none {
                let cs = Array(items[i].title)
                guard cs.count >= 3, cs[0] == "(" || cs[0] == "（" else { continue }
                var j = 1
                while j < cs.count && TOCChars.isCNNumeral(cs[j]) && j < 4 { j += 1 }
                guard j > 1, j < cs.count, TOCChars.isCJK(cs[j]), !TOCChars.isCNNumeral(cs[j]),
                      TOCChars.chineseNumber(cs[1..<j]) != nil else { continue }
                let fixed = String(cs[0..<j]) + (cs[0] == "(" ? ")" : "）") + String(cs[j...])
                items[i].penalize(0.9, "closing bracket lost by OCR; read as '\(String(cs[0..<j]))\(cs[0] == "(" ? ")" : "）")'")
                items[i].title = fixed
                items[i].heading = HeadingClassifier.classify(fixed)
            }
        }
    }

    public static func parse(lines input: [PrintedTOCLine], options: PrintedTOCOptions = PrintedTOCOptions()) -> PrintedTOCResult {
        var warnings: [PrintedTOCWarning] = []

        // --- 1. per-line page split -------------------------------------------------
        var parsed: [Item] = []
        // Two-column lines: the left halves of a run of such lines come first (reading
        // order is down the left column, then down the right one).
        var rightColumn: [Item] = []
        func flushRightColumn() {
            parsed += rightColumn
            rightColumn = []
        }
        var pageLists = 0, letterHeads = 0
        for line in input {
            let (measured, text) = measureIndent(line.text)
            let indent = line.indent ?? measured
            guard !text.allSatisfy(\.isWhitespace) else { continue }
            if looksLikeIndexLine(text) { pageLists += 1 }
            let bare = text.trimmingCharacters(in: .whitespaces)
            if bare.count == 1, let c = bare.first, c.isASCII, c.isUppercase { letterHeads += 1 }
            if let p = pageOnlyLine(text) {
                flushRightColumn()
                var it = Item(title: "", page: p, indent: indent, lines: [line.lineNumber], width: TOCChars.displayWidth(text))
                it.pageOnly = true
                parsed.append(it)
                continue
            }
            let parts = splitColumns(text)
            if parts.count == 1 { flushRightColumn() }
            for (k, part) in parts.enumerated() {
                let s = PageTokenizer.split(part)
                var it = Item(title: s.title, page: s.page, indent: indent, lines: [line.lineNumber], width: TOCChars.displayWidth(part))
                if parts.count > 1 { it.notes.append(k == 0 ? "two-column line split" : "second column of the line") }
                if s.title.isEmpty {
                    if let p = s.page {
                        it.pageOnly = true
                        it.page = p
                    } else {
                        warnings.append(PrintedTOCWarning(line: line.lineNumber, message: "no title or page, ignored: '\(MuluTOCFormat.oneLine(text))'"))
                        continue
                    }
                }
                it.strong = s.page != nil && (s.page!.separation == .leader || s.wide)
                if s.strippedNoise { it.penalize(0.95, "stray punctuation removed") }
                if s.strippedGibberish { it.penalize(0.7, "OCR noise removed from the end of the title") }
                if k == 0 { parsed.append(it) } else { rightColumn.append(it) }
            }
        }
        flushRightColumn()

        let paged = parsed.filter { !$0.pageOnly && $0.page != nil }
        let columnStyle = paged.count >= 5 && Double(paged.filter(\.strong).count) >= 0.6 * Double(paged.count)
        dropNonEntries(&parsed, columnStyle: columnStyle, warnings: &warnings)

        // Reference width of complete lines (those ending in a page after leaders). Text
        // without leaders (OCR output, where they are stripped) uses the widest lines with
        // a page instead: a wrapped first line fills the text block like them.
        let pagedWidths = parsed.filter { !$0.pageOnly && $0.page?.separation == .leader }.map(\.width).sorted()
        // Such a line is also long in absolute terms (24 columns: 12 CJK characters).
        var refWidth: Int? = pagedWidths.count >= 3 ? pagedWidths[pagedWidths.count / 2] : nil
        if refWidth == nil {
            let widths = parsed.filter { !$0.pageOnly && $0.page != nil }.map(\.width).sorted()
            if widths.count >= 5 { refWidth = max(Int((24 / 0.85).rounded(.up)), Int((Double(widths[(widths.count * 9) / 10]) * 0.95).rounded())) }
        }

        // --- 2. assembly ------------------------------------------------------------
        var items: [Item] = []
        var lastLine = -1
        for var cur in parsed {
            defer { lastLine = cur.lines.last! }
            let adjacent = items.last.map { $0.lines.last! == lastLine } ?? false
            if cur.pageOnly {
                if adjacent, var prev = items.last, prev.page == nil, !prev.pageOnly {
                    prev.page = cur.page
                    prev.lines += cur.lines
                    prev.penalize(0.9, "page number on its own line \(cur.lines[0])")
                    items[items.count - 1] = prev
                } else {
                    warnings.append(PrintedTOCWarning(line: cur.lines[0], message: "lone page number '\(cur.page!.raw)' ignored (the TOC page's own page number?)"))
                }
                continue
            }
            if let r = HeadingClassifier.repairNumbering(cur.title) {
                cur.title = r.title
                cur.penalize(0.9, "OCR repair: \(r.note)")
            }
            cur.heading = HeadingClassifier.classify(cur.title)
            if cur.heading.kind == .dotted { cur.title = HeadingClassifier.spaceAfterNumbering(cur.title) }
            let startsLower = cur.title.first.map { $0.isASCII && $0.isLowercase } ?? false
            // A wrapped title whose first line ends in a number ("3.2 回顾20" / "世纪的经济史 …… 26",
            // "Apollo 11" / "and Beyond"): in a TOC whose pages follow leaders or sit in a page
            // column, a number glued to the text (or after one space) with the next, deeper
            // indented, unnumbered line carrying a column page is part of the title.
            if adjacent, columnStyle, var prev = items.last, !prev.pageOnly, !prev.strong, !prev.inherited,
               let pp = prev.page, pp.style == .arabic, pp.separation == .glued || pp.separation == .space,
               cur.strong, cur.page != nil, cur.heading.kind == .none, cur.indent > prev.indent,
               let b = cur.title.first, TOCChars.isCJK(b) || startsLower,
               numberedKinds.contains(prev.heading.kind) || startsLower {
                var joined = prev.title + (pp.separation == .glued ? "" : " ") + pp.raw
                if b.isASCII && b.isLetter { joined += " " }
                prev.title = joined + cur.title
                prev.page = cur.page
                prev.strong = true
                prev.lines += cur.lines
                prev.conf *= cur.conf
                prev.notes += cur.notes
                prev.penalize(0.85, "'\(pp.raw)' is part of the title, which continues on line \(cur.lines[0])")
                warnings.append(PrintedTOCWarning(line: prev.lines[0], message: "'\(pp.raw)' read as part of a title wrapped onto line \(cur.lines[0]), not as its page: '\(MuluTOCFormat.oneLine(prev.title))'"))
                prev.heading = HeadingClassifier.classify(prev.title)
                if prev.heading.kind == .dotted { prev.title = HeadingClassifier.spaceAfterNumbering(prev.title) }
                items[items.count - 1] = prev
                continue
            }
            let startsDash = cur.title.hasPrefix("—") || cur.title.hasPrefix("--") || cur.title.hasPrefix("－") || cur.title.hasPrefix("―")
            if adjacent, var prev = items.last, prev.page == nil, !prev.pageOnly,
               ![.matter, .container, .tocHeading, .trailer].contains(prev.heading.kind),
               cur.heading.kind == .none {
                let wide = refWidth.map { Double(prev.width) >= 0.85 * Double($0) } ?? false
                if looksCutOff(prev.title) || startsLower || wide || startsDash {
                    var joined = prev.title
                    if joined.hasSuffix("-"), startsLower, joined.count >= 2, joined.dropLast().last!.isLetter {
                        joined.removeLast()
                    } else if let a = joined.last, let b = cur.title.first, !startsDash,
                              !(a.isNumber && TOCChars.isCJK(b)) && !(TOCChars.isCJK(a) && b.isNumber),
                              !(TOCChars.isCJK(a) || !a.isASCII) || !(TOCChars.isCJK(b) || !b.isASCII) {
                        joined += " "
                    }
                    prev.title = joined + cur.title
                    prev.page = cur.page
                    prev.strong = cur.strong
                    prev.lines += cur.lines
                    prev.conf *= cur.conf
                    prev.notes += cur.notes
                    prev.penalize(0.85, "title continues on line \(cur.lines[0])")
                    prev.heading = HeadingClassifier.classify(prev.title)
                    if prev.heading.kind == .dotted { prev.title = HeadingClassifier.spaceAfterNumbering(prev.title) }
                    items[items.count - 1] = prev
                    continue
                }
            }
            items.append(cur)
        }

        // TOC page headings and running headers.
        var pagelessCounts: [String: Int] = [:]
        for it in items where it.page == nil && it.heading.kind == .none {
            pagelessCounts[it.title, default: 0] += 1
        }
        items = items.filter { it in
            if it.heading.kind == .tocHeading && it.page == nil {
                warnings.append(PrintedTOCWarning(line: it.lines[0], message: "TOC heading '\(it.title)' skipped"))
                return false
            }
            if it.page == nil && it.heading.kind == .none && (pagelessCounts[it.title] ?? 0) >= 2 {
                warnings.append(PrintedTOCWarning(line: it.lines[0], message: "repeated line '\(MuluTOCFormat.oneLine(it.title))' skipped (running header?)"))
                return false
            }
            return true
        }
        for i in items.indices where items[i].heading.kind == .tocHeading {
            items[i].heading.kind = .matter
        }

        repairNumberingInContext(&items)
        splitGluedNumbering(&items)
        if pageLists >= 2 || letterHeads >= 3 || (pageLists >= 1 && letterHeads >= 2) {
            for i in items.indices { items[i].penalize(0.5, "the lines look like a book index, not a table of contents") }
            if let first = items.first {
                warnings.append(PrintedTOCWarning(line: first.lines[0], message: "these lines look like a book index (letter headings, comma-separated page lists), not a table of contents; every entry is flagged"))
            }
        }

        // Title sanity.
        for i in items.indices {
            let t = items[i].title
            if !t.contains(where: { $0.isLetter || TOCChars.isCJK($0) }) {
                items[i].penalize(0.5, "title has no letters")
            } else if t.count == 1 && !TOCChars.isCJK(t.first!) {
                items[i].penalize(0.6, "one-character title")
            }
            if items[i].heading.ocrCorrected { items[i].penalize(0.9, "OCR repair in the numbering") }
        }

        // --- 3. pages: confidence, Roman → arabic repair, inheritance ------------------
        // Front matter printed "i" / "ii" / "iii" and OCR'd as "1" / "11" / "111": an entry
        // before the first chapter cannot sit on or after the chapter's own (small) page.
        let bodyKinds: Set<HeadingKind> = [.part, .subpart, .chapter, .section, .dotted, .arabic]
        if let b = items.firstIndex(where: { bodyKinds.contains($0.heading.kind) }),
           let bodyStart = items[b...].first(where: { $0.page?.style == .arabic })?.page?.value, bodyStart <= 3 {
            for i in 0..<b where items[i].heading.kind == .matter || items[i].heading.kind == .none {
                guard let p = items[i].page, p.style == .arabic, p.value >= bodyStart, p.raw.count <= 3,
                      p.raw.allSatisfy({ "1lI|".contains($0) }) else { continue }
                let roman = String(repeating: "i", count: p.raw.count)
                items[i].page = PrintedPage(style: .roman, value: p.raw.count, raw: roman, ocrCorrected: true, separation: p.separation)
                items[i].penalize(0.8, "front matter before page \(bodyStart) of chapter 1: read '\(p.raw)' as roman '\(roman)'")
            }
        }
        var seenArabic = false
        var nextArabicValue = [Int](repeating: Int.max, count: items.count)
        var upcoming = Int.max
        for i in items.indices.reversed() {
            nextArabicValue[i] = upcoming
            if items[i].page?.style == .arabic { upcoming = items[i].page!.value }
        }
        var prevArabic = 0
        for i in items.indices {
            guard var p = items[i].page else { continue }
            if p.style == .roman && seenArabic && p.raw.allSatisfy({ $0 == "I" || $0 == "l" || $0 == "|" }) {
                let v = Int(String(p.raw.map { _ in Character("1") }))!
                let nextArabic = nextArabicValue[i]
                if v >= prevArabic && v <= nextArabic {
                    p = PrintedPage(style: .arabic, value: v, raw: p.raw, ocrCorrected: true, isRange: p.isRange, separation: p.separation)
                }
            }
            if p.style == .arabic {
                seenArabic = true
                prevArabic = p.value
            }
            switch p.separation {
            case .leader: break
            case .space, .bracket: items[i].conf *= 0.95
            case .glued: items[i].penalize(0.85, "page number glued to the title")
            case .alone: break
            }
            if p.ocrCorrected { items[i].penalize(0.7, "OCR repair: page '\(p.raw)' read as \(p.value)") }
            if p.isRange { items[i].penalize(0.95, "page range; using the first page") }
            items[i].page = p
        }
        // Next / previous entry with a page of its own, in one pass each (O(n)).
        var nextOwn = [Int?](repeating: nil, count: items.count)
        var following: Int? = nil
        for i in items.indices.reversed() {
            nextOwn[i] = following
            if items[i].page != nil { following = i }
        }
        var previousOwn: Int? = nil
        for i in items.indices {
            guard items[i].page == nil else { previousOwn = i; continue }
            if let n = nextOwn[i] {
                items[i].page = items[n].page
                items[i].notes.append("no page number; using the next entry's page (line \(items[n].lines[0]))")
            } else if let p = previousOwn {
                items[i].page = items[p].page
                items[i].notes.append("no page number; using the previous entry's page (line \(items[p].lines[0]))")
            } else {
                items[i].notes.append("no page number")
            }
            items[i].inherited = true
            items[i].conf = min(items[i].conf, 0.6)
        }

        // --- 4. levels ---------------------------------------------------------------
        assignLevels(&items, options: options)

        // Clamp: at most one deeper than the previous entry.
        var prevLevel = -1
        for i in items.indices {
            if items[i].level > prevLevel + 1 {
                let from = items[i].level
                items[i].level = prevLevel + 1
                items[i].penalize(0.8, "level lowered from \(from) to \(prevLevel + 1) (no parent at level \(from - 1))")
            }
            prevLevel = items[i].level
        }

        // --- 5. page order -------------------------------------------------------------
        for style in [PrintedPage.Style.arabic, .roman] {
            let idx = items.indices.filter { items[$0].page?.style == style && !items[$0].inherited }
            let keep = Set(longestNonDecreasing(idx.map { items[$0].page!.value }).map { idx[$0] })
            for (k, i) in idx.enumerated() where !keep.contains(i) {

                let before = idx[..<k].last(where: { keep.contains($0) })
                let after = idx[(k + 1)...].first(where: { keep.contains($0) })
                var ctx: [String] = []
                if let b = before { ctx.append("previous \(items[b].page!.display) on line \(items[b].lines[0])") }
                if let a = after { ctx.append("next \(items[a].page!.display) on line \(items[a].lines[0])") }
                let msg = "\(orderNotePrefix) page \(items[i].page!.display) is out of order" + (ctx.isEmpty ? "" : " (" + ctx.joined(separator: ", ") + ")")

                items[i].penalize(0.4, msg)
                warnings.append(PrintedTOCWarning(line: items[i].lines[0], message: msg))
            }
        }

        // --- 6. physical pages ---------------------------------------------------------
        var entries: [PrintedTOCEntry] = []
        for var it in items {
            var physical: Int? = nil
            if let p = it.page {
                switch p.style {
                case .arabic:
                    physical = p.value + options.offset
                case .roman:
                    if let r = options.romanOffset {
                        physical = p.value + r
                        it.conf *= 0.9
                    } else {
                        let msg = "front-matter page '\(p.raw)' is not mapped; pass a front-matter offset (--roman-offset N) to include it"
                        it.penalize(0.3, msg)
                        if !it.inherited { warnings.append(PrintedTOCWarning(line: it.lines[0], message: msg)) }
                    }
                case .prefixed:
                    let msg = "page '\(p.raw)' uses appendix-style numbering and cannot be mapped to a physical page"
                    it.penalize(0.3, msg)
                    if !it.inherited { warnings.append(PrintedTOCWarning(line: it.lines[0], message: msg)) }
                }
                if let ph = physical {
                    if ph < 1 {
                        let msg = "page \(p.display) \(options.offset >= 0 ? "+" : "-") \(abs(options.offset)) maps to physical page \(ph)"
                        it.penalize(0.3, msg)
                        warnings.append(PrintedTOCWarning(line: it.lines[0], message: msg))
                        physical = nil
                    } else if let n = options.pageCount, ph > n {
                        let msg = "page \(p.display) maps to physical page \(ph), but the PDF has \(n) pages"
                        it.penalize(0.3, msg)
                        warnings.append(PrintedTOCWarning(line: it.lines[0], message: msg))
                        physical = nil
                    }
                }
            }
            entries.append(PrintedTOCEntry(
                title: it.title, level: it.level, heading: it.heading, printedPage: it.page, physicalPage: physical,
                lines: it.lines, confidence: (it.conf * 100).rounded() / 100, notes: it.notes, pageInherited: it.inherited))
        }
        // Report in line order (stable for equal lines).
        let ordered = warnings.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
        return PrintedTOCResult(entries: entries, warnings: ordered, options: options)
    }

    // MARK: - levels

    static func rank(_ h: Heading, arabicHeadsDotted: Bool) -> Double? {
        switch h.kind {
        case .part, .appendix: return 0
        case .subpart: return 0.5
        case .chapter: return 1
        case .arabic: return arabicHeadsDotted ? 1 : 10
        case .section: return 2
        case .dotted: return Double(2 + min(h.numbers.count, 5))
        case .cnEnum: return 8
        case .cnParen: return 9
        case .arabicParen: return h.circled ? 12 : 11
        default: return nil
        }
    }

    static func assignLevels(_ items: inout [Item], options: PrintedTOCOptions) {
        // Does "1 Title" head a family of "1.1" entries?
        var lastArabic: Int? = nil
        var matched = 0, total = 0
        for it in items {
            switch it.heading.kind {
            case .arabic: lastArabic = it.heading.numbers.first
            case .chapter, .part: lastArabic = nil
            case .dotted:
                if let a = lastArabic {
                    total += 1
                    if it.heading.numbers.first == a { matched += 1 }
                }
            default: break
            }
        }
        let arabicHead = matched >= 1 && matched * 2 >= total

        // Structural entries: parts/chapters, else the top-ranked numbering.
        var structural = items.indices.filter {
            let k = items[$0].heading.kind
            return k == .part || k == .chapter || (k == .arabic && arabicHead)
        }
        if structural.isEmpty {
            let ranks = items.indices.compactMap { i -> (Int, Double)? in
                guard items[i].heading.kind != .appendix, let r = rank(items[i].heading, arabicHeadsDotted: arabicHead) else { return nil }
                return (i, r)
            }
            if let minRank = ranks.map(\.1).min() {
                structural = ranks.filter { $0.1 == minRank }.map(\.0)
            }
        }
        // Matter between the first and last chapter behaves like a chapter trailer.
        if let first = structural.first, let last = structural.last {
            var inside: Set<String> = []
            for i in items.indices where items[i].heading.kind == .matter && i > first && i < last {
                inside.insert(items[i].heading.keyword)
            }
            for i in items.indices where items[i].heading.kind == .matter && i > first && inside.contains(items[i].heading.keyword) {
                items[i].heading.kind = .trailer
            }
        }
        let hasNumbered = items.contains { numberedKinds.contains($0.heading.kind) }

        // Indentation columns (leading spaces, or the x-position passed by OCR).
        let tol = options.indentTolerance
        let sortedIndents = Array(Set(items.map(\.indent))).sorted()
        var clusterStarts: [Double] = []
        for v in sortedIndents where clusterStarts.last.map({ v - $0 > tol }) ?? true { clusterStarts.append(v) }
        func cluster(_ v: Double) -> Int { (clusterStarts.lastIndex(where: { $0 <= v }) ?? 0) }
        var members: [Int: [Int]] = [:]
        for i in items.indices { members[cluster(items[i].indent), default: []].append(i) }
        let informative = clusterStarts.count >= 2 && members.values.filter({ $0.count >= 2 }).count >= 2

        // When the columns agree with the numbering (deeper column ⇒ finer numbering), an
        // unnumbered entry takes the rank of the numbering usually found in its column, so
        // it nests like its numbered neighbours (and a garbled "第？节" still parents "一、").
        var columnRank: [Int: Double] = [:]
        if informative {
            for (c, idx) in members {
                let ranks = idx.compactMap { rank(items[$0].heading, arabicHeadsDotted: arabicHead) }
                guard !ranks.isEmpty else { continue }
                var counts: [Double: Int] = [:]
                for r in ranks { counts[r, default: 0] += 1 }
                columnRank[c] = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!.key
            }
            let known = columnRank.keys.sorted()
            let monotone = zip(known, known.dropFirst()).allSatisfy { columnRank[$0]! < columnRank[$1]! }
            if monotone && !known.isEmpty {
                for c in clusterStarts.indices where columnRank[c] == nil {
                    let before = known.last(where: { $0 < c }).map { columnRank[$0]! }
                    let after = known.first(where: { $0 > c }).map { columnRank[$0]! }
                    switch (before, after) {
                    case let (b?, a?): columnRank[c] = (b + a) / 2
                    case let (b?, nil): columnRank[c] = b + 0.5 * Double(c - known.last(where: { $0 < c })!)
                    case let (nil, a?): columnRank[c] = a - 0.5
                    default: break
                    }
                }
            } else {
                columnRank = [:]
            }
        }

        var stack: [Double] = []
        var rankUsed = [Double?](repeating: nil, count: items.count)
        for i in items.indices {
            let h = items[i].heading
            if let r = rank(h, arabicHeadsDotted: arabicHead) {
                while let top = stack.last, top >= r { stack.removeLast() }
                items[i].level = stack.count
                stack.append(r)
                rankUsed[i] = r
                continue
            }
            switch h.kind {
            case .matter, .tocHeading:
                stack = []
                items[i].level = 0
                // so entries indented under it (by column) can nest
                if let r = columnRank[cluster(items[i].indent)] { stack = [r] }
            case .container:
                stack = [-0.5]
                items[i].level = 0
            case .trailer:
                // 本节小结 / 习题1-1 belong to the section (第X节 or 1.1), others to the chapter.
                let limit: Double = h.keyword.contains("节") || h.numbers.count >= 2 ? 4 : 1
                if let t = stack.lastIndex(where: { $0 <= limit }) {
                    items[i].level = t + 1
                    stack.removeSubrange((t + 1)...)
                } else {
                    items[i].level = stack.isEmpty ? 0 : 1
                    if !stack.isEmpty { stack.removeSubrange(1...) }
                }
            default:  // unnumbered
                let c = cluster(items[i].indent)
                if let r = columnRank[c] {
                    // Same column as the entry above it (with only deeper entries in between):
                    // its sibling, whatever numbering that one has ("3D打印技术" after
                    // "1.5倍速播放…"). Otherwise the column's usual numbering rank.
                    var j = i - 1
                    while j >= 0 && cluster(items[j].indent) > c { j -= 1 }
                    if j >= 0, cluster(items[j].indent) == c, let rj = rankUsed[j],
                       ![.matter, .tocHeading, .container, .trailer].contains(items[j].heading.kind) {
                        let lvl = min(items[j].level, stack.count)
                        stack = Array(stack.prefix(lvl))
                        items[i].level = lvl
                        stack.append(rj)
                        rankUsed[i] = rj
                    } else {
                        while let top = stack.last, top >= r { stack.removeLast() }
                        items[i].level = stack.count
                        stack.append(r)
                        rankUsed[i] = r
                    }
                    items[i].penalize(0.9, "unnumbered: level from indentation")
                    continue
                }
                if i > 0 && items[i - 1].heading.kind == .none {
                    items[i].level = items[i - 1].level
                } else if let top = stack.last {
                    items[i].level = top <= 2 ? stack.count : stack.count - 1
                } else {
                    items[i].level = 0
                }
                if hasNumbered && i > 0 && !informative { items[i].penalize(0.8, "unnumbered: level guessed from context") }
            }
        }
        guard informative else { return }

        var clusterLevel: [Int: Int] = [:]
        var clusterPure: [Int: Bool] = [:]
        for (c, idx) in members {
            let levels = idx.filter { items[$0].heading.kind != .none }.map { items[$0].level }
            guard !levels.isEmpty else { continue }
            var counts: [Int: Int] = [:]
            for l in levels { counts[l, default: 0] += 1 }
            let best = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!
            clusterLevel[c] = best.key
            clusterPure[c] = Double(best.value) >= 0.8 * Double(levels.count)
        }
        // Without usable numbering in the columns: the numbered entries' level where there
        // are some, else one deeper than the column to its left.
        var effective: [Int] = []
        for c in clusterStarts.indices {
            effective.append(clusterLevel[c] ?? (c == 0 ? 0 : effective[c - 1] + 1))
        }
        for i in items.indices {
            let c = cluster(items[i].indent)
            if items[i].heading.kind == .none {
                guard columnRank.isEmpty else { continue }
                items[i].level = effective[c]
                if !clusterLevel.isEmpty { items[i].penalize(0.9, "unnumbered: level from indentation") }
            } else if let l = clusterLevel[c], clusterPure[c] == true, l != items[i].level, numberedKinds.contains(items[i].heading.kind) {
                items[i].penalize(0.85, "indentation suggests level \(l), numbering gives \(items[i].level)")
            }
        }
    }


    /// "1.21.5万亿投资" after "1.1 …" (OCR dropped the space in "1.2 1.5万亿投资"): when the
    /// title starts with the expected next number of the sequence (1.2, 1.1.1, 2.1, …) glued
    /// to a further number that reads as a quantity (a decimal, or digits before 年 万 % …),
    /// and the numbering as read is not itself an expected successor, it is split (flagged).
    static func splitGluedNumbering(_ items: inout [Item]) {
        var prevDotted: [Int]? = nil
        var chapter: Int? = nil
        let units: Set<Character> = ["%", "％", "年", "月", "日", "倍", "万", "亿", "千", "百", "兆", "元", "个", "种", "项", "岁", "次", "位", "天"]
        for i in items.indices {
            let h = items[i].heading
            switch h.kind {
            case .chapter, .arabic:
                if let v = h.numbers.first { chapter = v }
                prevDotted = nil
                continue
            case .part: chapter = nil; prevDotted = nil; continue
            default: break
            }
            var cands: [[Int]] = []
            if let p = prevDotted {
                if p.count >= 2 { for d in 2...p.count { cands.append(Array(p.prefix(d - 1)) + [p[d - 1] + 1]) } }
                cands.append(p + [1])
            }
            if let c = chapter { cands += [[c, 1], [c + 1, 1]] }
            if h.kind == .dotted && (cands.isEmpty || cands.contains(h.numbers)) { prevDotted = h.numbers; continue }
            guard h.kind == .dotted || h.kind == .none else { continue }
            let t = Array(TOCChars.halfWidth(items[i].title))
            var done = false
            for cand in cands.sorted(by: { $0.count > $1.count }) where !done {
                let s = Array(cand.map(String.init).joined(separator: "."))
                guard t.count > s.count + 1, Array(t[..<s.count]) == s, TOCChars.isDigit(t[s.count]) else { continue }
                var k = s.count
                while k < t.count && TOCChars.isDigit(t[k]) { k += 1 }
                var decimal = false
                if k + 1 < t.count && t[k] == "." && TOCChars.isDigit(t[k + 1]) {
                    decimal = true
                    k += 1
                    while k < t.count && TOCChars.isDigit(t[k]) { k += 1 }
                }
                guard decimal || (k < t.count && units.contains(t[k])) else { continue }
                let orig = Array(items[i].title)
                let fixed = String(orig[..<s.count]) + " " + String(orig[s.count...])
                items[i].penalize(0.9, "numbering '\(String(orig[..<k]))' read as \(String(s)) followed by '\(String(orig[s.count..<k]))' (OCR dropped a space)")
                items[i].title = fixed
                items[i].heading = HeadingClassifier.classify(fixed)
                prevDotted = cand
                done = true
            }
            if !done && h.kind == .dotted { prevDotted = h.numbers }
        }
    }

    /// "阿基米德原理 23, 45": a comma-separated list of pages (a book index line).
    static func looksLikeIndexLine(_ text: String) -> Bool {
        let cs = Array(TOCChars.halfWidth(text.trimmingCharacters(in: .whitespaces)))
        var k = cs.count
        var groups = 0
        while k > 0 {
            var d = k
            while d > 0 && TOCChars.isDigit(cs[d - 1]) { d -= 1 }
            guard d < k else { break }
            groups += 1
            var m = d
            while m > 0 && cs[m - 1] == " " { m -= 1 }
            guard m > 0, ",，、;；".contains(cs[m - 1]) else { break }
            m -= 1
            while m > 0 && cs[m - 1] == " " { m -= 1 }
            k = m
        }
        return groups >= 2
    }

    /// Indexes (into `values`) of one longest non-decreasing subsequence.
    static func longestNonDecreasing(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []       // index into values of the smallest tail for each length
        var prev = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            // first tail with value > v (upper bound, for non-decreasing)
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tails[mid]] <= v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [Int] = []
        var k = tails.last!
        while k >= 0 { out.append(k); k = prev[k] }
        return out.reversed()
    }
}
