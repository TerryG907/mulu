import Foundation

/// Writes direct objects back to PDF syntax. Used for the new catalog revision (the
/// original catalog dictionary with /Outlines and /PageMode changed) and for the
/// new outline dictionaries. Strings are always written as hex strings, which is
/// lossless for any byte content.
enum Serializer {
    static func write(_ object: PDFObject, into out: inout [UInt8]) throws {
        switch object {
        case .null:
            out.append(ascii: "null")
        case .bool(let b):
            out.append(ascii: b ? "true" : "false")
        case .int(let v):
            out.append(ascii: String(v))
        case .real(_, let lexeme):
            out.append(ascii: lexeme)
        case .string(let s):
            writeHexString(s, into: &out)
        case .name(let n):
            writeName(n, into: &out)
        case .ref(let r):
            out.append(ascii: "\(r.num) \(r.gen) R")
        case .array(let items):
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                try write(item, into: &out)
            }
            out.append(0x5D)
        case .dict(let d):
            try writeDict(d, into: &out)
        case .stream:
            // Streams are always indirect objects and can't be nested in a dictionary.
            throw MuluError.malformed("cannot serialize a stream as a direct object")
        }
    }

    static func writeDict(_ d: PDFDict, into out: inout [UInt8]) throws {
        out.append(ascii: "<<")
        // De-duplicate keys (last occurrence wins, as when reading).
        var seen = Set<String>()
        var chosen: [(String, PDFObject)] = []
        for (k, v) in d.entries.reversed() where seen.insert(k).inserted { chosen.append((k, v)) }
        for (k, v) in chosen.reversed() {
            out.append(0x20)
            writeName(k, into: &out)
            out.append(0x20)
            try write(v, into: &out)
        }
        out.append(ascii: " >>")
    }

    static func writeHexString(_ s: [UInt8], into out: inout [UInt8]) {
        let digits = Array("0123456789ABCDEF".utf8)
        out.append(0x3C)
        for b in s {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        out.append(0x3E)
    }

    /// §7.3.5: bytes outside ! .. ~, delimiters and '#' are written as #xx.
    static func writeName(_ name: String, into out: inout [UInt8]) {
        let digits = Array("0123456789ABCDEF".utf8)
        out.append(0x2F)
        func escaped(_ b: UInt8) {
            out.append(0x23)
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        for scalar in name.unicodeScalars {
            guard scalar.value <= 0xFF else {
                for b in String(scalar).utf8 { escaped(b) }
                continue
            }
            let b = UInt8(scalar.value)
            if b >= 0x21, b <= 0x7E, b != 0x23, !isPDFDelimiter(b) {
                out.append(b)
            } else {
                escaped(b)
            }
        }
    }
}
