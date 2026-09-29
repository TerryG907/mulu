import Foundation

/// A deliberately small XML reader for the outline interchange formats (PDFPatcher info
/// files, OPML): elements, attributes, entities, comments, CDATA, processing
/// instructions and a DOCTYPE without an internal subset. No namespaces, no DTDs.
/// Foundation-only, so it behaves the same everywhere.
struct MiniXMLElement: Equatable {
    var name: String
    var attributes: [(String, String)]
    var children: [MiniXMLElement]
    var line: Int

    func attribute(_ names: String...) -> String? {
        for n in names {
            if let v = attributes.first(where: { $0.0 == n })?.1 { return v }
        }
        let lower = names.map { $0.lowercased() }
        return attributes.first(where: { lower.contains($0.0.lowercased()) })?.1
    }

    static func == (a: MiniXMLElement, b: MiniXMLElement) -> Bool {
        a.name == b.name && a.children == b.children && a.attributes.map(\.0) == b.attributes.map(\.0)
            && a.attributes.map(\.1) == b.attributes.map(\.1)
    }
}

enum MiniXML {
    struct ParseError: Error, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "XML line \(line): \(message)" }
    }

    /// Decodes XML bytes: BOM, then the encoding declared in `<?xml ... encoding="..."?>`
    /// (UTF-8, UTF-16, GB2312/GBK/GB18030, Big5, Shift_JIS, Latin-1, Windows-1252).
    static func decode(_ bytes: [UInt8]) -> String? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(bytes: bytes.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) }
        if bytes.starts(with: [0x3C, 0x00]) { return String(bytes: bytes, encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0x00, 0x3C]) { return String(bytes: bytes, encoding: .utf16BigEndian) }
        let head = String(decoding: bytes.prefix(200).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        var declared = ""
        if head.hasPrefix("<?xml"), let r = head.range(of: "encoding") {
            let after = head[r.upperBound...].drop(while: { $0 == " " || $0 == "=" })
            if let q = after.first, q == "\"" || q == "'" {
                declared = String(after.dropFirst().prefix(while: { $0 != q })).lowercased()
            }
        }
        if let enc = encoding(named: declared), let s = String(bytes: bytes, encoding: enc) { return s }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func encoding(named name: String) -> String.Encoding? {
        switch name {
        case "", "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "gb2312", "gbk", "gb18030", "cp936", "x-gbk", "euc-cn", "hz-gb-2312":
            #if canImport(Darwin)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            #else
            return nil
            #endif
        case "big5", "big-5", "cp950":
            #if canImport(Darwin)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            #else
            return nil
            #endif
        default: return nil
        }
    }

    static func parse(_ text: String) throws -> MiniXMLElement {
        let s = Array(text.unicodeScalars)
        var i = 0
        var line = 1
        func fail(_ m: String) -> ParseError { ParseError(line: line, message: m) }
        func peek(_ str: String) -> Bool {
            var k = i
            for u in str.unicodeScalars {
                guard k < s.count, s[k] == u else { return false }
                k += 1
            }
            return true
        }
        func advance(_ n: Int = 1) {
            for _ in 0..<n where i < s.count {
                if s[i] == "\n" { line += 1 }
                i += 1
            }
        }
        func skipUntil(_ end: String) throws {
            while i < s.count && !peek(end) { advance() }
            guard i < s.count else { throw fail("unterminated construct (expected '\(end)')") }
            advance(end.unicodeScalars.count)
        }
        func isSpace(_ u: Unicode.Scalar) -> Bool { u == " " || u == "\t" || u == "\n" || u == "\r" }
        func skipSpace() { while i < s.count && isSpace(s[i]) { advance() } }
        func isNameChar(_ u: Unicode.Scalar) -> Bool {
            !(isSpace(u) || u == "=" || u == ">" || u == "/" || u == "<" || u == "\"" || u == "'" || u == "?" || u == "!")
        }
        func readName() throws -> String {
            var n = String.UnicodeScalarView()
            while i < s.count && isNameChar(s[i]) { n.append(s[i]); advance() }
            guard !n.isEmpty else { throw fail("expected a name") }
            return String(n)
        }
        func unescape(_ raw: String.UnicodeScalarView) throws -> String {
            var out = String.UnicodeScalarView()
            var k = raw.startIndex
            while k < raw.endIndex {
                let u = raw[k]
                if u == "&" {
                    guard let semi = raw[k...].firstIndex(of: ";"), raw.distance(from: k, to: semi) <= 12 else {
                        throw fail("bad entity reference")
                    }
                    let name = String(String.UnicodeScalarView(raw[raw.index(after: k)..<semi]))
                    switch name {
                    case "lt": out.append("<")
                    case "gt": out.append(">")
                    case "amp": out.append("&")
                    case "quot": out.append("\"")
                    case "apos": out.append("'")
                    default:
                        var v: UInt32? = nil
                        if name.hasPrefix("#x") || name.hasPrefix("#X") { v = UInt32(name.dropFirst(2), radix: 16) }
                        else if name.hasPrefix("#") { v = UInt32(name.dropFirst()) }
                        guard let v, let sc = Unicode.Scalar(v) else { throw fail("unknown entity &\(name);") }
                        out.append(sc)
                    }
                    k = raw.index(after: semi)
                } else {
                    out.append(u)
                    k = raw.index(after: k)
                }
            }
            return String(out)
        }

        // Prolog
        var root: MiniXMLElement? = nil
        var stack: [MiniXMLElement] = []
        while i < s.count {
            if s[i] != "<" {
                // character data (ignored); only whitespace is allowed outside the root
                if stack.isEmpty && !isSpace(s[i]) && s[i] != "\u{FEFF}" { throw fail("text outside the root element") }
                advance()
                continue
            }
            if peek("<?") { try skipUntil("?>"); continue }
            if peek("<!--") { try skipUntil("-->"); continue }
            if peek("<![CDATA[") { try skipUntil("]]>"); continue }
            if peek("<!") {
                if peek("<!DOCTYPE"), let k = s[i...].firstIndex(where: { $0 == ">" || $0 == "[" }), s[k] == "[" {
                    throw fail("DOCTYPE with an internal subset is not supported")
                }
                try skipUntil(">")
                continue
            }
            if peek("</") {
                advance(2)
                let name = try readName()
                skipSpace()
                guard i < s.count, s[i] == ">" else { throw fail("expected '>'") }
                advance()
                guard let top = stack.popLast(), top.name == name else { throw fail("mismatched end tag </\(name)>") }
                if stack.isEmpty {
                    guard root == nil else { throw fail("more than one root element") }
                    root = top
                } else {
                    stack[stack.count - 1].children.append(top)
                }
                continue
            }
            advance()  // <
            let startLine = line
            let name = try readName()
            var attrs: [(String, String)] = []
            while true {
                skipSpace()
                guard i < s.count else { throw fail("unterminated start tag <\(name)>") }
                if s[i] == ">" { advance(); break }
                if peek("/>") { advance(2); break }
                let an = try readName()
                skipSpace()
                guard i < s.count, s[i] == "=" else { throw fail("attribute \(an) has no value") }
                advance()
                skipSpace()
                guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw fail("attribute \(an) value must be quoted") }
                let q = s[i]
                advance()
                var raw = String.UnicodeScalarView()
                while i < s.count && s[i] != q {
                    guard s[i] != "<" else { throw fail("'<' in attribute value") }
                    // attribute-value normalisation: literal whitespace → space
                    raw.append(s[i] == "\n" || s[i] == "\t" || s[i] == "\r" ? " " : s[i])
                    advance()
                }
                guard i < s.count else { throw fail("unterminated attribute value") }
                advance()
                guard !attrs.contains(where: { $0.0 == an }) else { throw fail("duplicate attribute \(an)") }
                attrs.append((an, try unescape(raw)))
            }
            let el = MiniXMLElement(name: name, attributes: attrs, children: [], line: startLine)
            let selfClosing = i >= 2 && s[i - 2] == "/" && s[i - 1] == ">"
            if selfClosing {
                if stack.isEmpty {
                    guard root == nil else { throw fail("more than one root element") }
                    root = el
                } else {
                    stack[stack.count - 1].children.append(el)
                }
            } else {
                guard stack.count < 512 else { throw fail("elements nested too deeply") }
                stack.append(el)
            }
        }
        guard stack.isEmpty else { throw fail("unclosed element <\(stack.last!.name)>") }
        guard let root else { throw fail("no root element") }
        return root
    }

    /// Escapes text for an attribute value (XML 1.0; invalid control characters dropped).
    static func escape(_ s: String) -> String {
        var r = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "\t": r += "&#9;"
            case "\n": r += "&#10;"
            case "\r": r += "&#13;"
            default:
                if u.value < 0x20 || (u.value >= 0xFFFE && u.value <= 0xFFFF) || (u.value >= 0xD800 && u.value <= 0xDFFF) { continue }
                r.unicodeScalars.append(u)
            }
        }
        return r
    }
}
