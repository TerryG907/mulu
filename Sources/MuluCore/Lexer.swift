import Foundation

// Character classes, ISO 32000-1 §7.2.2.
@inline(__always) func isPDFWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00
}

@inline(__always) func isPDFDelimiter(_ c: UInt8) -> Bool {
    switch c {
    case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true  // ( ) < > [ ] { } / %
    default: return false
    }
}

@inline(__always) func isPDFRegular(_ c: UInt8) -> Bool { !isPDFWhitespace(c) && !isPDFDelimiter(c) }

@inline(__always) func isASCIIDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

@inline(__always) func hexNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

/// Bytes -> String with one unicode scalar per byte (lossless; used for names and keywords).
func latin1String<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    var view = String.UnicodeScalarView()
    for b in bytes { view.append(Unicode.Scalar(b)) }
    return String(view)
}

enum Token: Equatable {
    case integer(Int)
    case real(Double, String)
    case string([UInt8])
    case name(String)
    case arrayStart, arrayEnd, dictStart, dictEnd
    case keyword(String)
    case eof
}

/// A tolerant PDF tokenizer over a byte buffer (the file, or a decoded object stream).
struct Lexer {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    mutating func skipWhitespaceAndComments() {
        let n = bytes.count
        while pos < n {
            let c = bytes[pos]
            if isPDFWhitespace(c) {
                pos += 1
            } else if c == 0x25 {  // '%' comment runs to end of line
                while pos < n, bytes[pos] != 0x0A, bytes[pos] != 0x0D { pos += 1 }
            } else {
                return
            }
        }
    }

    mutating func next() -> Token {
        skipWhitespaceAndComments()
        guard pos < bytes.count else { return .eof }
        let c = bytes[pos]
        switch c {
        case 0x5B: pos += 1; return .arrayStart
        case 0x5D: pos += 1; return .arrayEnd
        case 0x3C:
            if pos + 1 < bytes.count, bytes[pos + 1] == 0x3C { pos += 2; return .dictStart }
            return .string(readHexString())
        case 0x3E:
            if pos + 1 < bytes.count, bytes[pos + 1] == 0x3E { pos += 2; return .dictEnd }
            pos += 1
            return .keyword(">")
        case 0x28: return .string(readLiteralString())
        case 0x29: pos += 1; return .keyword(")")
        case 0x2F: return .name(readName())
        case 0x7B: pos += 1; return .keyword("{")
        case 0x7D: pos += 1; return .keyword("}")
        case 0x2B, 0x2D, 0x2E, 0x30...0x39: return readNumber()
        default: return .keyword(readKeyword())
        }
    }

    private mutating func readKeyword() -> String {
        let start = pos
        while pos < bytes.count, isPDFRegular(bytes[pos]) { pos += 1 }
        if pos == start { pos += 1 }  // defensive: always make progress
        return latin1String(bytes[start..<pos])
    }

    /// Numbers (§7.3.3). Tolerates what real files contain: doubled signs ("--5"),
    /// a lone sign or dot (read as 0), and trailing junk like "1.2.3".
    private mutating func readNumber() -> Token {
        let n = bytes.count
        var negative = false
        while pos < n, bytes[pos] == 0x2B || bytes[pos] == 0x2D {
            if bytes[pos] == 0x2D { negative = true }
            pos += 1
        }
        let intStart = pos
        while pos < n, isASCIIDigit(bytes[pos]) { pos += 1 }
        let intEnd = pos
        var sawDot = false
        var fracStart = pos
        var fracEnd = pos
        if pos < n, bytes[pos] == 0x2E {
            sawDot = true
            pos += 1
            fracStart = pos
            while pos < n, isASCIIDigit(bytes[pos]) { pos += 1 }
            fracEnd = pos
        }
        while pos < n, bytes[pos] == 0x2E || bytes[pos] == 0x2D || bytes[pos] == 0x2B || isASCIIDigit(bytes[pos]) {
            pos += 1
        }
        let intLen = intEnd - intStart
        let fracLen = fracEnd - fracStart
        if intLen == 0 && fracLen == 0 { return .integer(0) }
        if !sawDot && intLen <= 18 {
            var v = 0
            for i in intStart..<intEnd { v = v * 10 + Int(bytes[i] - 0x30) }
            return .integer(negative ? -v : v)
        }
        let intText = intLen == 0 ? "0" : String(decoding: bytes[intStart..<intEnd], as: UTF8.self)
        let fracText = fracLen == 0 ? "0" : String(decoding: bytes[fracStart..<fracEnd], as: UTF8.self)
        let lexeme = (negative ? "-" : "") + intText + "." + fracText
        return .real(Double(lexeme) ?? 0, lexeme)
    }

    /// Literal string (§7.3.4.2): balanced parentheses, backslash escapes, and
    /// end-of-line normalisation (an unescaped CR or CRLF reads as LF).
    private mutating func readLiteralString() -> [UInt8] {
        let n = bytes.count
        pos += 1
        var out: [UInt8] = []
        var depth = 1
        while pos < n {
            let c = bytes[pos]
            pos += 1
            switch c {
            case 0x28:
                depth += 1
                out.append(c)
            case 0x29:
                depth -= 1
                if depth == 0 { return out }
                out.append(c)
            case 0x5C:
                guard pos < n else { return out }
                let e = bytes[pos]
                pos += 1
                switch e {
                case 0x6E: out.append(0x0A)  // \n
                case 0x72: out.append(0x0D)  // \r
                case 0x74: out.append(0x09)  // \t
                case 0x62: out.append(0x08)  // \b
                case 0x66: out.append(0x0C)  // \f
                case 0x30...0x37:  // \ddd, one to three octal digits, high-order overflow ignored
                    var v = Int(e - 0x30)
                    var k = 0
                    while k < 2, pos < n, bytes[pos] >= 0x30, bytes[pos] <= 0x37 {
                        v = v * 8 + Int(bytes[pos] - 0x30)
                        pos += 1
                        k += 1
                    }
                    out.append(UInt8(v & 0xFF))
                case 0x0D:  // backslash-EOL is a line continuation
                    if pos < n, bytes[pos] == 0x0A { pos += 1 }
                case 0x0A:
                    break
                default:  // \( \) \\ and unknown escapes: the backslash is dropped
                    out.append(e)
                }
            case 0x0D:
                out.append(0x0A)
                if pos < n, bytes[pos] == 0x0A { pos += 1 }
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Hex string (§7.3.4.3): whitespace ignored, odd digit count padded with 0.
    private mutating func readHexString() -> [UInt8] {
        let n = bytes.count
        pos += 1
        var out: [UInt8] = []
        var high: UInt8? = nil
        while pos < n {
            let c = bytes[pos]
            pos += 1
            if c == 0x3E { break }
            guard let v = hexNibble(c) else { continue }
            if let h = high {
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        if let h = high { out.append(h << 4) }
        return out
    }

    /// Name (§7.3.5) with #xx escapes decoded.
    private mutating func readName() -> String {
        let n = bytes.count
        pos += 1
        var raw: [UInt8] = []
        while pos < n, isPDFRegular(bytes[pos]) {
            let c = bytes[pos]
            if c == 0x23, pos + 2 < n, let h = hexNibble(bytes[pos + 1]), let l = hexNibble(bytes[pos + 2]) {
                raw.append(h << 4 | l)
                pos += 3
            } else {
                raw.append(c)
                pos += 1
            }
        }
        return latin1String(raw)
    }
}

extension Array where Element == UInt8 {
    /// True if `pattern` occurs at `offset`.
    func matches(_ pattern: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + pattern.count <= count else { return false }
        for i in 0..<pattern.count where self[offset + i] != pattern[i] { return false }
        return true
    }

    /// First occurrence of `pattern` at or after `from`.
    func firstIndex(of pattern: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, from >= 0, count >= pattern.count else { return nil }
        let first = pattern[0]
        let last = count - pattern.count
        return withUnsafeBufferPointer { buf -> Int? in
            var i = from
            while i <= last {
                if buf[i] == first {
                    var ok = true
                    for k in 1..<pattern.count where buf[i + k] != pattern[k] {
                        ok = false
                        break
                    }
                    if ok { return i }
                }
                i += 1
            }
            return nil
        }
    }

    /// Last occurrence of `pattern` that starts at or before `before`.
    func lastIndex(of pattern: [UInt8], before: Int? = nil) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let first = pattern[0]
        var i = Swift.min(before ?? (count - pattern.count), count - pattern.count)
        return withUnsafeBufferPointer { buf -> Int? in
            while i >= 0 {
                if buf[i] == first {
                    var ok = true
                    for k in 1..<pattern.count where buf[i + k] != pattern[k] {
                        ok = false
                        break
                    }
                    if ok { return i }
                }
                i -= 1
            }
            return nil
        }
    }

    mutating func append(ascii s: String) { append(contentsOf: s.utf8) }
}
