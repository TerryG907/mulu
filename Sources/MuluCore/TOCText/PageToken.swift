import Foundation

/// A page number as printed at the end of a TOC line.
public struct PrintedPage: Sendable, Equatable {
    public enum Style: String, Sendable {
        case arabic
        case roman     // front matter: i, ii, xiv
        case prefixed  // appendix pagination: A1, B-12 (never mapped to a physical page)
    }
    /// How the number was separated from the title.
    public enum Separation: String, Sendable {
        case leader   // dot leaders / rules (…… ····· ..... ——)
        case space    // plain whitespace
        case bracket  // (12) 【12】
        case glued    // directly after a CJK character: "导论2"
        case alone    // the whole line is the number
    }

    public var style: Style
    public var value: Int
    public var raw: String
    public var ocrCorrected: Bool
    public var isRange: Bool
    public var separation: Separation

    public init(style: Style, value: Int, raw: String, ocrCorrected: Bool = false, isRange: Bool = false, separation: Separation) {
        self.style = style
        self.value = value
        self.raw = raw
        self.ocrCorrected = ocrCorrected
        self.isRange = isRange
        self.separation = separation
    }

    public var display: String { style == .arabic ? String(value) : raw }
}

/// Splits one printed-TOC line into its title and trailing page number.
///
/// Page tokens: ASCII / full-width digits, Roman numerals (front matter), page ranges
/// ("12-15" → 12), bracketed numbers ("(12)", "【12】"), "p. 12", "第12页". OCR
/// confusions inside a number are repaired (O/o → 0, l/I/| → 1) and flagged. Trailing
/// dot leaders and stray punctuation are removed from the title.
enum PageTokenizer {
    struct Split {
        var title: String
        var page: PrintedPage?
        var strippedNoise = false
        var strippedGibberish = false
        /// The page follows a TAB or at least two spaces (a right-aligned page column).
        var wide = false
    }

    static let trailingNoise: Set<Character> = [
        "。", "，", ",", ";", "；", ":", "：", "'", "\"", "’", "”", "‘", "“", "`", "´", "、", "!", "！",
        "*", "^", "\\", "/", "|", "｜", "¦",
    ]
    /// OCR debris between a title and its page (misread leaders).
    static let junkBeforePage: Set<Character> = ["、", "’", "‘", "'", "`", ",", "，", "×", "ˊ", "ˋ", "¸", "·", "⋅"]
    /// OCR debris in front of a title (no title starts with these).
    static let junkBeforeTitle: Set<Character> = ["：", ":", "⋅", "・", "，", ",", "。", "'", "’", "`", "、", "·"]
    static let confusables: [Character: Character] = ["O": "0", "o": "0", "l": "1", "I": "1", "|": "1"]
    static let connectors: Set<Character> = ["-", "–", "—", "~", "～", "‒", "−"]
    /// "28 至 35" / "28到35": a range written with a word.
    static let rangeWords: Set<Character> = ["至", "到"]
    static let brackets: [Character: Character] = [
        ")": "(", "）": "（", "]": "[", "}": "{", ">": "<", "】": "【", "」": "「", "》": "《", "〕": "〔",
    ]
    /// A trailing number after one of these words belongs to the title ("Part 2", "World War II").
    static let numberingWords: Set<String> = [
        "part", "chapter", "chap", "ch", "section", "sec", "book", "volume", "vol", "appendix", "unit",
        "lesson", "lecture", "module", "act", "scene", "day", "step", "level", "phase", "stage", "no",
        "number", "figure", "fig", "table", "exercise", "problem", "war", "grade", "class", "version",
        "edition", "ed", "vol.", "no.", "ch.", "sec.", "fig.",
    ]

    static func split(_ line: String) -> Split {
        let cs = Array(line)
        let n = cs.map(TOCChars.halfWidth)
        var e = n.count
        var result = Split(title: "", page: nil)

        func trimSpaces() { while e > 0 && n[e - 1].isWhitespace { e -= 1 } }
        trimSpaces()
        let fullEnd = e

        // 1. Stray punctuation after the number ("12。", "12'", "12 |").
        var guardCount = 0
        while e > 0 && guardCount < 6 {
            guardCount += 1
            let c = n[e - 1]
            if trailingNoise.contains(c) {
                e -= 1
                result.strippedNoise = true
                trimSpaces()
            } else if (c == "." || c == "·" || c == "•") && e >= 2 && TOCChars.isDigit(n[e - 2]) {
                e -= 1
                result.strippedNoise = true
            } else {
                break
            }
        }

        // 2. "第12页" / "12页".
        var pageSuffix = false
        if e >= 2 && n[e - 1] == "页" && TOCChars.isDigit(n[e - 2]) {
            e -= 1
            pageSuffix = true
        }

        var titleEnd = e
        var page: PrintedPage? = nil

        // 3. Bracketed number at the end: "(12)", "【12】", "（xii）".
        if e >= 3, let opener = brackets[n[e - 1]] {
            var o = e - 2
            while o >= 0 && e - o <= 12 && n[o] != opener { o -= 1 }
            if o >= 0 && n[o] == opener {
                let inner = String(n[(o + 1)..<(e - 1)]).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty && inner.count <= 5 && inner.allSatisfy(TOCChars.isDigit), let v = Int(inner), v > 0 {
                    page = PrintedPage(style: .arabic, value: v, raw: inner, separation: .bracket)
                    titleEnd = o
                } else if let r = TOCChars.romanValue(inner), inner == inner.lowercased(), r <= 200 {
                    page = PrintedPage(style: .roman, value: r, raw: inner, separation: .bracket)
                    titleEnd = o
                }
            }
        }

        // 4. Trailing run of page characters.
        if page == nil, let (p, end) = prefixedPage(n, end: e) {
            page = p
            titleEnd = end
        }
        if page == nil {
            var j = e
            while j > 0 && isPageRunChar(n[j - 1]) { j -= 1 }
            // Leading connectors belong to the leaders ("——12").
            while j < e && connectors.contains(n[j]) { j += 1 }
            if j < e {
                (page, titleEnd) = classifyRun(n: n, start: j, end: e)
            }
        }

        if var p = page, p.separation != .alone {
            // "p. 12" / "pp. 12-15"
            var k = titleEnd
            while k > 0 && (n[k - 1].isWhitespace || n[k - 1] == ".") { k -= 1 }
            var w = k
            while w > 0 && TOCChars.isLatinLetter(n[w - 1]) { w -= 1 }
            let word = String(n[w..<k]).lowercased()
            if (word == "p" || word == "pp" || word == "s") && (w == 0 || n[w - 1].isWhitespace || TOCChars.isLeader(n[w - 1])) {
                titleEnd = w
                if p.separation == .glued { p.separation = .space }
                page = p
            }
        }

        // Last resort after dot leaders: a token of digits and letters OCR confuses with
        // digits ("2S" → 25, "B0" → 80).
        if page == nil, let (p, end) = looseOCRPage(n, end: e) {
            page = p
            titleEnd = end
        }
        // "抗高血压药 4.0": OCR put a dot inside a two-digit page (Chinese titles only).
        if page == nil, e >= 4, n[0..<e].contains(where: TOCChars.isCJK),
           TOCChars.isDigit(n[e - 1]), n[e - 2] == ".", TOCChars.isDigit(n[e - 3]), n[e - 4].isWhitespace,
           let v = Int(String([n[e - 3], n[e - 1]].map { Character(String(TOCChars.digit($0)!)) })), v > 0 {
            page = PrintedPage(style: .arabic, value: v, raw: String(n[(e - 3)..<e]), ocrCorrected: true, separation: .space)
            titleEnd = e - 3
        }

        // A number right after a numbering word is part of the title: "Part 2", "Chapter IV",
        // "交通与住房的第2" (never a page: "第12页" is handled above). Not after a TAB or a
        // wide gap: "Solving the Problem<TAB>7" ends in a page column.
        if let p = page, p.separation == .space || p.separation == .glued || (p.style == .roman && p.separation != .leader),
           !wideGap(n, before: titleEnd) {
            let before = String(n[0..<titleEnd]).trimmingCharacters(in: .whitespaces)
            let lastWord = before.split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased() } ?? ""
            if (p.separation != .glued && numberingWords.contains(lastWord)) || (before.hasSuffix("第") && !pageSuffix) {
                page = nil
                titleEnd = e
            }
        }
        // An upper-case Roman number after a single space is usually a title ("World War II").
        if let p = page, p.style == .roman, p.separation == .space, p.raw != p.raw.lowercased() {
            var k = titleEnd, spaces = 0
            while k > 0 && n[k - 1].isWhitespace { k -= 1; spaces += n[k] == "\t" ? 2 : 1 }
            if spaces < 2 {
                page = nil
                titleEnd = e
            }
        }

        // Without a page, nothing after the title was a page decoration: keep "、" / "页".
        if page == nil {
            titleEnd = fullEnd
            result.strippedNoise = false
        } else if page?.separation != .alone {
            result.wide = wideGap(n, before: titleEnd)
        }

        // Title: strip trailing leaders/whitespace (and "第" of "第12页"). A pageless line
        // keeps a single hyphen after a letter: it is a word broken across lines ("Alge-").
        var t = titleEnd
        let hyphenated = page == nil && t >= 2 && n[t - 1] == "-" && n[t - 2].isLetter
        var changed = !hyphenated
        let hasCJK = n[0..<t].contains(where: TOCChars.isCJK)
        while changed {
            changed = false
            while t > 0 && (n[t - 1].isWhitespace || TOCChars.isLeader(n[t - 1]) || (page != nil && junkBeforePage.contains(n[t - 1]))) {
                t -= 1
                changed = true
            }
            if page != nil && pageSuffix && t > 0 && n[t - 1] == "第" { t -= 1; changed = true }
            guard page != nil, t > 0 else { continue }
            // Leaders misread as "一" after an English title, or as a stray letter after a
            // Chinese one ("序 …j 9").
            if n[t - 1] == "一" && !n[0..<(t - 1)].contains(where: TOCChars.isCJK)
                && n[0..<(t - 1)].contains(where: TOCChars.isLatinLetter) {
                t -= 1
                changed = true
                continue
            }
            if hasCJK {
                var k = t
                while k > 0 && n[k - 1].isASCII && n[k - 1].isLetter && t - k < 3 { k -= 1 }
                if k < t && t - k <= 2 && k > 0 && TOCChars.isLeader(n[k - 1]) { t = k; changed = true }
            }
        }
        // The page read twice ("临床应用 6 O<TAB>60"), or a lone invalid "0" page.
        if let p = page, p.style == .arabic {
            var k = t, tokens: [String] = []
            while tokens.count < 3 {
                var a = k
                while a > 0 && (TOCChars.isDigit(n[a - 1]) || confusables[n[a - 1]] != nil) && k - a < 3 { a -= 1 }
                guard a < k, a > 0, n[a - 1].isWhitespace else { break }
                tokens.insert(String(n[a..<k]), at: 0)
                k = a
                while k > 0 && n[k - 1].isWhitespace { k -= 1 }
            }
            let mapped = String(tokens.joined().map { TOCChars.digit($0).map { Character(String($0)) } ?? confusables[$0] ?? $0 })
            if !tokens.isEmpty, !mapped.isEmpty, String(p.value).hasPrefix(mapped), k > 0,
               tokens.joined().contains(where: { confusables[$0] != nil }) || mapped == String(p.value) {
                t = k
                result.strippedNoise = true
            }
        }
        // "组织----------- 1<TAB>9" / "附则== 11<TAB>32": a short number between a run of
        // leaders and the page is OCR debris (a leader glyph or the page read twice).
        if page != nil {
            var a = t
            while a > 0 && TOCChars.isDigit(n[a - 1]) && t - a < 3 { a -= 1 }
            if a < t, a > 0, !TOCChars.isDigit(n[a - 1]) {
                var b = a
                while b > 0 && n[b - 1].isWhitespace { b -= 1 }
                var l = b
                while l > 0 && TOCChars.isLeader(n[l - 1]) { l -= 1 }
                if b - l >= 2, l > 0, n[0..<l].contains(where: { $0.isLetter || TOCChars.isCJK($0) }) {
                    t = l
                    while t > 0 && (n[t - 1].isWhitespace || TOCChars.isLeader(n[t - 1])) { t -= 1 }
                    result.strippedNoise = true
                }
            }
        }
        if page == nil, t >= 2, n[t - 1] == "0", n[t - 2].isWhitespace, n[0..<(t - 2)].contains(where: { !$0.isWhitespace }) {
            t -= 2
            while t > 0 && n[t - 1].isWhitespace { t -= 1 }
        }
        var s = 0
        while s < t && (n[s].isWhitespace || junkBeforeTitle.contains(n[s])) { s += 1 }
        var titleChars = Array(cs[s..<t])

        // OCR sometimes reads dot leaders as a run of random Latin letters glued to CJK text.
        if let cut = gibberishTail(titleChars) {
            titleChars = Array(titleChars[..<cut])
            while let last = titleChars.last, last.isWhitespace || TOCChars.isLeader(last) { titleChars.removeLast() }
            result.strippedGibberish = true
        }
        result.title = normalizeTitle(titleChars)
        result.page = page
        return result
    }

    static func isPageRunChar(_ c: Character) -> Bool {
        TOCChars.isDigit(c) || confusables[c] != nil || TOCChars.isRomanChar(c) || connectors.contains(c)
    }

    /// Classifies n[start..<end] (a run of page characters). Returns the page (if any) and
    /// where the title ends.
    private static func classifyRun(n: [Character], start: Int, end: Int) -> (PrintedPage?, Int) {
        var j = start
        var run = Array(n[j..<end])
        let hasDigit = run.contains(where: TOCChars.isDigit)

        func separation(before idx: Int) -> PrintedPage.Separation? {
            if idx == 0 { return .alone }
            let c = n[idx - 1]
            if c.isWhitespace {
                var k = idx - 1
                while k > 0 && n[k - 1].isWhitespace { k -= 1 }
                if k == 0 { return .alone }
                return TOCChars.isLeader(n[k - 1]) ? .leader : .space
            }
            if TOCChars.isLeader(c) { return .leader }
            if TOCChars.isLatinLetter(c) || TOCChars.isDigit(c) { return nil }
            return .glued
        }

        if hasDigit {
            // Letters in front of the first digit that are glued to a word are title text
            // ("Hello12" → no page; "绪论 l2" → 12).
            if j > 0 && TOCChars.isLatinLetter(n[j - 1]) {
                guard let firstDigit = run.firstIndex(where: TOCChars.isDigit) else { return (nil, end) }
                j += firstDigit
                run = Array(n[j..<end])
            }
            // Range "12-15": keep the first number. Also "12 - 15" with spaces.
            var isRange = false
            if let k = run.firstIndex(where: { connectors.contains($0) }) {
                let right = run[(k + 1)...]
                guard right.contains(where: TOCChars.isDigit) else { return (nil, end) }
                run = Array(run[..<k])
                isRange = true
            } else {
                var k = j
                while k > 0 && n[k - 1].isWhitespace { k -= 1 }
                if k > 0 && (connectors.contains(n[k - 1]) || rangeWords.contains(n[k - 1])) {
                    var m = k - 1
                    while m > 0 && n[m - 1].isWhitespace { m -= 1 }
                    var d = m
                    while d > 0 && TOCChars.isDigit(n[d - 1]) { d -= 1 }
                    if d < m && (d == 0 || !TOCChars.isDigit(n[d - 1])) && (m - d) <= 5 {
                        // "12 - 15": the page is the left number
                        let left = Array(n[d..<m])
                        let startIdx = d
                        guard let sep = separation(before: startIdx) else { return (nil, end) }
                        if let v = Int(String(left.map { Character(String(TOCChars.digit($0)!)) })), v > 0 {
                            return (PrintedPage(style: .arabic, value: v, raw: String(left), isRange: true, separation: sep), startIdx)
                        }
                    }
                }
            }
            guard !run.isEmpty, run.count <= 6 else { return (nil, end) }
            var digits = ""
            var fixed = false
            for c in run {
                if let d = TOCChars.digit(c) {
                    digits.append(Character(String(d)))
                } else if let r = confusables[c] {
                    digits.append(r)
                    fixed = true
                } else {
                    return (nil, end)
                }
            }
            guard digits.count <= 5, let v = Int(digits), v > 0 else { return (nil, end) }
            guard let sep = separation(before: j) else { return (nil, end) }
            if fixed && sep == .glued { return (nil, end) }
            return (PrintedPage(style: .arabic, value: v, raw: String(run), ocrCorrected: fixed, isRange: isRange, separation: sep), j)
        }

        // No digits: a Roman numeral (front matter), or "l"/"ll" misread for 1/11.
        guard let sep = separation(before: j), sep != .glued else { return (nil, end) }
        let raw = String(run)
        if !run.isEmpty && run.count <= 2 && run.allSatisfy({ $0 == "l" }) {
            return (PrintedPage(style: .arabic, value: run.count == 1 ? 1 : 11, raw: raw, ocrCorrected: true, separation: sep), j)
        }
        // "lO" / "IO": only OCR confusables, including an O (never part of a Roman numeral).
        if run.count <= 4, run.allSatisfy({ confusables[$0] != nil }), run.contains(where: { $0 == "O" || $0 == "o" }),
           run.first != "O", run.first != "o",
           let v = Int(String(run.map { confusables[$0]! })), v > 0 {
            return (PrintedPage(style: .arabic, value: v, raw: raw, ocrCorrected: true, separation: sep), j)
        }
        if let r = TOCChars.romanValue(raw), r <= 200 {
            return (PrintedPage(style: .roman, value: r, raw: raw, separation: sep), j)
        }
        return (nil, end)
    }

    /// Appendix-style pagination at the end of the line: "A1", "A-12", "B133" (one capital
    /// letter, optional hyphen, 1-4 digits), after dot leaders or a wide gap.
    static func prefixedPage(_ n: [Character], end: Int) -> (PrintedPage, Int)? {
        var d = end
        while d > 0 && TOCChars.isDigit(n[d - 1]) && end - d < 5 { d -= 1 }
        guard d < end, end - d <= 4, d > 0, !TOCChars.isDigit(n[d - 1]) else { return nil }
        var k = d
        if n[k - 1] == "-" || n[k - 1] == "–" { k -= 1 }
        // not I/O: "I2" / "O5" are OCR misreadings of 12 / 05
        guard k > 0, let letter = n[k - 1].asciiValue, letter >= 65, letter <= 90, letter != 73, letter != 79 else { return nil }
        let start = k - 1
        guard start > 0, n[start - 1].isWhitespace || TOCChars.isLeader(n[start - 1]) else { return nil }
        var b = start
        while b > 0 && n[b - 1].isWhitespace { b -= 1 }
        let leader = b > 0 && TOCChars.isLeader(n[b - 1])
        guard leader || wideGap(n, before: start), b > 0,
              let v = Int(String(n[d..<end].map { Character(String(TOCChars.digit($0)!)) })) else { return nil }
        return (PrintedPage(style: .prefixed, value: v, raw: String(n[start..<end]), separation: leader ? .leader : .space), start)
    }

    static let looseConfusables: [Character: Character] = [
        "O": "0", "o": "0", "D": "0", "Q": "0", "l": "1", "I": "1", "|": "1", "i": "1", "S": "5", "s": "5",
        "Z": "2", "z": "2", "B": "8", "g": "9", "q": "9", "b": "6", "G": "6", "T": "7",
    ]

    static func looseOCRPage(_ n: [Character], end: Int) -> (PrintedPage, Int)? {
        var s = end
        while s > 0 && !n[s - 1].isWhitespace && !TOCChars.isLeader(n[s - 1]) && end - s <= 5 { s -= 1 }
        guard end - s >= 2, end - s <= 5, s > 0 else { return nil }
        let token = n[s..<end]
        guard token.contains(where: TOCChars.isDigit),
              token.allSatisfy({ TOCChars.isDigit($0) || looseConfusables[$0] != nil }) else { return nil }
        var b = s, leaders = 0
        while b > 0 && (n[b - 1].isWhitespace || TOCChars.isLeader(n[b - 1])) {
            if TOCChars.isLeader(n[b - 1]) { leaders += 1 }
            b -= 1
        }
        guard leaders >= 2, b > 0 else { return nil }
        let digits = String(token.map { c in TOCChars.digit(c).map { Character(String($0)) } ?? looseConfusables[c]! })
        guard let v = Int(digits), v > 0 else { return nil }
        return (PrintedPage(style: .arabic, value: v, raw: String(token), ocrCorrected: true, separation: .leader), s)
    }

    /// At least two spaces (a TAB counts as two) before index `idx`.
    static func wideGap(_ n: [Character], before idx: Int) -> Bool {
        var k = idx, spaces = 0
        while k > 0 && n[k - 1].isWhitespace { k -= 1; spaces += n[k] == "\t" ? 2 : 1 }
        return spaces >= 2
    }

    /// Index where a trailing run of random Latin letters glued to CJK text starts.
    static func gibberishTail(_ cs: [Character]) -> Int? {
        var i = cs.count
        while i > 0 && cs[i - 1].isASCII && cs[i - 1].isLetter { i -= 1 }
        let len = cs.count - i
        guard len >= 8, i > 0, TOCChars.isCJK(cs[i - 1]) else { return nil }
        let run = Array(cs[i...])
        var score = 0
        for k in 1..<run.count {
            let a = run[k - 1], b = run[k]
            if a.isLowercase && b.isUppercase { score += 1 }
            if a.isUppercase && b.isLowercase && k + 1 < run.count && run[k + 1].isUppercase { score += 1 }
        }
        return (score >= 3 || len >= 20) ? i : nil
    }

    /// Collapses whitespace runs to one space; "目　录" / "前 言" (single CJK characters
    /// spaced out for typographic effect) are joined.
    static func normalizeTitle(_ cs: [Character]) -> String {
        let words = String(cs).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 2 && words.count <= 8 && words.allSatisfy({ $0.count == 1 && TOCChars.isCJK($0.first!) }) {
            return words.joined()
        }
        // No space after CJK enumeration punctuation: "一、 企业文化" → "一、企业文化".
        var out = ""
        for w in words {
            if let last = out.last, "、）】〕：，".contains(last), let first = w.first, TOCChars.isCJK(first) {
                out += w
            } else {
                out += out.isEmpty ? w : " " + w
            }
        }
        return out
    }
}
