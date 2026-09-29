import Foundation

// Pure text rules for page-number tokens as OCR reads them (no Vision here, so they are
// unit-tested directly).
//
//   arabic   ASCII or full-width digits (１２３); ranges "12-15" / "12–15" keep their first
//            page; OCR confusions O/o -> 0 and l/I -> 1 are repaired when the token also
//            has a real digit (or when dot leaders precede it) and the result is `noisy`.
//   roman    i..xl (front matter), canonical forms only; upper case only after dot leaders
//            or standing alone, so "Part II" / "Appendix C" are not read as page numbers.
//   leaders  runs of . · • … ‥ ⋯ - — – _ ~ ・ ． 。 (and spaces) between title and number.

public enum PageKind: String, Sendable {
    case arabic
    case roman
}

public struct PageNumber: Sendable, Equatable {
    public var value: Int
    public var kind: PageKind
    /// Normalized text: ASCII digits ("12", "12-15") or a lower-case roman numeral.
    public var text: String
    /// O/o/l/I had to be read as digits.
    public var noisy: Bool
    /// An upper-case roman numeral ("IV"), which could also be misread letters.
    public var upperRoman: Bool

    public init(value: Int, kind: PageKind, text: String, noisy: Bool = false, upperRoman: Bool = false) {
        self.value = value
        self.kind = kind
        self.text = text
        self.noisy = noisy
        self.upperRoman = upperRoman
    }
}

/// A line split into title and trailing page token.
public struct TrailingSplit: Sendable, Equatable {
    /// Text before the token, with dot leaders and trailing separators removed.
    public var title: String
    public var number: PageNumber
    /// The token (including a range) in the original text.
    public var tokenRange: Range<String.Index>
    /// Dot leaders (two or more leader characters, or an ellipsis) precede the token.
    public var leader: Bool
    /// The token touches the title with nothing in between ("绪论12").
    public var abutting: Bool
}

public enum PageToken {
    static let leaderChars: Set<Character> = [
        ".", "·", "•", "…", "‥", "⋯", "-", "—", "–", "―", "‒", "_", "~", "～", "․", "‧", "∙", "・", "･", "⋅",
        "。", "．", "﹒", "－", "＿", "…", "︙", "∶",
    ]
    static let separatorChars: Set<Character> = [",", "，", ":", "：", ";", "；", "'", "\"", "`", "‘", "’", "“", "”"]
    static let strayTrailing: Set<Character> = [
        ".", ",", ";", ":", "'", "\"", "`", ")", "]", "}", "|", "»", "›", "）", "】", "」", "』", "。", "，", "、", "’", "”",
    ]
    static let rangeDashes: Set<Character> = ["-", "–", "—", "~", "～", "－", "‒"]
    static let romanChars: Set<Character> = ["i", "v", "x", "l", "c", "d", "m", "I", "V", "X", "L", "C", "D", "M"]
    static let noiseDigits: [Character: Character] = ["O": "0", "o": "0", "l": "1", "I": "1"]

    /// Canonical roman numerals 1...40.
    static let romanTable: [String: Int] = {
        let ones = ["", "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix"]
        let tens = ["", "x", "xx", "xxx", "xl"]
        var t: [String: Int] = [:]
        for v in 1...40 { t[tens[v / 10] + ones[v % 10]] = v }
        return t
    }()

    /// ASCII value of a decimal digit, including full-width digits; nil otherwise.
    @inline(__always) static func digit(_ c: Character) -> Character? {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return nil }
        switch s.value {
        case 0x30...0x39: return c
        case 0xFF10...0xFF19: return Character(Unicode.Scalar(s.value - 0xFF10 + 0x30)!)
        default: return nil
        }
    }

    static func isLeader(_ c: Character) -> Bool { leaderChars.contains(c) }

    static func isTokenChar(_ c: Character) -> Bool {
        digit(c) != nil || noiseDigits[c] != nil || romanChars.contains(c)
    }

    static func isASCIIAlnum(_ c: Character) -> Bool {
        guard c.isASCII, let s = c.unicodeScalars.first else { return false }
        return (0x30...0x39).contains(s.value) || (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
    }

    /// Parses a bare token ("12", "１２", "1O", "12-15", "xii").
    /// - Parameter allowNoiseOnly: accept a token made only of O/l/I look-alikes (e.g. "lO").
    public static func parse(_ token: String, allowNoiseOnly: Bool = false, allowUpperRoman: Bool = true) -> PageNumber? {
        let chars = Array(token)
        guard !chars.isEmpty, chars.count <= 11 else { return nil }
        // Roman first: every character is a roman letter and the whole is canonical 1...40.
        if chars.allSatisfy({ romanChars.contains($0) }) {
            let lower = token.lowercased()
            if let v = romanTable[lower] {
                let upper = token != lower
                if upper && !allowUpperRoman { return nil }
                // "I" alone could as well be a misread 1; keep roman, flag as upper case.
                return PageNumber(value: v, kind: .roman, text: lower, noisy: false, upperRoman: upper)
            }
        }
        // Arabic, possibly a range: split at the first dash that has a digit-ish on both sides.
        var head: [Character] = []
        var tail: [Character] = []
        var inTail = false
        for (i, c) in chars.enumerated() {
            if rangeDashes.contains(c) {
                guard !inTail, i > 0, i < chars.count - 1 else { return nil }
                inTail = true
                continue
            }
            if inTail { tail.append(c) } else { head.append(c) }
        }
        func arabic(_ cs: [Character]) -> (String, Bool, Bool)? {
            guard !cs.isEmpty, cs.count <= 4 else { return nil }
            var out = ""
            var noisy = false
            var real = false
            for c in cs {
                if let d = digit(c) {
                    out.append(d)
                    real = true
                } else if let d = noiseDigits[c] {
                    out.append(d)
                    noisy = true
                } else {
                    return nil
                }
            }
            return (out, noisy, real)
        }
        guard let (h, hn, hr) = arabic(head) else { return nil }
        guard hr || allowNoiseOnly else { return nil }
        guard let v = Int(h), v >= 1 else { return nil }
        var text = String(v)
        var noisy = hn
        if inTail {
            guard let (t, tn, tr) = arabic(tail), tr || allowNoiseOnly, let tv = Int(t), tv >= v else { return nil }
            text += "-\(tv)"
            noisy = noisy || tn
        }
        return PageNumber(value: v, kind: .arabic, text: text, noisy: noisy)
    }

    /// Splits "第一章 绪论 …… 12" into title "第一章 绪论" and page 12. Returns nil when the
    /// text does not end in a page-number token that is separated from the title (by white
    /// space, dot leaders or, for arabic digits, a CJK character).
    public static func splitTrailing(_ text: String) -> TrailingSplit? {
        // A roman "i" after dot leaders that OCR read as "j" ("序 ……j").
        if text.hasSuffix("j") {
            let swapped = String(text.dropLast()) + "i"
            if var r = splitTrailing(swapped), r.leader, r.number.kind == .roman, r.number.text == "i" {
                let lo = swapped.utf16.distance(from: swapped.startIndex, to: r.tokenRange.lowerBound)
                let hi = swapped.utf16.distance(from: swapped.startIndex, to: r.tokenRange.upperBound)
                r.tokenRange = String.Index(utf16Offset: lo, in: text)..<String.Index(utf16Offset: hi, in: text)
                r.number.noisy = true
                return r
            }
        }
        let start0 = text.startIndex
        var end = text.endIndex
        var strays = 0
        while end > start0 {
            let c = text[text.index(before: end)]
            if c.isWhitespace {
                end = text.index(before: end)
            } else if strayTrailing.contains(c) && strays < 2 {
                strays += 1
                end = text.index(before: end)
            } else {
                break
            }
        }
        guard end > start0 else { return nil }
        // Token: token characters, plus range dashes that sit between two digits.
        var start = end
        while start > start0 {
            let before = text.index(before: start)
            let c = text[before]
            if isTokenChar(c) {
                start = before
                continue
            }
            if rangeDashes.contains(c), start < end, digit(text[start]) != nil, before > start0,
               digit(text[text.index(before: before)]) != nil {
                start = before
                continue
            }
            break
        }
        guard start < end else { return nil }
        // A dash at the token's start is a leader, not a range.
        while start < end, rangeDashes.contains(text[start]) { start = text.index(after: start) }
        guard start < end else { return nil }
        let token = String(text[start..<end])

        // What separates it from the title.
        var titleEnd = start
        var leaderCount = 0
        var ellipsis = false
        var separated = false
        while titleEnd > start0 {
            let c = text[text.index(before: titleEnd)]
            if c.isWhitespace || separatorChars.contains(c) {
                separated = true
            } else if isLeader(c) {
                leaderCount += 1
                if c == "…" || c == "⋯" || c == "‥" { ellipsis = true }
            } else {
                break
            }
            titleEnd = text.index(before: titleEnd)
        }
        var leader = leaderCount >= 2 || ellipsis
        let abutting = titleEnd == start && titleEnd > start0
        // "理论基础 …… 1 5": wide (full-width) digits that OCR split with a space. Merged only
        // when dot leaders precede the first group, so "Chapter 3 1" stays title + page.
        if !abutting, leaderCount == 0, text[titleEnd..<start] == " ", token.count <= 2,
           token.allSatisfy({ digit($0) != nil }) {
            var d = titleEnd
            while d > start0, digit(text[text.index(before: d)]) != nil, text.distance(from: d, to: titleEnd) < 2 {
                d = text.index(before: d)
            }
            var k = d
            var leaders2 = 0
            var ellipsis2 = false
            while k > start0 {
                let c = text[text.index(before: k)]
                if c.isWhitespace || separatorChars.contains(c) {
                } else if isLeader(c) {
                    leaders2 += 1
                    if c == "…" || c == "⋯" || c == "‥" { ellipsis2 = true }
                } else {
                    break
                }
                k = text.index(before: k)
            }
            if d < titleEnd, leaders2 >= 2 || ellipsis2,
               let merged = parse(String(text[d..<titleEnd]) + token), merged.kind == .arabic {
                let title = String(text[start0..<k]).trimmingCharacters(in: .whitespaces)
                leader = true
                return TrailingSplit(title: title, number: merged, tokenRange: d..<end, leader: leader, abutting: false)
            }
        }
        let before: Character? = titleEnd > start0 ? text[text.index(before: titleEnd)] : nil
        let standalone = titleEnd == start0

        // "2.3" / "1.1.2" at the end is a section number, not a page.
        if leaderCount == 1, !separated, let b = before, digit(b) != nil { return nil }
        if leaderCount == 1, !separated, let b = before, isASCIIAlnum(b) { return nil }
        if abutting, let b = before, isASCIIAlnum(b) || !b.isLetter { return nil }  // digits glued to CJK letters only

        guard var number = parse(token, allowNoiseOnly: leader || (standalone && token.count == 1 && token != "I"),
                                 allowUpperRoman: true) else { return nil }
        if number.kind == .roman {
            if abutting { return nil }
            if number.upperRoman && !(leader || standalone) { return nil }
            if !leader && !separated && !standalone { return nil }
        }
        // A lone "l" / "I" with nothing but leaders before it is a 1; anything else must look right.
        if number.kind == .arabic, number.noisy, !leader, !standalone,
           !token.contains(where: { digit($0) != nil }) { return nil }
        number.noisy = number.noisy || (number.kind == .arabic && token.contains(where: { noiseDigits[$0] != nil }))
        let title = String(text[start0..<titleEnd]).trimmingCharacters(in: .whitespaces)
        return TrailingSplit(title: title, number: number, tokenRange: start..<end, leader: leader, abutting: abutting)
    }

    /// Removes trailing dot leaders, separators and white space.
    public static func stripTrailingLeaders(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let c = s[s.index(before: end)]
            guard c.isWhitespace || isLeader(c) || separatorChars.contains(c) else { break }
            end = s.index(before: end)
        }
        return String(s[s.startIndex..<end])
    }

    static let decoration: Set<Character> = [
        "-", "—", "–", "―", "‒", "·", "•", "・", ".", "|", "[", "]", "(", ")", "{", "}", "（", "）", "〔", "〕",
        "<", ">", "《", "》", "【", "】", "〈", "〉", "~", "～", "*", "_", "－", "…", "⋯", "：", ":", "/",
    ]

    /// A page number standing alone, possibly decorated: "12", "- 12 -", "— 12 —", "·12·",
    /// "[12]", "第 12 页", "Page 12", "p. 12", "xii". Nil for anything else.
    public static func parseStandalone(_ raw: String, allowRoman: Bool = true) -> PageNumber? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Page", "PAGE", "page", "P.", "p.", "第"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if s.hasSuffix("页") || s.hasSuffix("頁") { s = String(s.dropLast()) }
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespaces)
        var chars = Array(trimmed)
        while let f = chars.first, f.isWhitespace || decoration.contains(f) { chars.removeFirst() }
        while let l = chars.last, l.isWhitespace || decoration.contains(l) { chars.removeLast() }
        let token = String(chars.filter { !$0.isWhitespace })
        // White space inside the digits is fine ("1 2" is a spaced 12); letters and digits
        // mixed with other text are not.
        guard !token.isEmpty, chars.filter({ !$0.isWhitespace }).count == token.count else { return nil }
        guard let n = parse(token, allowNoiseOnly: false, allowUpperRoman: true) else { return nil }
        if n.kind == .roman && !allowRoman { return nil }
        return n
    }

    static let chapterWords: Set<String> = [
        "chapter", "section", "part", "vol", "vol.", "volume", "lesson", "unit", "lecture", "§", "第", "figure",
        "fig.", "table", "appendix", "book", "no.", "article",
    ]
    static let chapterSuffixes: Set<Character> = ["章", "节", "節", "篇", "部", "讲", "講", "课", "課", "卷", "回", "编", "編", "期", "年", "月", "日", "条", "項", "项", "图", "表", "号"]

    /// Arabic page-number candidates in a running header or footer: the whole text when it is
    /// a (decorated) number, else a number at its start or end that is not part of
    /// "Chapter 3", "第3章", "3.2" and the like. `standalone` tells which kind was found.
    public static func folioCandidates(_ text: String) -> [(value: Int, standalone: Bool)] {
        if let n = parseStandalone(text, allowRoman: false) { return [(n.value, true)] }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2 else {
            // One word: digits glued to CJK text at either end ("12绪论", "绪论13").
            return gluedCandidates(text)
        }
        var out: [(Int, Bool)] = []
        if let n = parse(words[0]), n.kind == .arabic, !n.text.contains("-") {
            let next = words[1]
            if let f = next.first, !chapterSuffixes.contains(f), !chapterWords.contains(words[0].lowercased()) {
                out.append((n.value, false))
            }
        }
        if let n = parse(words[words.count - 1]), n.kind == .arabic, !n.text.contains("-") {
            let prev = words[words.count - 2].lowercased()
            if !chapterWords.contains(prev), !prev.hasSuffix("第") {
                out.append((n.value, false))
            }
        }
        if out.isEmpty { out = gluedCandidates(words[words.count - 1]) + gluedCandidates(words[0]) }
        return out
    }

    static func gluedCandidates(_ word: String) -> [(value: Int, standalone: Bool)] {
        let cs = Array(word)
        var out: [(Int, Bool)] = []
        // trailing digits after a CJK character
        var i = cs.count
        while i > 0, digit(cs[i - 1]) != nil { i -= 1 }
        if i > 0, i < cs.count, cs.count - i <= 4, !cs[i - 1].isASCII, cs[i - 1] != "第", !chapterSuffixes.contains(cs[i - 1]),
           let v = Int(String(cs[i...].map { digit($0)! })), v >= 1 {
            out.append((v, false))
        }
        // leading digits before a CJK character (not 3章 / 3节)
        var j = 0
        while j < cs.count, digit(cs[j]) != nil { j += 1 }
        if j > 0, j < cs.count, j <= 4, !cs[j].isASCII, !chapterSuffixes.contains(cs[j]),
           let v = Int(String(cs[..<j].map { digit($0)! })), v >= 1 {
            out.append((v, false))
        }
        return out
    }
}

extension PageToken {
    /// Reads a short token as a lower-case roman numeral, mapping the look-alikes OCR
    /// produces for thin serif strokes (1 l I | ! f j -> i). Only used to re-read a number
    /// that was already recognized as roman. Leaders and decoration around it are ignored.
    public static func romanLookalike(_ raw: String) -> PageNumber? {
        var chars = Array(raw.filter { !$0.isWhitespace })
        while let f = chars.first, decoration.contains(f) || isLeader(f) { chars.removeFirst() }
        while let l = chars.last, decoration.contains(l) || isLeader(l) { chars.removeLast() }
        guard !chars.isEmpty, chars.count <= 7 else { return nil }
        let map: [Character: Character] = ["1": "i", "l": "i", "I": "i", "|": "i", "!": "i", "f": "i", "j": "i", "í": "i", "ì": "i",
                                           "V": "v", "X": "x", "i": "i", "v": "v", "x": "x", "L": "l"]
        var s = ""
        for c in chars {
            guard let m = map[c] else { return nil }
            s.append(m)
        }
        guard let v = romanTable[s] else { return nil }
        return PageNumber(value: v, kind: .roman, text: s, noisy: s != String(chars).lowercased())
    }
}
