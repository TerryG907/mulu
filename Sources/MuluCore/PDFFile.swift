import Foundation

/// The kind of the newest cross-reference section of a file.
public enum XRefKind: String, Sendable {
    case classic  // "xref" table + "trailer" dictionary (§7.5.4)
    case stream   // cross-reference stream (§7.5.8)
    case hybrid   // classic table whose trailer has /XRefStm (§7.5.8.4)
}

/// One cross-reference entry after merging all revisions.
public enum XRefEntry: Sendable, Equatable {
    case free
    case inUse(offset: Int, gen: Int)
    case compressed(stream: Int, index: Int)  // object number `index`-th in object stream `stream`
}

struct XRefSection {
    var entries: [(num: Int, entry: XRefEntry)]
    var trailer: PDFDict
    var isStream: Bool
    /// Next-free link of object 0's free entry (the head of the free list, §7.5.4),
    /// if this section has an entry for object 0.
    var freeListHead: Int? = nil
    /// The classic table said "1 N" but began with object 0's free entry, so its
    /// entries were renumbered (readers that do not apply that fix see other numbers).
    var renumbered = false
    /// The trailer dictionary had values nested deeper than the parser materialises.
    var truncated = false
}

/// A decoded object stream (§7.5.7): its data and the absolute offset of each object.
struct ObjectStreamIndex {
    let data: [UInt8]
    let objects: [(num: Int, offset: Int)]

    func position(of num: Int, hint: Int) -> Int? {
        if hint >= 0, hint < objects.count, objects[hint].num == num { return objects[hint].offset }
        // Some writers get the index wrong; fall back to searching the header.
        return objects.first(where: { $0.num == num })?.offset
    }
}

/// An "N G obj" header found by scanning the raw bytes (used only for repair).
struct ScannedObject {
    let num: Int
    let gen: Int
    let offset: Int
    let end: Int
}

private let kwStartxref = Array("startxref".utf8)
private let kwStream = Array("stream".utf8)
private let kwEndstream = Array("endstream".utf8)
private let kwEndobj = Array("endobj".utf8)
private let kwTrailer = Array("trailer".utf8)
private let kwHeader = Array("%PDF-".utf8)
private let kwXref = Array("xref".utf8)

/// A parsed PDF file: the merged cross-reference map over every revision, the newest
/// trailer, and lazy, cached object resolution. The file bytes are never modified.
public final class PDFFile {
    public let bytes: [UInt8]
    public let headerOffset: Int

    public private(set) var entries: [Int: XRefEntry] = [:]
    /// The newest trailer dictionary (for an xref stream: the stream's dictionary).
    public private(set) var trailer = PDFDict()
    public private(set) var xrefKind: XRefKind = .classic
    /// Number of cross-reference sections followed through /Prev (hybrid /XRefStm
    /// sections are counted as part of their table's revision).
    public private(set) var revisionCount = 0
    /// The value of the last `startxref` (becomes /Prev of an appended update).
    public private(set) var startXRef = 0
    /// True when the xref chain could not be read and the object map was rebuilt by
    /// scanning "N G obj" headers. An update to such a file must carry a complete xref.
    public private(set) var isReconstructed = false
    /// True if the trailer of ANY revision has /Encrypt.
    public private(set) var isEncrypted = false
    /// Largest /Size of any trailer seen.
    public private(set) var maxDeclaredSize = 0
    /// The frame the file's offsets are measured in: added to every offset read from
    /// the xref data and subtracted from every offset written. 0 normally; the header
    /// position when the file has junk before "%PDF-" and its offsets are relative to
    /// the header (qpdf, PDFium, pdf.js and PDFKit read such files that way).
    public private(set) var offsetBase = 0
    /// True when the last startxref lands exactly (no whitespace skipped) on "xref" or
    /// on an "N G obj" header in the chosen frame.
    public private(set) var startXRefIsExact = false
    /// Object 0's next-free link in the newest section that has an entry for object 0
    /// (the head of the free list). An appended classic xref repeats it unchanged.
    public private(set) var freeListHead = 0
    private var sawFreeListHead = false
    /// Objects whose xref offset was wrong and that were found, unambiguously, by
    /// scanning (absolute offsets). An update republishes these corrected entries so
    /// that every reader resolves them the way Mulu did.
    public private(set) var repairedEntries: [Int: XRefEntry] = [:]
    /// Some classic section needed the "1 N starts with object 0" renumbering; an
    /// update then republishes every entry (readers disagree about that fix).
    public private(set) var usedRenumberingFix = false
    /// Object numbers marked free in a hybrid file's table but defined by the same
    /// section's /XRefStm stream: readers disagree about which one wins.
    private var hybridConflicts: Set<Int> = []
    /// Objects whose value had containers nested deeper than `Parser.maxDepth`; the
    /// skipped parts read as null, so such an object must never be rewritten.
    public private(set) var truncatedObjects: Set<ObjRef> = []
    /// The newest trailer had containers nested deeper than `Parser.maxDepth`.
    public private(set) var trailerIsTruncated = false

    /// Deepest chain of nested object resolutions (object stream -> its /Length or
    /// /DecodeParms -> another object stream -> ...). Real files need fewer than 10.
    static let maxResolveDepth = 64
    /// Budget for all decoded xref and object stream data of one file.
    static let maxDecodedTotal = 512 << 20
    /// Implementation limit of PDF readers on indirect objects (Annex C.2).
    public static let maxObjectNumber = 8_388_607

    private var cache: [ObjRef: PDFObject] = [:]
    private var inFlight: Set<ObjRef> = []
    private var objectStreams: [Int: ObjectStreamIndex] = [:]
    private var decodedTotal = 0
    private var scanCache: [ScannedObject]? = nil
    private var scanning = false
    private var pageCache: [ObjRef]? = nil

    public convenience init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard let h = PDFFile.findHeader(bytes) else { throw MuluError.notPDF }
        headerOffset = h
        var firstError: Error? = nil
        for base in candidateBases() {
            resetState()
            do {
                try loadXRefChain(base: base)
                return
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // The startxref/xref chain is unusable. Rebuild the object map from the raw
        // "N G obj" headers, but only if the result is unambiguous.
        resetState()
        do {
            try reconstruct()
        } catch MuluError.noRoot {
            throw MuluError.noRoot
        } catch {
            throw MuluError.unparseableXRef("\(firstError.map { "\($0)" } ?? "no xref"); reconstruction failed: \(error)")
        }
    }

    /// The offset frames to try, best first. With junk before "%PDF-" the offsets may
    /// be absolute or relative to the header. A frame counts as right only if the
    /// last startxref lands EXACTLY on "xref" or "N G obj": a header-relative offset
    /// read as absolute lands a few bytes early, often on the end-of-line before the
    /// keyword, which a whitespace-skipping lexer would silently accept.
    private func candidateBases() -> [Int] {
        guard headerOffset > 0 else { return [0] }
        guard let sx = findStartXRef() else { return [0, headerOffset] }
        let relative = landsExactly(at: sx + headerOffset)
        let absolute = landsExactly(at: sx)
        // When exactly one frame fits, the other is not tried even if the chain turns
        // out to be broken further down: a whitespace-tolerant read in the wrong frame
        // could "succeed" and the update would then be written in the wrong frame.
        // Reconstruction (below) is the fallback instead.
        if relative != absolute { return relative ? [headerOffset] : [0] }
        return [0, headerOffset]
    }

    /// True if `p` is the first byte of an "xref" keyword or of an "N G obj" header.
    func landsExactly(at p: Int) -> Bool {
        guard p >= 0, p < bytes.count, !isPDFWhitespace(bytes[p]) else { return false }
        if p > 0, isPDFRegular(bytes[p - 1]) { return false }  // the middle of a token
        if bytes.matches(kwXref, at: p) { return p + 4 == bytes.count || !isPDFRegular(bytes[p + 4]) }
        return objectHeader(at: p) != nil
    }

    /// Parses "num gen obj" at `p` (leading whitespace and comments are skipped).
    func objectHeader(at p: Int) -> ObjRef? {
        guard p >= 0, p < bytes.count else { return nil }
        var lx = Lexer(bytes, at: p)
        guard case .integer(let num) = lx.next(), num >= 0, case .integer(let gen) = lx.next(), gen >= 0,
              case .keyword("obj") = lx.next()
        else { return nil }
        return ObjRef(num, gen)
    }

    /// First object number that is free for new objects: at least every declared
    /// /Size, and above every object the xref defines (free entries do not count, and
    /// numbers beyond the Annex C limit cannot collide with new objects anyway).
    public var nextObjectNumber: Int {
        var highest = 0
        for (num, e) in entries where num < PDFFile.maxObjectNumber {
            if case .free = e { continue }
            highest = max(highest, num)
        }
        return max(maxDeclaredSize, highest + 1)
    }

    /// The highest object number that any live object (or the trailer) refers to,
    /// below the Annex C limit. A reference to an undefined object means null
    /// (§7.3.10); numbering new objects above it keeps that meaning.
    public func highestReferencedObjectNumber() -> Int {
        var highest = 0
        var stack: [PDFObject] = [.dict(trailer)]
        func drain() {
            while let o = stack.popLast() {
                switch o {
                case .ref(let r): if r.num < PDFFile.maxObjectNumber { highest = max(highest, r.num) }
                case .array(let a): stack.append(contentsOf: a)
                case .dict(let d): for (_, v) in d.entries { stack.append(v) }
                case .stream(let s): for (_, v) in s.dict.entries { stack.append(v) }
                default: break
                }
            }
        }
        drain()
        for (num, e) in entries {
            let ref: ObjRef
            switch e {
            case .free: continue
            case .inUse(_, let gen): ref = ObjRef(num, gen)
            case .compressed: ref = ObjRef(num, 0)
            }
            guard let o = try? resolve(ref) else { continue }
            stack.append(o)
            drain()
        }
        return highest
    }

    /// True if a newer revision must republish every xref entry (see
    /// `usedRenumberingFix`).
    public var needsFullRepublish: Bool { usedRenumberingFix }

    /// Count of in-use objects (plain or compressed) in the merged map.
    public var objectCount: Int {
        entries.values.reduce(0) { n, e in
            if case .free = e { return n }
            return n + 1
        }
    }

    // MARK: - Header / startxref

    static func findHeader(_ bytes: [UInt8]) -> Int? {
        let limit = min(bytes.count, 1024)
        guard limit >= kwHeader.count else { return nil }
        for i in 0...(limit - kwHeader.count) where bytes.matches(kwHeader, at: i) { return i }
        return nil
    }

    /// Scans backwards for the last "startxref" and reads the offset after it. This
    /// tolerates CR/LF/CRLF and garbage after %%EOF.
    func findStartXRef() -> Int? {
        var before: Int? = nil
        while let i = bytes.lastIndex(of: kwStartxref, before: before) {
            // Must be a keyword, not the tail of a longer word.
            if i == 0 || !isPDFRegular(bytes[i - 1]) {
                var lx = Lexer(bytes, at: i + kwStartxref.count)
                if case .integer(let v) = lx.next(), v >= 0 { return v }
                return nil
            }
            if i == 0 { return nil }
            before = i - 1
        }
        return nil
    }

    private func resetState() {
        entries = [:]
        trailer = PDFDict()
        xrefKind = .classic
        revisionCount = 0
        startXRef = 0
        isEncrypted = false
        maxDeclaredSize = 0
        offsetBase = 0
        startXRefIsExact = false
        freeListHead = 0
        sawFreeListHead = false
        repairedEntries = [:]
        usedRenumberingFix = false
        hybridConflicts = []
        truncatedObjects = []
        trailerIsTruncated = false
        isReconstructed = false
        cache = [:]
        inFlight = []
        objectStreams = [:]
        decodedTotal = 0
        pageCache = nil
    }

    // MARK: - Cross-reference chain (§7.5.4, §7.5.6, §7.5.8)

    private func loadXRefChain(base: Int) throws {
        guard let sx = findStartXRef() else { throw MuluError.unparseableXRef("no startxref found") }
        startXRef = sx
        offsetBase = base
        startXRefIsExact = landsExactly(at: sx + base)
        var next: Int? = sx
        var visited = Set<Int>()
        var newest = true
        while let off = next {
            guard visited.insert(off).inserted else { break }  // /Prev cycle: stop
            guard visited.count <= 100_000 else { throw MuluError.unparseableXRef("too many xref sections") }
            let section = try parseXRefSection(at: try framed(off))
            revisionCount += 1
            if newest {
                trailer = section.trailer
                trailerIsTruncated = section.truncated
                xrefKind = section.isStream ? .stream : .classic
            }
            // Newest revision wins: an entry is only taken if no newer section (or,
            // within a hybrid section, the classic table itself) already defined it.
            let fresh = Set(section.entries.lazy.map(\.num).filter { self.entries[$0] == nil })
            merge(section.entries, base: base)
            if section.renumbered { usedRenumberingFix = true }
            noteFreeListHead(section)
            noteTrailer(section.trailer)
            if !section.isStream, let xs = section.trailer["XRefStm"]?.intValue {
                // Hybrid-reference file (§7.5.8.4): the table's entries take precedence
                // over the hidden xref stream's, which take precedence over /Prev.
                let hidden = try parseXRefSection(at: try framed(xs))
                guard hidden.isStream else { throw MuluError.unparseableXRef("/XRefStm does not point to an xref stream") }
                // qpdf and pdf.js let a free table entry win; PDFium, PDFKit and pypdf
                // use the stream's definition. Remember such objects: resolving one
                // is refused because readers would disagree.
                var tableFree = Set<Int>()
                for (num, e) in section.entries where num > 0 && fresh.contains(num) && e == .free { tableFree.insert(num) }
                for (num, e) in hidden.entries where e != .free && tableFree.contains(num) { hybridConflicts.insert(num) }
                merge(hidden.entries, base: base)
                noteFreeListHead(hidden)
                noteTrailer(hidden.trailer)
                if newest { xrefKind = .hybrid }
            }
            newest = false
            if let prev = section.trailer["Prev"] {
                guard let p = prev.intValue else { throw MuluError.unparseableXRef("/Prev is not an integer") }
                next = p
            } else {
                next = nil
            }
        }
        guard revisionCount > 0 else { throw MuluError.unparseableXRef("no xref section") }
        forgetResolvedObjects()
    }

    /// Objects resolved while the xref map was still incomplete (e.g. an indirect
    /// /Length or /DecodeParms of an xref stream) may have been cached as null or
    /// stale; drop them once the map is final.
    private func forgetResolvedObjects() {
        cache = [:]
        objectStreams = [:]
        pageCache = nil
    }

    /// A /Prev or /XRefStm value in the file's frame -> absolute offset.
    private func framed(_ off: Int) throws -> Int {
        guard off >= 0, off < bytes.count else {
            throw MuluError.unparseableXRef("xref offset \(off) is outside the file")
        }
        return off + offsetBase
    }

    private func merge(_ list: [(num: Int, entry: XRefEntry)], base: Int) {
        for (num, e) in list where num >= 0 && entries[num] == nil {
            guard case .inUse(let off, let gen) = e else {
                entries[num] = e
                continue
            }
            if off == 0 {
                // "In use at offset 0" (Quartz writes these for unused objects): there
                // is no object there. qpdf and pdf.js read it as null, and it must hide
                // any older definition of the same number.
                entries[num] = .free
            } else if off < 0 || off >= bytes.count {
                // Garbage (e.g. an 8-byte field near Int64.max): kept as is, so that
                // no arithmetic can overflow; loading it falls back to a scan.
                entries[num] = .inUse(offset: off, gen: gen)
            } else {
                entries[num] = .inUse(offset: off + base, gen: gen)  // stored as absolute file offsets
            }
        }
    }

    /// Sections are visited newest first, so the first object-0 entry seen wins.
    private func noteFreeListHead(_ section: XRefSection) {
        guard !sawFreeListHead, let head = section.freeListHead else { return }
        freeListHead = head
        sawFreeListHead = true
    }

    private func noteTrailer(_ t: PDFDict) {
        if let e = t["Encrypt"], !e.isNull { isEncrypted = true }
        if let s = t["Size"]?.intValue { maxDeclaredSize = max(maxDeclaredSize, s) }
    }

    func parseXRefSection(at offset: Int) throws -> XRefSection {
        guard offset >= 0, offset < bytes.count else {
            throw MuluError.unparseableXRef("xref offset \(offset) is outside the file")
        }
        var lx = Lexer(bytes, at: offset)
        switch lx.next() {
        case .keyword("xref"):
            return try parseClassicSection(lx)
        case .integer:
            return try parseXRefStreamSection(at: offset)
        default:
            throw MuluError.unparseableXRef("no xref table or xref stream at offset \(offset)")
        }
    }

    /// Classic table: subsections of "start count" followed by `count` entries of the
    /// form "oooooooooo ggggg n|f". Entries are read as tokens rather than fixed
    /// 20-byte records, which tolerates writers that use a one-byte EOL.
    private func parseClassicSection(_ lexer: Lexer) throws -> XRefSection {
        var lx = lexer
        var list: [(num: Int, entry: XRefEntry)] = []
        var freeListHead: Int? = nil
        var renumbered = false
        var firstSubsection = true
        while true {
            let t = lx.next()
            if case .keyword("trailer") = t { break }
            guard case .integer(var start) = t, case .integer(let count) = lx.next(), start >= 0, count >= 0 else {
                throw MuluError.unparseableXRef("bad xref subsection header")
            }
            guard count <= bytes.count / 10 + 1 else { throw MuluError.unparseableXRef("implausible xref subsection size") }
            for i in 0..<count {
                guard case .integer(let off) = lx.next(), case .integer(let gen) = lx.next(),
                      case .keyword(let kind) = lx.next()
                else { throw MuluError.unparseableXRef("bad xref entry") }
                // A common writer bug: the first subsection says "1 N" but starts with
                // object 0's free entry. pdf.js applies the same correction.
                if firstSubsection, i == 0, start == 1, kind == "f", off == 0, gen == 65535 {
                    start = 0
                    renumbered = true
                }
                let num = start + i
                switch kind {
                case "n":
                    list.append((num, .inUse(offset: off, gen: gen)))  // offset 0: see merge()
                case "f":
                    list.append((num, .free))
                    if num == 0, freeListHead == nil { freeListHead = off }
                default:
                    throw MuluError.unparseableXRef("bad xref entry type '\(kind)'")
                }
            }
            firstSubsection = false
        }
        var parser = Parser(lexer: lx)
        guard case .dict(let d) = try parser.parseObject() else {
            throw MuluError.unparseableXRef("trailer is not a dictionary")
        }
        return XRefSection(entries: list, trailer: d, isStream: false, freeListHead: freeListHead,
                           renumbered: renumbered, truncated: parser.truncated)
    }

    /// Cross-reference stream (§7.5.8): rows of /W-sized big-endian fields.
    private func parseXRefStreamSection(at offset: Int) throws -> XRefSection {
        let parsed = try parseIndirect(at: offset, resolveLength: true)
        guard case .stream(let s) = parsed.object else {
            throw MuluError.unparseableXRef("object at xref offset \(offset) is not a stream")
        }
        let d = s.dict
        guard d["Type"]?.nameValue == "XRef" || (d["Type"] == nil && d["W"] != nil) else {
            throw MuluError.unparseableXRef("stream at xref offset \(offset) is not /Type /XRef")
        }
        guard let wArr = d["W"]?.arrayValue, wArr.count == 3 else { throw MuluError.unparseableXRef("bad /W") }
        let w = wArr.compactMap(\.intValue)
        guard w.count == 3, w.allSatisfy({ $0 >= 0 && $0 <= 8 }), w.reduce(0, +) > 0 else {
            throw MuluError.unparseableXRef("bad /W")
        }
        let size = d["Size"]?.intValue ?? 0
        var index = [0, size]
        if let idx = d["Index"]?.arrayValue {
            index = idx.compactMap(\.intValue)
            guard index.count == idx.count, index.count % 2 == 0 else { throw MuluError.unparseableXRef("bad /Index") }
        }
        let data = try decodeStream(s)
        let rowLength = w[0] + w[1] + w[2]

        func field(_ at: Int, _ width: Int) -> Int {
            var v = 0
            for k in 0..<width { v = v << 8 | Int(data[at + k]) }
            return v
        }

        var list: [(num: Int, entry: XRefEntry)] = []
        var freeListHead: Int? = nil
        var p = 0
        for pair in stride(from: 0, to: index.count, by: 2) {
            let start = index[pair]
            let count = index[pair + 1]
            guard start >= 0, count >= 0 else { throw MuluError.unparseableXRef("bad /Index") }
            for i in 0..<count {
                guard p + rowLength <= data.count else {
                    throw MuluError.unparseableXRef("xref stream data is shorter than /Index says")
                }
                // Field 1 defaults to type 1 when its width is 0 (Table 17).
                let type = w[0] == 0 ? 1 : field(p, w[0])
                let f2 = field(p + w[0], w[1])
                let f3 = field(p + w[0] + w[1], w[2])
                p += rowLength
                switch type {
                case 0:
                    list.append((start + i, .free))
                    if start + i == 0, freeListHead == nil { freeListHead = f2 }
                case 1: list.append((start + i, .inUse(offset: f2, gen: f3)))
                case 2: list.append((start + i, .compressed(stream: f2, index: f3)))
                default: break  // unknown types are references to the null object
                }
            }
        }
        return XRefSection(entries: list, trailer: d, isStream: true, freeListHead: freeListHead,
                           truncated: parsed.truncated)
    }

    // MARK: - Indirect objects

    /// Parses "num gen obj <object> [stream ... endstream] endobj" at `offset`.
    /// Returns the header, the object, and the offset just past it.
    func parseIndirect(at offset: Int, resolveLength: Bool) throws -> (ref: ObjRef, object: PDFObject, end: Int, truncated: Bool) {
        guard offset >= 0, offset < bytes.count else { throw MuluError.malformed("offset \(offset) is outside the file") }
        var parser = Parser(lexer: Lexer(bytes, at: offset))
        guard case .integer(let num) = parser.lexer.next(), num >= 0,
              case .integer(let gen) = parser.lexer.next(), gen >= 0,
              case .keyword("obj") = parser.lexer.next()
        else { throw MuluError.malformed("no object header at offset \(offset)") }
        let ref = ObjRef(num, gen)
        let first = parser.lexer.next()
        if case .keyword("endobj") = first { return (ref, .null, parser.lexer.pos, false) }
        let object = try parser.parseObject(startingWith: first, depth: 0)
        var probe = parser.lexer
        probe.skipWhitespaceAndComments()
        if case .dict(let dict) = object, bytes.matches(kwStream, at: probe.pos) {
            let dataStart = streamDataStart(afterKeywordAt: probe.pos)
            let range = try streamDataRange(dict: dict, dataStart: dataStart, owner: ref, resolveLength: resolveLength)
            return (ref, .stream(PDFStream(dict: dict, dataRange: range)), range.upperBound, parser.truncated)
        }
        let end = bytes.matches(kwEndobj, at: probe.pos) ? probe.pos + kwEndobj.count : parser.lexer.pos
        return (ref, object, end, parser.truncated)
    }

    /// §7.3.8.1: "stream" is followed by CRLF or LF (a lone CR is tolerated), and the
    /// data starts right after that end-of-line marker.
    private func streamDataStart(afterKeywordAt p0: Int) -> Int {
        let n = bytes.count
        var p = p0 + kwStream.count
        let afterKeyword = p
        while p < n, bytes[p] == 0x20 { p += 1 }  // tolerate "stream  \n"
        if p < n, bytes[p] == 0x0D {
            p += 1
            if p < n, bytes[p] == 0x0A { p += 1 }
            return p
        }
        if p < n, bytes[p] == 0x0A { return p + 1 }
        return afterKeyword
    }

    /// Uses /Length (possibly an indirect object) when "endstream" follows it;
    /// otherwise falls back to searching for "endstream".
    private func streamDataRange(dict: PDFDict, dataStart: Int, owner: ObjRef, resolveLength: Bool) throws -> Range<Int> {
        var declared: Int? = nil
        if let len = dict["Length"] {
            if case .ref(let r) = len {
                if resolveLength, r != owner, let v = try? resolve(r) { declared = v.intValue }
            } else {
                declared = len.intValue
            }
        }
        if let n = declared, n >= 0, n <= bytes.count - dataStart, isEndstream(at: dataStart + n) {
            return dataStart..<(dataStart + n)
        }
        if let e = bytes.firstIndex(of: kwEndstream, from: dataStart) {
            var end = e
            if end > dataStart, bytes[end - 1] == 0x0A { end -= 1 }
            if end > dataStart, bytes[end - 1] == 0x0D { end -= 1 }
            return dataStart..<end
        }
        if let n = declared, n >= 0, n <= bytes.count - dataStart { return dataStart..<(dataStart + n) }
        throw MuluError.malformed("cannot determine the length of the stream in object \(owner)")
    }

    private func isEndstream(at p0: Int) -> Bool {
        var p = p0
        while p < bytes.count, isPDFWhitespace(bytes[p]) { p += 1 }
        return bytes.matches(kwEndstream, at: p)
    }

    /// Resolves an indirect reference. Missing and free objects are `null` (§7.3.10).
    public func resolve(_ ref: ObjRef) throws -> PDFObject {
        if let hit = cache[ref] { return hit }
        guard !inFlight.contains(ref) else { throw MuluError.malformed("reference cycle involving \(ref)") }
        // Resolving can recurse (object stream -> its /DecodeParms, stored in another
        // object stream -> ...). Bound the depth so hostile chains cannot overflow the
        // stack; inFlight holds exactly the references being resolved right now.
        guard inFlight.count < PDFFile.maxResolveDepth else {
            throw MuluError.unsupported("object references nest more than \(PDFFile.maxResolveDepth) levels deep (object streams whose parameters live in other object streams)")
        }
        inFlight.insert(ref)
        defer { inFlight.remove(ref) }
        let object = try load(ref)
        cache[ref] = object
        return object
    }

    /// Follows references until a direct object is reached.
    public func resolve(_ object: PDFObject) throws -> PDFObject {
        var cur = object
        var hops = 0
        while case .ref(let r) = cur {
            cur = try resolve(r)
            hops += 1
            if hops > 32 { throw MuluError.malformed("reference chain too long") }
        }
        return cur
    }

    private func load(_ ref: ObjRef) throws -> PDFObject {
        switch entries[ref.num] {
        case .none:
            return .null
        case .some(.free):
            if hybridConflicts.contains(ref.num) {
                throw MuluError.ambiguous("the hybrid xref table marks object \(ref.num) free but its /XRefStm stream defines it; readers disagree about which one wins")
            }
            return .null
        case .some(.inUse(let offset, let gen)):
            // A reference whose generation differs from the xref's refers to an object
            // that does not exist, i.e. null.
            guard gen == ref.gen else { return .null }
            return try loadUncompressed(ref, offset: offset)
        case .some(.compressed(let stream, let index)):
            guard ref.gen == 0 else { return .null }  // compressed objects are always generation 0
            return try loadCompressed(ref.num, stream: stream, index: index)
        }
    }

    private func loadUncompressed(_ ref: ObjRef, offset: Int) throws -> PDFObject {
        if objectHeader(at: offset) == ref {
            // The xref is right: errors in the object itself are reported as such,
            // not hidden behind a search for another copy.
            let parsed = try parseIndirect(at: offset, resolveLength: true)
            if parsed.truncated { truncatedObjects.insert(ref) }
            return parsed.object
        }
        // The xref offset is wrong. Accept the object only if exactly one "num gen obj"
        // header for it exists in the file; otherwise we cannot know which is meant.
        let candidates = scannedObjects().filter { $0.num == ref.num && $0.gen == ref.gen }
        guard candidates.count == 1 else {
            if candidates.isEmpty { throw MuluError.malformed("object \(ref.num) \(ref.gen) not found (xref offset \(offset) is wrong)") }
            throw MuluError.ambiguous("xref offset for object \(ref.num) \(ref.gen) is wrong and the object is defined \(candidates.count) times")
        }
        let parsed = try parseIndirect(at: candidates[0].offset, resolveLength: true)
        guard parsed.ref == ref else { throw MuluError.malformed("object \(ref.num) \(ref.gen) not found") }
        if parsed.truncated { truncatedObjects.insert(ref) }
        if !isReconstructed { repairedEntries[ref.num] = .inUse(offset: candidates[0].offset, gen: ref.gen) }
        return parsed.object
    }

    private func loadCompressed(_ num: Int, stream: Int, index: Int) throws -> PDFObject {
        let os = try objectStream(stream)
        guard let pos = os.position(of: num, hint: index) else { return .null }
        var parser = Parser(lexer: Lexer(os.data, at: pos))
        let object = try parser.parseObject()
        if parser.truncated { truncatedObjects.insert(ObjRef(num, 0)) }
        return object
    }

    /// Loads and indexes object stream `num` (§7.5.7): /N pairs "objnum offset" at the
    /// start of the decoded data, offsets relative to /First.
    func objectStream(_ num: Int) throws -> ObjectStreamIndex {
        if let hit = objectStreams[num] { return hit }
        guard case .inUse(_, let gen)? = entries[num] else {
            throw MuluError.malformed("object stream \(num) is missing or is itself compressed")
        }
        guard case .stream(let s) = try resolve(ObjRef(num, gen)) else {
            throw MuluError.malformed("object \(num) is not an object stream")
        }
        let data = try decodeStream(s)
        let dict = resolvedShallow(s.dict)
        guard let n = dict["N"]?.intValue, let first = dict["First"]?.intValue,
              n >= 0, first >= 0, first <= data.count
        else { throw MuluError.malformed("object stream \(num) has bad /N or /First") }
        var lx = Lexer(data, at: 0)
        var objects: [(num: Int, offset: Int)] = []
        objects.reserveCapacity(min(n, data.count / 2))
        for _ in 0..<n {
            guard lx.pos < first, case .integer(let on) = lx.next(), case .integer(let rel) = lx.next(),
                  on >= 0, rel >= 0, first + rel <= data.count
            else { break }
            objects.append((on, first + rel))
        }
        let index = ObjectStreamIndex(data: data, objects: objects)
        objectStreams[num] = index
        return index
    }

    /// Decodes a stream's data through its /Filter chain.
    public func decodeStream(_ s: PDFStream) throws -> [UInt8] {
        var data = Array(bytes[s.dataRange])
        for (name, parms) in try filterChain(s.dict) {
            data = try Filters.decode(data, filter: name, parms: parms)
            guard data.count <= Filters.maxDecodedSize else { throw Filters.tooLarge() }
        }
        decodedTotal += data.count
        guard decodedTotal <= PDFFile.maxDecodedTotal else {
            throw MuluError.unsupported("the cross-reference and object streams decode to more than \(PDFFile.maxDecodedTotal >> 20) MiB in total")
        }
        return data
    }

    private func filterChain(_ d: PDFDict) throws -> [(String, PDFDict?)] {
        var names: [String] = []
        switch try d["Filter"].map({ try resolve($0) }) {
        case .name(let n)?: names = [n]
        case .array(let a)?:
            names = try a.map {
                guard case .name(let n) = try resolve($0) else { throw MuluError.malformed("bad /Filter") }
                return n
            }
        case nil, .null?: break
        default: throw MuluError.malformed("bad /Filter")
        }
        var parms: [PDFDict?] = []
        switch try (d["DecodeParms"] ?? d["DP"]).map({ try resolve($0) }) {
        case .dict(let p)?: parms = [p]
        case .array(let a)?: parms = try a.map { try resolve($0).dictValue }
        default: break
        }
        return names.enumerated().map { i, name in
            (name, i < parms.count ? parms[i].map(resolvedShallow) : nil)
        }
    }

    private func resolvedShallow(_ d: PDFDict) -> PDFDict {
        var r = d
        for (k, v) in d.entries {
            if case .ref = v, let x = try? resolve(v) { r[k] = x }
        }
        return r
    }

    // MARK: - Reconstruction (repair) by scanning "N G obj" headers

    /// All "N G obj" headers in file order, skipping any that fall inside the data of
    /// an earlier stream (e.g. an embedded PDF), with the end offset of each object.
    func scannedObjects() -> [ScannedObject] {
        if let hit = scanCache { return hit }
        if scanning { return [] }
        scanning = true
        defer { scanning = false }
        var result: [ScannedObject] = []
        var skipUntil = 0
        for h in scanHeaders() where h.offset >= max(skipUntil, headerOffset) {  // not in junk before %PDF-
            guard let parsed = try? parseIndirect(at: h.offset, resolveLength: false),
                  parsed.ref.num == h.num, parsed.ref.gen == h.gen
            else { continue }
            result.append(ScannedObject(num: h.num, gen: h.gen, offset: h.offset, end: parsed.end))
            skipUntil = parsed.end
        }
        scanCache = result
        return result
    }

    private func scanHeaders() -> [(num: Int, gen: Int, offset: Int)] {
        var out: [(num: Int, gen: Int, offset: Int)] = []
        bytes.withUnsafeBufferPointer { buf in
            let n = buf.count
            var i = 1
            while i + 2 < n {
                // "obj" as a whole keyword...
                if buf[i] == 0x6F, buf[i + 1] == 0x62, buf[i + 2] == 0x6A, i + 3 == n || !isPDFRegular(buf[i + 3]) {
                    // ...preceded by whitespace, digits (gen), whitespace, digits (num).
                    var j = i - 1
                    if isPDFWhitespace(buf[j]) {
                        while j >= 0, isPDFWhitespace(buf[j]) { j -= 1 }
                        let genEnd = j + 1
                        while j >= 0, isASCIIDigit(buf[j]) { j -= 1 }
                        let genStart = j + 1
                        if genStart < genEnd, genEnd - genStart <= 5, j >= 0, isPDFWhitespace(buf[j]) {
                            while j >= 0, isPDFWhitespace(buf[j]) { j -= 1 }
                            let numEnd = j + 1
                            while j >= 0, isASCIIDigit(buf[j]) { j -= 1 }
                            let numStart = j + 1
                            if numStart < numEnd, numEnd - numStart <= 10, j < 0 || !isPDFRegular(buf[j]) {
                                var num = 0, gen = 0
                                for k in numStart..<numEnd { num = num * 10 + Int(buf[k] - 0x30) }
                                for k in genStart..<genEnd { gen = gen * 10 + Int(buf[k] - 0x30) }
                                out.append((num, gen, numStart))
                            }
                        }
                    }
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    private func reconstruct() throws {
        isReconstructed = true
        // Scanned offsets are absolute. With junk before "%PDF-", the complete table
        // written by an update uses the frame qpdf, PDFium, pdf.js and PDFKit use for
        // such a file: relative to the header.
        offsetBase = headerOffset
        let objects = scannedObjects()
        guard !objects.isEmpty else { throw MuluError.unparseableXRef("no objects found") }

        var direct: [Int: ScannedObject] = [:]
        for o in objects {
            if let prev = direct[o.num] {
                throw MuluError.ambiguous("object \(o.num) is defined at offsets \(prev.offset) and \(o.offset)")
            }
            direct[o.num] = o
        }
        for (num, o) in direct { entries[num] = .inUse(offset: o.offset, gen: o.gen) }

        var trailers: [(pos: Int, dict: PDFDict)] = []
        var compressedIn: [Int: Int] = [:]
        var sawXRefStream = false
        for o in objects {
            guard let obj = try? resolve(ObjRef(o.num, o.gen)), case .stream(let s) = obj else { continue }
            switch s.dict["Type"]?.nameValue {
            case "ObjStm":
                guard let os = try? objectStream(o.num) else { continue }
                for (i, item) in os.objects.enumerated() {
                    if direct[item.num] != nil || compressedIn[item.num] != nil {
                        throw MuluError.ambiguous("object \(item.num) is defined more than once")
                    }
                    compressedIn[item.num] = o.num
                    entries[item.num] = .compressed(stream: o.num, index: i)
                }
            case "XRef":
                sawXRefStream = true
                trailers.append((o.offset, s.dict))
            default:
                break
            }
        }

        var searchFrom = 0
        while let p = bytes.firstIndex(of: kwTrailer, from: searchFrom) {
            searchFrom = p + kwTrailer.count
            let boundaryBefore = p == 0 || !isPDFRegular(bytes[p - 1])
            let boundaryAfter = searchFrom >= bytes.count || !isPDFRegular(bytes[searchFrom])
            guard boundaryBefore, boundaryAfter, !PDFFile.isInside(p, objects) else { continue }
            var parser = Parser(lexer: Lexer(bytes, at: searchFrom))
            if case .dict(let d)? = try? parser.parseObject() { trailers.append((p, d)) }
        }
        trailers.sort { $0.pos < $1.pos }
        guard !trailers.isEmpty else { throw MuluError.unparseableXRef("no trailer dictionary found") }
        for t in trailers { noteTrailer(t.dict) }
        let roots = Set(trailers.compactMap { $0.dict["Root"]?.refValue })
        guard !roots.isEmpty else { throw MuluError.noRoot }
        guard roots.count == 1 else { throw MuluError.ambiguous("trailers disagree about /Root") }
        trailer = trailers.last(where: { $0.dict["Root"]?.refValue != nil })!.dict
        xrefKind = sawXRefStream ? .stream : .classic
        revisionCount = trailers.count
        maxDeclaredSize = max(maxDeclaredSize, (entries.keys.max() ?? 0) + 1)
        forgetResolvedObjects()
    }

    private static func isInside(_ p: Int, _ objects: [ScannedObject]) -> Bool {
        // objects are sorted by offset and non-overlapping: binary search.
        var lo = 0, hi = objects.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if objects[mid].offset <= p { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 && p < objects[found].end
    }

    // MARK: - Document structure

    /// The catalog dictionary (§7.7.2), if /Root resolves to a dictionary.
    public func catalog() throws -> PDFDict? {
        guard let r = trailer["Root"]?.refValue else { return nil }
        if case .dict(let d) = try resolve(r) { return d }
        return nil
    }

    /// Page objects in document order (§7.7.3.2): /Root /Pages, then /Kids
    /// recursively. Implemented iteratively so deep trees cannot overflow.
    ///
    /// Readers disagree about page numbering in damaged page trees (PDFKit, PDFium and
    /// pdf.js trust /Count; qpdf and pypdf walk /Kids; they skip different broken
    /// kids), so an outline pointing into such a tree could land on different pages.
    /// These are therefore refused rather than repaired: a cycle or a node listed
    /// twice, a page listed twice, a kid that is missing or not a dictionary, a kid
    /// that is not an indirect reference, and a node whose /Count differs from the
    /// number of pages under it.
    public func pageRefs() throws -> [ObjRef] {
        if let hit = pageCache { return hit }
        guard let cat = try catalog() else { throw MuluError.noRoot }
        guard let pagesObj = cat["Pages"] else {
            pageCache = []
            return []
        }
        enum Kind { case node([PDFObject]), leaf }
        func kind(_ d: PDFDict) throws -> Kind {
            var type: String? = nil
            if let t = d["Type"] { type = try resolve(t).nameValue }
            var kids: [PDFObject]? = nil
            if let k = d["Kids"] { kids = try resolve(k).arrayValue }
            if type == "Pages" { return .node(kids ?? []) }
            if type == "Page" { return .leaf }
            if let kids { return .node(kids) }
            return .leaf
        }
        func declaredCount(_ d: PDFDict) throws -> Int? {
            guard let c = d["Count"] else { return nil }
            return try resolve(c).intValue
        }
        struct Frame {
            var ref: ObjRef?
            var kids: [PDFObject]
            var next = 0
            var pages = 0
            var declared: Int?
        }

        guard case .dict(let rootDict) = try resolve(pagesObj) else {
            pageCache = []
            return []
        }
        var result: [ObjRef] = []
        var visitedNodes = Set<ObjRef>()
        var seenPages = Set<ObjRef>()
        var stack: [Frame] = []
        switch try kind(rootDict) {
        case .leaf:
            guard let r = pagesObj.refValue else {
                throw MuluError.unsupported("the only page is a direct object and cannot be a destination")
            }
            result.append(r)
        case .node(let kids):
            if let r = pagesObj.refValue { visitedNodes.insert(r) }
            stack.append(Frame(ref: pagesObj.refValue, kids: kids, declared: try declaredCount(rootDict)))
        }
        while let top = stack.last {
            if top.next >= top.kids.count {
                stack.removeLast()
                if let d = top.declared, d != top.pages {
                    let node = top.ref.map { "\($0)" } ?? "the root /Pages"
                    throw MuluError.ambiguous("page tree node \(node) has /Count \(d) but \(top.pages) page(s) under it; readers would number pages differently")
                }
                if !stack.isEmpty { stack[stack.count - 1].pages += top.pages }
                continue
            }
            let kid = top.kids[top.next]
            stack[stack.count - 1].next += 1
            guard case .ref(let r) = kid else {
                throw MuluError.unsupported("the page tree has a kid that is not an indirect reference; readers number such pages differently")
            }
            guard case .dict(let d) = try resolve(kid) else {
                throw MuluError.ambiguous("page tree kid \(r) is missing or not a dictionary; readers would disagree about the page count")
            }
            switch try kind(d) {
            case .leaf:
                // A page listed twice: pypdf maps it to its last position, others to
                // its first, so an outline entry for it would land on different pages.
                guard seenPages.insert(r).inserted else {
                    throw MuluError.ambiguous("page \(r) appears twice in the page tree; readers would number pages differently")
                }
                result.append(r)
                stack[stack.count - 1].pages += 1
            case .node(let kids):
                guard visitedNodes.insert(r).inserted else {
                    throw MuluError.malformed("the page tree has a cycle: node \(r) is reached twice")
                }
                guard stack.count < 100_000 else { throw MuluError.malformed("page tree too deep") }
                stack.append(Frame(ref: r, kids: kids, declared: try declaredCount(d)))
            }
        }
        pageCache = result
        return result
    }

    /// True if the first object in the file is a linearization dictionary whose /L
    /// equals the file length (Annex F.2: once a file has been updated incrementally,
    /// /L no longer matches and the linearization is no longer valid; pdf.js and
    /// qpdf apply the same test).
    public var isLinearized: Bool {
        var lx = Lexer(bytes, at: headerOffset)  // the header line is a comment to the lexer
        guard case .integer = lx.next(), case .integer = lx.next(), case .keyword("obj") = lx.next(),
              lx.pos <= headerOffset + 1024
        else { return false }
        var parser = Parser(lexer: lx)
        guard case .dict(let d)? = try? parser.parseObject(), d["Linearized"] != nil else { return false }
        return d["L"]?.intValue == bytes.count
    }
}
