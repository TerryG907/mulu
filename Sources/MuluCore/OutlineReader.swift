import Foundation

/// One outline item as read back from a file.
public struct OutlineItemInfo: Sendable, Equatable {
    public var title: String
    public var level: Int       // 0-based depth
    public var pageIndex: Int?  // 0-based; nil when the destination cannot be resolved to a page

    public init(title: String, level: Int, pageIndex: Int?) {
        self.title = title
        self.level = level
        self.pageIndex = pageIndex
    }
}

extension PDFFile {
    /// Reads the document outline (§12.3.3) in display order (depth-first, pre-order).
    public func readOutline() throws -> [OutlineItemInfo] {
        guard let cat = try catalog() else { throw MuluError.noRoot }
        guard let outlinesObj = cat["Outlines"], case .dict(let root) = try resolve(outlinesObj) else { return [] }

        var pageIndexByRef: [ObjRef: Int] = [:]
        for (i, r) in try pageRefs().enumerated() {
            if pageIndexByRef[r] == nil { pageIndexByRef[r] = i }
        }
        let pageCount = try pageRefs().count

        var result: [OutlineItemInfo] = []
        var visited = Set<ObjRef>()
        // Explicit stack of (item-or-nil, level); pushing Next before First yields
        // pre-order traversal without recursion.
        var stack: [(PDFObject?, Int)] = [(root["First"], 0)]
        while let top = stack.popLast() {
            let (current, level) = top
            guard let current, case .ref(let r) = current, visited.insert(r).inserted else { continue }
            guard case .dict(let item) = try resolve(current) else { continue }
            let title: String
            if case .string(let bytes)? = try item["Title"].map({ try resolve($0) }) {
                title = PDFText.decode(bytes)
            } else {
                title = ""
            }
            let page = destinationPageIndex(of: item, catalog: cat, pages: pageIndexByRef, pageCount: pageCount)
            result.append(OutlineItemInfo(title: title, level: level, pageIndex: page))
            guard result.count <= 1_000_000 else { throw MuluError.malformed("outline too large") }
            stack.append((item["Next"], level))
            if let first = item["First"] { stack.append((first, level + 1)) }
        }
        return result
    }

    /// True if the catalog's outline has at least one item.
    public func hasOutlineItems() -> Bool {
        guard let cat = try? catalog(), let o = cat["Outlines"],
              case .dict(let root)? = try? resolve(o), let first = root["First"],
              case .dict? = try? resolve(first)
        else { return false }
        return true
    }

    /// /Dest, or the /D of a /GoTo action in /A (§12.3.2, §12.6.4.2).
    private func destinationPageIndex(of item: PDFDict, catalog: PDFDict, pages: [ObjRef: Int], pageCount: Int) -> Int? {
        var dest = item["Dest"]
        if dest == nil, let a = item["A"], case .dict(let action)? = try? resolve(a),
           action["S"]?.nameValue == "GoTo" {
            dest = action["D"]
        }
        guard let dest else { return nil }
        return pageIndex(ofDestination: dest, catalog: catalog, pages: pages, pageCount: pageCount, depth: 0)
    }

    private func pageIndex(ofDestination d: PDFObject, catalog: PDFDict, pages: [ObjRef: Int], pageCount: Int, depth: Int) -> Int? {
        guard depth < 8, let value = try? resolve(d) else { return nil }
        switch value {
        case .array(let a):
            guard let first = a.first else { return nil }
            if case .ref(let r) = first { return pages[r] }
            // An integer page number is only meaningful for remote destinations, but
            // readers accept it for local ones too.
            if let n = first.intValue, n >= 0, n < pageCount { return n }
            return nil
        case .dict(let dict):
            guard let inner = dict["D"] else { return nil }
            return pageIndex(ofDestination: inner, catalog: catalog, pages: pages, pageCount: pageCount, depth: depth + 1)
        case .name(let n):
            guard let target = namedDestination(Array(n.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }), catalog: catalog) else { return nil }
            return pageIndex(ofDestination: target, catalog: catalog, pages: pages, pageCount: pageCount, depth: depth + 1)
        case .string(let s):
            guard let target = namedDestination(s, catalog: catalog) else { return nil }
            return pageIndex(ofDestination: target, catalog: catalog, pages: pages, pageCount: pageCount, depth: depth + 1)
        default:
            return nil
        }
    }

    /// Named destinations: the /Dests name tree under /Names (PDF 1.2) or the /Dests
    /// dictionary in the catalog (PDF 1.1).
    private func namedDestination(_ key: [UInt8], catalog: PDFDict) -> PDFObject? {
        if let names = catalog["Names"], case .dict(let nd)? = try? resolve(names), let tree = nd["Dests"] {
            var visited = Set<ObjRef>()
            if let v = nameTreeLookup(tree, key: key, depth: 0, visited: &visited) { return v }
        }
        if let dests = catalog["Dests"], case .dict(let dd)? = try? resolve(dests) {
            return dd[latin1String(key)]
        }
        return nil
    }

    private func nameTreeLookup(_ node: PDFObject, key: [UInt8], depth: Int, visited: inout Set<ObjRef>) -> PDFObject? {
        guard depth < 64 else { return nil }
        if case .ref(let r) = node, !visited.insert(r).inserted { return nil }
        guard case .dict(let d)? = try? resolve(node) else { return nil }
        if let namesObj = d["Names"], case .array(let names)? = try? resolve(namesObj) {
            var i = 0
            while i + 1 < names.count {
                if case .string(let k)? = try? resolve(names[i]), k == key { return names[i + 1] }
                i += 2
            }
        }
        if let kidsObj = d["Kids"], case .array(let kids)? = try? resolve(kidsObj) {
            for kid in kids {
                if let v = nameTreeLookup(kid, key: key, depth: depth + 1, visited: &visited) { return v }
            }
        }
        return nil
    }
}

/// PDF text strings (§7.9.2.2): UTF-16BE with BOM, UTF-8 with BOM (PDF 2.0), or
/// PDFDocEncoding.
public enum PDFText {
    public static func decode(_ b: [UInt8]) -> String {
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return utf16(b.dropFirst(2), bigEndian: true) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return utf16(b.dropFirst(2), bigEndian: false) }  // non-standard but seen
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(decoding: b.dropFirst(3), as: UTF8.self) }
        var view = String.UnicodeScalarView()
        for x in b {
            let v = pdfDocEncoding(x)
            view.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
        return String(view)
    }

    /// UTF-16BE with BOM as a hex string: the encoding Mulu always writes for titles.
    public static func utf16BEHex(_ s: String) -> [UInt8] {
        var out: [UInt8] = Array("<FEFF".utf8)
        let digits = Array("0123456789ABCDEF".utf8)
        for u in s.utf16 {
            out.append(digits[Int(u >> 12)])
            out.append(digits[Int((u >> 8) & 0xF)])
            out.append(digits[Int((u >> 4) & 0xF)])
            out.append(digits[Int(u & 0xF)])
        }
        out.append(0x3E)
        return out
    }

    private static func utf16(_ b: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(b.count / 2)
        var i = b.startIndex
        while i + 1 < b.endIndex {
            let hi = UInt16(b[i]), lo = UInt16(b[i + 1])
            units.append(bigEndian ? (hi << 8 | lo) : (lo << 8 | hi))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// PDFDocEncoding (Annex D.2): Latin-1 except 0x18...0x1F and 0x80...0xA0.
    static func pdfDocEncoding(_ x: UInt8) -> UInt32 {
        switch x {
        case 0x18...0x1F: return UInt32(low[Int(x - 0x18)])
        case 0x80...0xA0: return UInt32(high[Int(x - 0x80)])
        default: return UInt32(x)
        }
    }

    private static let low: [UInt16] = [0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC]
    private static let high: [UInt16] = [
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044,
        0x2039, 0x203A, 0x2212, 0x2030, 0x201E, 0x201C, 0x201D, 0x2018,
        0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
        0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD,
        0x20AC,
    ]
}
