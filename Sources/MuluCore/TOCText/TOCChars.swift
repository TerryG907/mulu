import Foundation

/// Character-level helpers shared by the printed-TOC parser and the interop readers.
/// Foundation-only; every function is pure.
enum TOCChars {
    static func scalar(_ c: Character) -> UInt32? {
        c.unicodeScalars.count == 1 ? c.unicodeScalars.first!.value : nil
    }

    /// Full-width ASCII variants (U+FF01...U+FF5E) map to ASCII and U+3000 to a space;
    /// every other character is returned unchanged (so indexes stay aligned).
    static func halfWidth(_ c: Character) -> Character {
        guard let v = scalar(c) else { return c }
        if v >= 0xFF01 && v <= 0xFF5E { return Character(Unicode.Scalar(v - 0xFEE0)!) }
        if v == 0x3000 { return " " }
        return c
    }

    static func halfWidth<S: StringProtocol>(_ s: S) -> String { String(s.map(halfWidth)) }

    /// ASCII or full-width decimal digit.
    static func digit(_ c: Character) -> Int? {
        guard let v = scalar(c) else { return nil }
        switch v {
        case 0x30...0x39: return Int(v - 0x30)
        case 0xFF10...0xFF19: return Int(v - 0xFF10)
        default: return nil
        }
    }

    static func isDigit(_ c: Character) -> Bool { digit(c) != nil }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FFFF,
             0x3040...0x30FF, 0xAC00...0xD7AF, 0x3005, 0x3007:
            return true
        default:
            return false
        }
    }

    /// ASCII letter, or its full-width variant.
    static func isLatinLetter(_ c: Character) -> Bool {
        let h = halfWidth(c)
        return h.isASCII && h.isLetter
    }

    static func isSpace(_ c: Character) -> Bool { c.isWhitespace }

    /// Width in "columns": CJK and full-width forms count 2, everything else 1.
    static func displayWidth<S: StringProtocol>(_ s: S) -> Int {
        s.reduce(0) { acc, c in
            guard let v = c.unicodeScalars.first?.value else { return acc + 1 }
            let wide = isCJK(c) || (v >= 0xFF01 && v <= 0xFF60) || (v >= 0x3000 && v <= 0x303F)
            return acc + (wide ? 2 : 1)
        }
    }

    /// Dot leaders and rules printed between a title and its page number, as they come
    /// out of typesetting or OCR.
    static let leaders: Set<Character> = [
        ".", "…", "·", "‥", "⋯", "‧", "•", "・", "･", "．", "﹒", "-", "—", "─", "–", "―", "‒",
        "_", "＿", "~", "～", "⋅", "∙", "°", "﹍", "﹎", "=", "━", "┄", "┈", "╌", "∶", "︰", "。",
        "\u{00B7}", "\u{2027}", "\u{30FB}",
    ]

    static func isLeader(_ c: Character) -> Bool { leaders.contains(c) }

    // MARK: Chinese numerals

    static let cnDigits: [Character: Int] = [
        "零": 0, "〇": 0, "○": 0, "Ｏ": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "壹": 1, "贰": 2, "貳": 2, "叁": 3, "參": 3, "肆": 4,
        "伍": 5, "陆": 6, "陸": 6, "柒": 7, "捌": 8, "玖": 9,
    ]
    static let cnUnits: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000]

    static func isCNNumeral(_ c: Character) -> Bool {
        (cnDigits[c] != nil && c != "Ｏ") || cnUnits[c] != nil
    }

    /// 一 → 1, 十二 → 12, 二十 → 20, 一百零五 → 105, 一〇五 → 105. nil if not a numeral.
    static func chineseNumber<S: Sequence>(_ s: S) -> Int? where S.Element == Character {
        let cs = Array(s)
        guard !cs.isEmpty, cs.count <= 8 else { return nil }
        if !cs.contains(where: { cnUnits[$0] != nil }) {
            var v = 0
            for c in cs {
                guard let d = cnDigits[c] else { return nil }
                v = v * 10 + d
            }
            return v
        }
        var total = 0, current = 0, lastUnit = Int.max
        for c in cs {
            if let d = cnDigits[c] {
                current = d
            } else if let u = cnUnits[c] {
                guard u < lastUnit else { return nil }
                total += (current == 0 ? 1 : current) * u
                current = 0
                lastUnit = u
            } else {
                return nil
            }
        }
        return total + current
    }

    // MARK: Roman numerals

    private static let romanChars: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        let upper = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "L", "C", "D", "M"]
        for (i, s) in upper.enumerated() {
            m[0x2160 + UInt32(i)] = s
            m[0x2170 + UInt32(i)] = s.lowercased()
        }
        return m
    }()

    static func isRomanChar(_ c: Character) -> Bool {
        guard let v = scalar(c) else { return false }
        if romanChars[v] != nil { return true }
        return "ivxlcdmIVXLCDM".contains(c)
    }

    /// Canonical Roman numeral (all upper- or all lower-case, or the Unicode Roman
    /// numeral characters) → value; nil otherwise ("IIII", "VX", "Iv" are rejected).
    static func romanValue<S: Sequence>(_ s: S) -> Int? where S.Element == Character {
        var str = ""
        for c in s {
            if let v = scalar(c), let mapped = romanChars[v] { str += mapped } else { str.append(c) }
        }
        guard !str.isEmpty, str.count <= 15 else { return nil }
        guard str == str.uppercased() || str == str.lowercased() else { return nil }
        let up = str.uppercased()
        let vals: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0
        let cs = Array(up)
        for i in cs.indices {
            guard let v = vals[cs[i]] else { return nil }
            if i + 1 < cs.count, let n = vals[cs[i + 1]], n > v { total -= v } else { total += v }
        }
        guard total > 0, romanString(total) == up else { return nil }
        return total
    }

    static func romanString(_ n: Int) -> String {
        guard n > 0 && n < 4000 else { return "" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, r = ""
        for (v, s) in table { while n >= v { r += s; n -= v } }
        return r
    }

    // MARK: English number words

    private static let wordValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
    ]

    /// "One" → 1, "twenty-one" → 21.
    static func englishNumber(_ s: String) -> Int? {
        let w = s.lowercased()
        if let v = wordValues[w] { return v }
        let parts = w.split(separator: "-")
        if parts.count == 2, let t = wordValues[String(parts[0])], t >= 20, t % 10 == 0,
           let u = wordValues[String(parts[1])], u < 10 {
            return t + u
        }
        return nil
    }

    /// Arabic (ASCII/full-width), Roman or English-word number.
    static func anyNumber(_ s: String) -> Int? {
        if !s.isEmpty, s.allSatisfy(isDigit), s.count <= 6 {
            return Int(String(s.map { Character(String(digit($0)!)) }))
        }
        if let r = romanValue(s) { return r }
        if let c = chineseNumber(s) { return c }
        return englishNumber(s)
    }
}
