import Foundation

/// One outline item to write: a title, a 0-based level, and a 0-based page index.
public struct OutlineSpec: Sendable, Equatable {
    public var title: String
    public var level: Int
    public var pageIndex: Int

    public init(title: String, level: Int, pageIndex: Int) {
        self.title = title
        self.level = level
        self.pageIndex = pageIndex
    }
}

/// Builds an incremental update (ISO 32000-1 §7.5.6): bytes that are APPENDED to the
/// original file, never replacing any of its bytes. The update contains
///   - a new /Outlines dictionary and one dictionary per outline item,
///   - a new revision of the catalog (same object number and generation),
///   - a cross-reference section for just those objects, whose /Prev points at the
///     original's newest section, and a trailer / startxref / %%EOF.
public enum IncrementalWriter {
    public static func makeUpdate(for doc: PDFFile, outline: [OutlineSpec]) throws -> [UInt8] {
        if doc.isEncrypted { throw MuluError.encrypted }
        guard let rootRef = doc.trailer["Root"]?.refValue else { throw MuluError.noRoot }
        guard case .dict(var catalog) = try doc.resolve(rootRef) else { throw MuluError.noRoot }
        if doc.truncatedObjects.contains(rootRef) {
            throw MuluError.unsupported("the catalog nests arrays or dictionaries more than \(Parser.maxDepth) levels deep; it cannot be rewritten without losing data")
        }
        if doc.trailerIsTruncated {
            throw MuluError.unsupported("the trailer nests arrays or dictionaries more than \(Parser.maxDepth) levels deep; it cannot be copied without losing data")
        }
        let pages = try doc.pageRefs()
        guard !pages.isEmpty else { throw MuluError.zeroPages }
        try validate(outline, pages: pages)
        // New objects go above the declared /Size, above every object the xref
        // defines, and above every number some object refers to: a reference to an
        // undefined object means null (§7.3.10) and must keep meaning null. (This scan
        // also resolves every object, which records any xref repairs made on the way.)
        let firstNew = max(doc.nextObjectNumber, doc.highestReferencedObjectNumber() + 1)
        guard firstNew + outline.count + 3 <= PDFFile.maxObjectNumber else {
            throw MuluError.unsupported("object number \(firstNew + outline.count + 2) would exceed the limit of \(PDFFile.maxObjectNumber) (/Size \(doc.nextObjectNumber))")
        }

        let hasCompressed = doc.entries.values.contains { if case .compressed = $0 { return true } else { return false } }
        let useXRefStream = doc.xrefKind == .stream || (doc.isReconstructed && hasCompressed)

        // Offsets are written in the file's own frame: normally absolute, or relative
        // to the header when the original's offsets are (see PDFFile.offsetBase).
        let frame = doc.offsetBase
        let steerAbsoluteReadersToRebuild = frame > 0 && useXRefStream
            && !absoluteReadersLandOnWhitespace(doc) && !isCompressed(rootRef, in: doc)
        let base = doc.bytes.count - frame
        var out: [UInt8] = []
        // The first new object must start on a fresh line.
        if let last = doc.bytes.last, last != 0x0A, last != 0x0D { out.append(0x0A) }

        // In a header-relative file, readers that use absolute offsets (pypdf) land
        // `frame` bytes before each new object or xref keyword. Make sure those bytes
        // are whitespace, so they still find it by skipping whitespace.
        func padForAbsoluteReaders() {
            guard frame > 0 else { return }
            var have = 0
            var i = out.count - 1
            while have < frame, i >= 0, isPDFWhitespace(out[i]) {
                have += 1
                i -= 1
            }
            if i < 0 {
                var j = doc.bytes.count - 1
                while have < frame, j >= 0, isPDFWhitespace(doc.bytes[j]) {
                    have += 1
                    j -= 1
                }
            }
            if have < frame { out.append(contentsOf: repeatElement(0x20, count: frame - have)) }
        }

        var written: [(num: Int, gen: Int, offset: Int)] = []  // offsets in the file's frame
        var next = firstNew

        func beginObject(_ num: Int, _ gen: Int) {
            padForAbsoluteReaders()
            written.append((num, gen, base + out.count))
            out.append(ascii: "\(num) \(gen) obj\n")
        }
        func endObject() { out.append(ascii: "\nendobj\n") }

        if !outline.isEmpty {
            let n = outline.count
            let rootNum = next
            func itemNum(_ i: Int) -> Int { rootNum + 1 + i }
            next += n + 1

            // Rebuild the tree from the flat (level-annotated) list.
            var parent = [Int?](repeating: nil, count: n)
            var children = [[Int]](repeating: [], count: n)
            var topLevel: [Int] = []
            var open: [Int] = []  // open[k] = most recent item at level k
            for i in 0..<n {
                let level = outline[i].level
                open.removeSubrange(level..<open.count)
                if level == 0 {
                    topLevel.append(i)
                } else {
                    let p = open[level - 1]
                    parent[i] = p
                    children[p].append(i)
                }
                open.append(i)
            }
            // All items are open, so an item's /Count is its number of descendants.
            var descendants = [Int](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                descendants[i] = children[i].reduce(0) { $0 + 1 + descendants[$1] }
            }
            var prevSibling = [Int?](repeating: nil, count: n)
            var nextSibling = [Int?](repeating: nil, count: n)
            for siblings in [topLevel] + children {
                for (a, b) in zip(siblings, siblings.dropFirst()) {
                    nextSibling[a] = b
                    prevSibling[b] = a
                }
            }

            beginObject(rootNum, 0)
            out.append(ascii: "<< /Type /Outlines /First \(itemNum(topLevel.first!)) 0 R /Last \(itemNum(topLevel.last!)) 0 R /Count \(n) >>")
            endObject()

            for i in 0..<n {
                beginObject(itemNum(i), 0)
                out.append(ascii: "<< /Title ")
                out.append(contentsOf: PDFText.utf16BEHex(outline[i].title))
                out.append(ascii: " /Parent \(parent[i].map(itemNum) ?? rootNum) 0 R")
                if let p = prevSibling[i] { out.append(ascii: " /Prev \(itemNum(p)) 0 R") }
                if let s = nextSibling[i] { out.append(ascii: " /Next \(itemNum(s)) 0 R") }
                if let first = children[i].first, let last = children[i].last {
                    out.append(ascii: " /First \(itemNum(first)) 0 R /Last \(itemNum(last)) 0 R /Count \(descendants[i])")
                }
                let page = pages[outline[i].pageIndex]  // validated above
                out.append(ascii: " /Dest [\(page.num) \(page.gen) R /XYZ null null null] >>")
                endObject()
            }

            catalog["Outlines"] = .ref(ObjRef(rootNum, 0))
            catalog["PageMode"] = .name("UseOutlines")
        } else {
            // An empty TOC removes the outline.
            catalog["Outlines"] = nil
            if catalog["PageMode"]?.nameValue == "UseOutlines" { catalog["PageMode"] = nil }
        }

        // New revision of the catalog: same object number and generation. If the
        // original lived in an object stream it is simply superseded by this plain
        // object, because the newest xref entry wins.
        beginObject(rootRef.num, rootRef.gen)
        try Serializer.writeDict(catalog, into: &out)
        endObject()

        // Rows of the new cross-reference section, offsets in the file's frame.
        var rows: [Int: XRefEntry] = [:]
        func framed(_ e: XRefEntry) -> XRefEntry {
            if case .inUse(let off, let gen) = e { return .inUse(offset: off - frame, gen: gen) }
            return e
        }
        if doc.isReconstructed || doc.needsFullRepublish {
            // Reconstructed: the original chain is unusable, so this section must be
            // complete and must not have /Prev. Renumbered table: readers disagree
            // about the old entries, so every live entry is republished (a classic
            // table cannot hold compressed entries; those stay reachable via /Prev).
            for (num, e) in doc.entries where num > 0 {
                switch e {
                case .free: continue
                case .compressed where !useXRefStream: continue
                default: rows[num] = framed(e)
                }
            }
        }
        // Objects Mulu found only by scanning (their xref offset is wrong): publish the
        // corrected offsets so that every reader resolves them as Mulu did.
        for (num, e) in doc.repairedEntries { rows[num] = framed(e) }
        for w in written { rows[w.num] = .inUse(offset: w.offset, gen: w.gen) }
        let size = max(doc.nextObjectNumber, (written.map(\.num).max() ?? 0) + 1)

        var trailerDict = PDFDict()
        if useXRefStream {
            let xrefNum = next
            next += 1
            if steerAbsoluteReadersToRebuild {
                // pypdf checks that the byte before its (absolute) startxref is
                // whitespace, then follows the chain. Here that chain would send it to
                // original objects it cannot find (see absoluteReadersLandOnWhitespace),
                // so a comment in front makes the check fail and pypdf rebuilds the map
                // by scanning, where the newest (appended) definitions win. Readers using
                // header-relative offsets land exactly on the object and never see this.
                out.append(0x25)  // "%"
                out.append(contentsOf: repeatElement(0x20, count: max(0, frame - 1)))
                out.append(0x0A)
            } else {
                padForAbsoluteReaders()
            }
            let xrefOffset = base + out.count
            rows[xrefNum] = .inUse(offset: xrefOffset, gen: 0)
            let size = max(size, xrefNum + 1)
            let table = doc.isReconstructed ? completeTable(rows, size: size) : rows.mapValues { XRefRow($0) }
            let (data, w2, w3) = encodeRows(table)
            trailerDict["Type"] = .name("XRef")
            trailerDict["Size"] = .int(size)
            trailerDict["Index"] = .array(runs(table.keys.sorted()).flatMap { [PDFObject.int($0.start), .int($0.count)] })
            trailerDict["W"] = .array([.int(1), .int(w2), .int(w3)])
            copyTrailerKeys(from: doc, into: &trailerDict, rootRef: rootRef)
            trailerDict["Length"] = .int(data.count)
            out.append(ascii: "\(xrefNum) 0 obj\n")
            try Serializer.writeDict(trailerDict, into: &out)
            out.append(ascii: "\nstream\r\n")
            out.append(contentsOf: data)
            out.append(ascii: "\nendstream\nendobj\n")
            out.append(ascii: "startxref\n\(xrefOffset)\n%%EOF\n")
        } else {
            var table = doc.isReconstructed ? completeTable(rows, size: size) : rows.mapValues { XRefRow($0) }
            // Start the table with object 0 (the free-list head, repeated unchanged), as
            // Acrobat does. pypdf treats a newest classic table whose first subsection is
            // not "0 n" as mis-numbered, re-verifies every entry of every revision, and
            // rebuilds the whole map from a scan if any original entry looks odd.
            if table[0] == nil { table[0] = XRefRow(type: 0, f2: doc.freeListHead, f3: 65535) }
            padForAbsoluteReaders()
            let xrefOffset = base + out.count
            out.append(ascii: "xref\n")
            let nums = table.keys.sorted()
            var k = 0
            for run in runs(nums) {
                out.append(ascii: "\(run.start) \(run.count)\n")
                for _ in 0..<run.count {
                    // Each entry is exactly 20 bytes: 10-digit field, space, 5-digit
                    // field, space, type, and a two-byte EOL (§7.5.4).
                    let row = table[nums[k]]!
                    out.append(ascii: pad(row.f2, 10) + " " + pad(row.f3, 5) + (row.type == 0 ? " f\r\n" : " n\r\n"))
                    k += 1
                }
            }
            trailerDict["Size"] = .int(size)
            copyTrailerKeys(from: doc, into: &trailerDict, rootRef: rootRef)
            out.append(ascii: "trailer\n")
            try Serializer.writeDict(trailerDict, into: &out)
            out.append(ascii: "\nstartxref\n\(xrefOffset)\n%%EOF\n")
        }
        return out
    }

    static func validate(_ outline: [OutlineSpec], pages: [ObjRef]) throws {
        var previous = -1
        for (i, item) in outline.enumerated() {
            guard item.level >= 0, item.level <= previous + 1 else {
                throw MuluError.tocSyntax(line: i + 1, message: "invalid outline level \(item.level) after \(previous)")
            }
            guard item.pageIndex >= 0, item.pageIndex < pages.count else {
                throw MuluError.pageOutOfRange(line: i + 1, page: item.pageIndex + 1, physical: item.pageIndex + 1, pageCount: pages.count)
            }
            previous = item.level
        }
    }

    /// True if a reader that takes this header-relative file's offsets as absolute
    /// (pypdf) still reaches every original object: the `offsetBase` bytes in front
    /// of each one are whitespace, which it skips.
    static func absoluteReadersLandOnWhitespace(_ doc: PDFFile) -> Bool {
        let h = doc.offsetBase
        for e in doc.entries.values {
            guard case .inUse(let off, _) = e else { continue }
            guard off - h >= 0, off <= doc.bytes.count else { return false }
            for i in (off - h)..<off where !isPDFWhitespace(doc.bytes[i]) { return false }
        }
        return true
    }

    static func isCompressed(_ ref: ObjRef, in doc: PDFFile) -> Bool {
        if case .compressed? = doc.entries[ref.num] { return true }
        return false
    }

    /// Keys of an xref stream dictionary that describe the stream itself, plus the
    /// cross-reference keys every update writes for itself.
    static let sectionKeys: Set<String> = [
        "Type", "Size", "Index", "W", "Prev", "XRefStm", "Length", "Filter", "DecodeParms",
        "DP", "F", "FFilter", "FDecodeParms", "DL", "Root",
    ]

    /// /Prev (unless the section must be complete) and /Root, then every other entry of
    /// the previous trailer (§7.5.6: "the added trailer shall contain all the entries
    /// except the Prev entry ... from the previous trailer"), such as /Info, /ID and
    /// private keys; for an xref stream, minus the keys that describe that stream.
    private static func copyTrailerKeys(from doc: PDFFile, into d: inout PDFDict, rootRef: ObjRef) {
        if !doc.isReconstructed { d["Prev"] = .int(doc.startXRef) }
        d["Root"] = .ref(rootRef)
        for key in doc.trailer.keys where !sectionKeys.contains(key) && d[key] == nil {  // lookups: last duplicate wins
            guard let v = doc.trailer[key], !v.isNull else { continue }
            d[key] = v
        }
    }

    /// Row fields as they appear in an xref stream (type, field 2, field 3).
    struct XRefRow {
        var type: Int
        var f2: Int
        var f3: Int
        init(type: Int, f2: Int, f3: Int) {
            self.type = type
            self.f2 = f2
            self.f3 = f3
        }
        init(_ e: XRefEntry) {
            switch e {
            case .free: self.init(type: 0, f2: 0, f3: 0)
            case .inUse(let offset, let gen): self.init(type: 1, f2: offset, f3: gen)
            case .compressed(let stream, let index): self.init(type: 2, f2: stream, f3: index)
            }
        }
    }

    /// A complete table 0..<size: missing numbers become free entries linked into the
    /// free list that starts at object 0 (generation 65535).
    private static func completeTable(_ rows: [Int: XRefEntry], size: Int) -> [Int: XRefRow] {
        var table: [Int: XRefRow] = [:]
        var freeNums: [Int] = []
        for num in 0..<size {
            if num != 0, let e = rows[num] { table[num] = XRefRow(e) } else { freeNums.append(num) }
        }
        for (i, num) in freeNums.enumerated() {
            let nextFree = i + 1 < freeNums.count ? freeNums[i + 1] : 0
            table[num] = XRefRow(type: 0, f2: nextFree, f3: num == 0 ? 65535 : 0)
        }
        return table
    }

    /// Big-endian rows for an uncompressed xref stream with /W [1 w2 w3].
    private static func encodeRows(_ table: [Int: XRefRow]) -> (data: [UInt8], w2: Int, w3: Int) {
        let w2 = byteWidth(table.values.map(\.f2).max() ?? 0)
        let w3 = byteWidth(table.values.map(\.f3).max() ?? 0)
        var data: [UInt8] = []
        data.reserveCapacity(table.count * (1 + w2 + w3))
        for num in table.keys.sorted() {
            let row = table[num]!
            data.append(UInt8(row.type))
            for k in stride(from: w2 - 1, through: 0, by: -1) { data.append(UInt8((row.f2 >> (8 * k)) & 0xFF)) }
            for k in stride(from: w3 - 1, through: 0, by: -1) { data.append(UInt8((row.f3 >> (8 * k)) & 0xFF)) }
        }
        return (data, w2, w3)
    }

    private static func byteWidth(_ v: Int) -> Int {
        var n = 1
        var x = v >> 8
        while x > 0 {
            n += 1
            x >>= 8
        }
        return n
    }

    /// Groups sorted object numbers into contiguous subsections.
    static func runs(_ sorted: [Int]) -> [(start: Int, count: Int)] {
        var result: [(start: Int, count: Int)] = []
        for num in sorted {
            if let last = result.last, last.start + last.count == num {
                result[result.count - 1].count += 1
            } else {
                result.append((num, 1))
            }
        }
        return result
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
