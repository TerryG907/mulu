import Foundation

/// An indirect reference `num gen R` (ISO 32000-1 §7.3.10).
public struct ObjRef: Hashable, Sendable, CustomStringConvertible {
    public var num: Int
    public var gen: Int
    public init(_ num: Int, _ gen: Int) {
        self.num = num
        self.gen = gen
    }
    public var description: String { "\(num) \(gen) R" }
}

/// A stream object. The (still encoded) data is not copied: `dataRange` points into
/// the file bytes of the `PDFFile` that parsed it. Streams can never live inside an
/// object stream (§7.5.7), so they always come from the file itself.
public struct PDFStream: Sendable, Equatable {
    public var dict: PDFDict
    public var dataRange: Range<Int>
}

/// A PDF object (§7.3). Names are stored as Strings whose unicode scalars are the raw
/// name bytes (U+0000...U+00FF, i.e. Latin-1), which makes the mapping lossless both
/// ways. Strings are stored as raw bytes. Reals keep a canonical lexeme so that
/// re-serializing never goes through floating-point formatting.
public enum PDFObject: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double, String)
    case string([UInt8])
    case name(String)
    case array([PDFObject])
    case dict(PDFDict)
    case stream(PDFStream)
    case ref(ObjRef)

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .real(let d, _):
            // Some writers emit integral values as reals ("/Length 123.0").
            if d.rounded() == d, abs(d) < 9.0e15 { return Int(d) }
            return nil
        default: return nil
        }
    }
    public var nameValue: String? {
        if case .name(let n) = self { return n }
        return nil
    }
    public var refValue: ObjRef? {
        if case .ref(let r) = self { return r }
        return nil
    }
    public var arrayValue: [PDFObject]? {
        if case .array(let a) = self { return a }
        return nil
    }
    /// The dictionary of a dict object, or of a stream object.
    public var dictValue: PDFDict? {
        switch self {
        case .dict(let d): return d
        case .stream(let s): return s.dict
        default: return nil
        }
    }
    public var stringBytes: [UInt8]? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// An insertion-ordered dictionary. Order is preserved so that a re-serialized
/// catalog looks like the original. Lookups return the LAST occurrence of a key,
/// which is what pdf.js, PDFium and qpdf do with (invalid) duplicate keys.
public struct PDFDict: Sendable, Equatable {
    public private(set) var entries: [(key: String, value: PDFObject)] = []

    public init() {}
    public init(_ pairs: [(String, PDFObject)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var keys: [String] { entries.map(\.key) }
    public var count: Int { entries.count }

    public subscript(key: String) -> PDFObject? {
        get {
            for i in stride(from: entries.count - 1, through: 0, by: -1) where entries[i].key == key {
                return entries[i].value
            }
            return nil
        }
        set {
            guard let newValue else {
                entries.removeAll { $0.key == key }
                return
            }
            if let first = entries.firstIndex(where: { $0.key == key }) {
                // Replace in place (keeps the original key order) and drop duplicates.
                entries[first].value = newValue
                var i = entries.count - 1
                while i > first {
                    if entries[i].key == key { entries.remove(at: i) }
                    i -= 1
                }
            } else {
                entries.append((key, newValue))
            }
        }
    }

    /// Appends without de-duplication (used by the parser; lookups still see the last one).
    mutating func appendRaw(_ key: String, _ value: PDFObject) {
        entries.append((key, value))
    }

    public static func == (lhs: PDFDict, rhs: PDFDict) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (a, b) in zip(lhs.entries, rhs.entries) where a.key != b.key || a.value != b.value {
            return false
        }
        return true
    }
}
