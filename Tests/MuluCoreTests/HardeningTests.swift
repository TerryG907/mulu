import Foundation
import Testing
@testable import MuluCore

/// One test (or more) per adversarial finding fixed in the hardening pass. The
/// byte-level reproducers themselves live in Fixtures/regression and run through all
/// five readers in tools/run_all.sh; these tests pin the behaviour in MuluCore.
@Suite struct HardeningTests {
    // MARK: helpers

    /// The rows of the newest cross-reference section of `bytes`.
    func newestRows(_ bytes: [UInt8]) throws -> [Int: XRefEntry] {
        let doc = try PDFFile(bytes: bytes)
        let section = try doc.parseXRefSection(at: doc.startXRef + doc.offsetBase)
        return Dictionary(section.entries.map { ($0.num, $0.entry) }, uniquingKeysWith: { a, _ in a })
    }

    /// True if at least `n` whitespace bytes precede `offset`.
    func whitespaceBefore(_ bytes: [UInt8], _ offset: Int, _ n: Int) -> Bool {
        guard offset >= n else { return false }
        return (offset - n..<offset).allSatisfy { isPDFWhitespace(bytes[$0]) }
    }

    /// Checks every row the update added: header-relative, exact, padded for absolute readers.
    func checkUpdateFrame(_ out: [UInt8], inputCount: Int, frame: Int) throws {
        let doc = try PDFFile(bytes: out)
        #expect(doc.offsetBase == frame)
        #expect(doc.startXRefIsExact)
        #expect(whitespaceBefore(out, doc.startXRef + frame, frame))
        for (num, e) in try newestRows(out) {
            guard case .inUse(let off, let gen) = e, off + frame >= inputCount else { continue }
            #expect(doc.objectHeader(at: off + frame) == ObjRef(num, gen))
            #expect(doc.landsExactly(at: off + frame))
            #expect(whitespaceBefore(out, off + frame, frame), "object \(num) lacks \(frame) whitespace bytes before it")
        }
    }

    // MARK: SR-1, SR-2, HI-4: junk before %PDF- (1-2 bytes) keeps the header-relative frame

    @Test(arguments: [Array("\n".utf8), Array("\r\n".utf8), Array(" ".utf8)])
    func shortJunkPrefixClassic(_ junk: [UInt8]) throws {
        let input = junk + Fixtures.classic(pages: 3)  // offsets relative to "%PDF-"
        let doc = try PDFFile(bytes: input)
        #expect(doc.offsetBase == junk.count)  // not 0: the EOL before "xref" must not fool it
        #expect(doc.startXRefIsExact)
        let r = try Mulu.apply(pdf: input, tocText: "A 1\n\tB 2\nC 3", offset: 0)
        try checkUpdateFrame(r.output, inputCount: input.count, frame: junk.count)
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [0, 1, 2])
        // /Prev keeps the original's (header-relative) startxref value.
        let out = try PDFFile(bytes: r.output)
        #expect(out.trailer["Prev"] == .int(doc.startXRef))
        // Re-apply stays in the same frame.
        let r2 = try Mulu.apply(pdf: r.output, tocText: "Z 3", offset: 0)
        try checkUpdateFrame(r2.output, inputCount: r.output.count, frame: junk.count)
    }

    @Test(arguments: [Array("\n".utf8), Array("\r\n".utf8)])
    func shortJunkPrefixXRefStream(_ junk: [UInt8]) throws {
        let input = junk + Fixtures.objectStreamCatalog(pages: 4)
        #expect(try PDFFile(bytes: input).offsetBase == junk.count)
        let r = try Mulu.apply(pdf: input, tocText: "A 1\nB 4", offset: 0)
        try checkUpdateFrame(r.output, inputCount: input.count, frame: junk.count)
    }

    @Test func absoluteOffsetsWithJunkStayAbsolute() throws {
        var b = PDFBuilder(version: "1.4")
        b.bytes = Array("\n".utf8) + b.bytes  // one junk byte, offsets absolute
        Fixtures.pageObjects(&b, pages: 2)
        b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R >>")
        #expect(try PDFFile(bytes: b.bytes).offsetBase == 0)
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 2", offset: 0)
        try checkUpdateFrame(r.output, inputCount: b.bytes.count, frame: 0)
    }

    // MARK: SR-3: the reconstruction path writes its complete table in the header frame

    @Test func reconstructionWithJunkUsesHeaderFrame() throws {
        let junk = Array("GARBAGE\n".utf8)
        let broken = junk + withStartxref(Fixtures.classic(pages: 3)) { _ in 5 }  // points into the header
        let doc = try PDFFile(bytes: broken)
        #expect(doc.isReconstructed)
        #expect(doc.offsetBase == junk.count)
        let r = try Mulu.apply(pdf: broken, tocText: "A 1\nB 3", offset: 0)
        let out = try PDFFile(bytes: r.output)
        #expect(!out.isReconstructed)
        #expect(out.offsetBase == junk.count)
        #expect(out.trailer["Prev"] == nil)
        for (num, e) in try newestRows(r.output) {
            guard case .inUse(let off, let gen) = e else { continue }
            #expect(out.objectHeader(at: off + junk.count) == ObjRef(num, gen))
            #expect(out.landsExactly(at: off + junk.count))
        }
    }

    // MARK: SR-4: the added trailer keeps every entry of the previous one (§7.5.6)

    @Test func trailerEntriesAreCarriedOver() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 2)
        b.classicXRef(nums: [1, 2, 3, 4, 5],
                      trailer: "<< /Size 6 /Root 1 0 R /Info 5 0 R /ABCD:DocFlags (keep-me) /Extra [1 2] >>")
        let out = try PDFFile(bytes: try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0).output)
        #expect(out.trailer["ABCD:DocFlags"] == .string(Array("keep-me".utf8)))
        #expect(out.trailer["Extra"] == .array([.int(1), .int(2)]))
        #expect(out.trailer["Info"] == .ref(ObjRef(5, 0)))

        var s = PDFBuilder(version: "1.5")
        Fixtures.pageObjects(&s, pages: 2)
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535)]
        for k in 1...5 { rows[k] = (1, s.offsets[k]!.offset, 0) }
        s.xrefStream(num: 6, rows: rows, trailerKeys: "/Root 1 0 R /Info 5 0 R /ABCD:DocFlags (keep-me)")
        let so = try PDFFile(bytes: try Mulu.apply(pdf: s.bytes, tocText: "A 1", offset: 0).output)
        #expect(so.xrefKind == .stream)
        #expect(so.trailer["ABCD:DocFlags"] == .string(Array("keep-me".utf8)))
        #expect(so.trailer["Filter"] == nil)  // stream-specific keys are the update's own
        #expect(so.trailer["DecodeParms"] == nil)
    }

    // MARK: SR-5: new objects are numbered above dangling references (§7.3.10)

    @Test func newObjectsDoNotCaptureDanglingReferences() throws {
        var b = PDFBuilder(version: "1.4")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
        b.obj(3, "<< /Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R] /Resources 12 0 R >>")
        b.obj(4, "<< /Type /Page /Parent 2 0 R >>")
        b.classicXRef(nums: [1, 2, 3, 4], trailer: "<< /Size 5 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(doc.nextObjectNumber == 5)
        #expect(doc.highestReferencedObjectNumber() == 12)
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 1\nB 2", offset: 0)
        let rows = try newestRows(r.output)
        #expect(rows.keys.filter { $0 != 0 && $0 != 1 }.allSatisfy { $0 > 12 })
        let out = try PDFFile(bytes: r.output)
        #expect(try out.resolve(ObjRef(10, 0)) == .null)
        #expect(try out.resolve(ObjRef(12, 0)) == .null)
    }

    // MARK: HI-1: offsets near Int64.max never trap

    @Test func hugeXRefStreamOffsetWithJunkPrefix() throws {
        var b = PDFBuilder(version: "1.5")
        Fixtures.pageObjects(&b, pages: 2)
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535)]
        for k in 1...5 { rows[k] = (1, b.offsets[k]!.offset, 0) }
        rows[50] = (1, Int.max, 0)
        b.xrefStream(num: 6, rows: rows, trailerKeys: "/Root 1 0 R", pngFilters: nil, w: (1, 8, 1))
        let input = Array("JUNKJUNKJUNKJUNK\n".utf8) + b.bytes
        let doc = try PDFFile(bytes: input)  // no trap is the point
        #expect(doc.offsetBase == 17)
        _ = try? doc.resolve(ObjRef(50, 0))
        _ = try Mulu.apply(pdf: input, tocText: "A 1\nB 2", offset: 0)
    }

    // MARK: HI-2: nesting through object streams is bounded

    @Test func deepDecodeParmsChainIsRefusedNotCrashing() throws {
        let depth = 200
        var b = PDFBuilder(version: "1.5")
        b.obj(3, "<< /Type /Page /Parent 2 0 R >>")
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535), 3: (1, b.offsets[3]!.offset, 0)]
        // Object stream 1000+k holds the /DecodeParms of object stream 1000+k-1 (object
        // 2000+k-1); object stream 1000 holds the catalog and the page tree root.
        for k in stride(from: depth, through: 0, by: -1) {
            let objs: [(Int, String)] = k == 0
                ? [(1, "<< /Type /Catalog /Pages 2 0 R >>"), (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")]
                : [(2000 + k - 1, "<< /Predictor 1 >>")]
            var header = "", content = ""
            for (num, text) in objs {
                header += "\(num) \(content.utf8.count) "
                content += text + " "
            }
            let parms = k < depth ? "/DecodeParms \(2000 + k) 0 R" : ""
            b.stream(1000 + k, dict: "/Type /ObjStm /N \(objs.count) /First \(header.utf8.count) /Filter /FlateDecode \(parms)",
                     data: Filters.zlibCompress(Array((header + content).utf8)))
            rows[1000 + k] = (1, b.offsets[1000 + k]!.offset, 0)
            for (i, (num, _)) in objs.enumerated() { rows[num] = (2, 1000 + k, i) }
        }
        b.xrefStream(num: 5000, rows: rows, trailerKeys: "/Root 1 0 R")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(throws: MuluError.self) { try doc.pageRefs() }
        do {
            _ = try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0)
            Issue.record("expected a refusal")
        } catch let e as MuluError {
            #expect("\(e)".contains("nest more than"))
        }
    }

    // MARK: HI-3, HI-5, HI-6, HI-7, HI-11: page trees readers would number differently

    func tree(_ kids: String, count: Int, extra: [(Int, String)] = [], xrefNums: [Int]? = nil) -> [UInt8] {
        var b = PDFBuilder(version: "1.4")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [\(kids)] /Count \(count) >>")
        for (n, body) in extra { b.obj(n, body) }
        b.classicXRef(nums: xrefNums ?? ([1, 2] + extra.map(\.0)), trailer: "<< /Size 30 /Root 1 0 R >>")
        return b.bytes
    }

    @Test func damagedPageTreesAreRefused() throws {
        let page = "<< /Type /Page /Parent 2 0 R >>"
        let cases: [(String, [UInt8], String)] = [
            ("cycle", tree("3 0 R 5 0 R", count: 2, extra: [(3, page), (5, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>")]), "cycle"),
            ("self kid", tree("3 0 R 2 0 R", count: 2, extra: [(3, page)]), "cycle"),
            ("count mismatch", tree("3 0 R 4 0 R 5 0 R", count: 2, extra: [(3, page), (4, page), (5, page)]), "/Count"),
            ("missing kid", tree("3 0 R 99 0 R 4 0 R", count: 3, extra: [(3, page), (4, page)]), "missing"),
            ("direct kid", tree("3 0 R << /Type /Page >> 4 0 R", count: 3, extra: [(3, page), (4, page)]), "indirect"),
            ("page twice", tree("3 0 R 4 0 R 3 0 R", count: 3, extra: [(3, page), (4, page)]), "appears twice"),
        ]
        for (label, bytes, message) in cases {
            do {
                _ = try Mulu.apply(pdf: bytes, tocText: "A 1", offset: 0)
                Issue.record("\(label): expected a refusal")
            } catch let e as MuluError {
                #expect("\(e)".contains(message), "\(label): \(e)")
            }
        }
        // A consistent tree with nested nodes still works.
        let ok = tree("3 0 R 5 0 R", count: 3, extra: [(3, page), (5, "<< /Type /Pages /Parent 2 0 R /Kids [6 0 R 7 0 R] /Count 2 >>"),
                                                    (6, "<< /Type /Page /Parent 5 0 R >>"), (7, "<< /Type /Page /Parent 5 0 R >>")])
        #expect(try PDFFile(bytes: ok).pageRefs() == [ObjRef(3, 0), ObjRef(6, 0), ObjRef(7, 0)])
    }

    @Test func offsetZeroEntryHidesOlderDefinition() throws {
        // Revision 2 marks page 4 "in use at offset 0": no object, like qpdf and pdf.js read it.
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 2)
        let first = b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R >>")
        let start = b.bytes.count
        b.add("xref\n0 1\n0000000000 65535 f\r\n4 1\n0000000000 00000 n\r\ntrailer\n<< /Size 6 /Root 1 0 R /Prev \(first) >>\nstartxref\n\(start)\n%%EOF\n")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(try doc.resolve(ObjRef(4, 0)) == .null)
        #expect(throws: MuluError.self) { try doc.pageRefs() }
    }

    // MARK: HI-8: entries Mulu repairs are republished

    @Test func repairedOffsetIsRepublished() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 2)
        let real = b.offsets[4]!.offset
        b.offsets[4]!.offset = 999_999  // beyond EOF
        b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(try doc.pageRefs() == [ObjRef(3, 0), ObjRef(4, 0)])
        #expect(doc.repairedEntries[4] == .inUse(offset: real, gen: 0))
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 2", offset: 0)
        #expect(try newestRows(r.output)[4] == .inUse(offset: real, gen: 0))
        let out = try PDFFile(bytes: r.output)
        _ = try out.pageRefs()
        #expect(out.repairedEntries.isEmpty)
    }

    @Test func renumberedTableIsRepublished() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 1)
        let start = b.bytes.count
        b.add("xref\n1 5\n0000000000 65535 f\r\n")
        for n in 1...4 { b.add(pad(b.offsets[n]!.offset, 10) + " 00000 n\r\n") }
        b.add("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n")
        #expect(try PDFFile(bytes: b.bytes).usedRenumberingFix)
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0)
        let rows = try newestRows(r.output)
        for n in 2...4 { #expect(rows[n] == .inUse(offset: b.offsets[n]!.offset, gen: 0)) }
    }

    // MARK: HI-9: deep nesting is skipped, not fatal, unless the object must be rewritten

    @Test func deeplyNestedPageIsFineButNestedCatalogIsRefused() throws {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        var p = PDFBuilder(version: "1.4")
        p.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        p.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        p.obj(3, "<< /Type /Page /Parent 2 0 R /PieceInfo \(deep) >>")
        p.classicXRef(nums: [1, 2, 3], trailer: "<< /Size 4 /Root 1 0 R >>")
        _ = try Mulu.apply(pdf: p.bytes, tocText: "A 1", offset: 0)

        var c = PDFBuilder(version: "1.4")
        c.obj(1, "<< /Type /Catalog /Pages 2 0 R /X \(deep) >>")
        c.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        c.obj(3, "<< /Type /Page /Parent 2 0 R >>")
        c.classicXRef(nums: [1, 2, 3], trailer: "<< /Size 4 /Root 1 0 R >>")
        #expect(try PDFFile(bytes: c.bytes).pageRefs().count == 1)  // readable...
        do {
            _ = try Mulu.apply(pdf: c.bytes, tocText: "A 1", offset: 0)
            Issue.record("expected a refusal")
        } catch let e as MuluError {
            #expect("\(e)".contains("nests arrays or dictionaries more than"))  // ...but not rewritable
        }
    }

    @Test func closedDeepNestingParsesAsTruncated() throws {
        let s = "[1 " + String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000) + " 2]"
        var p = Parser(lexer: Lexer(Array(s.utf8)))
        guard case .array(let a) = try p.parseObject() else { Issue.record("not an array"); return }
        #expect(a.first == .int(1) && a.last == .int(2))
        #expect(p.truncated)
    }

    // MARK: HI-10: stray free entries with huge numbers do not block apply

    @Test func strayHugeFreeEntryIsIgnored() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 2)
        let start = b.bytes.count
        b.add("xref\n0 6\n0000000000 65535 f\r\n")
        for n in 1...5 { b.add(pad(b.offsets[n]!.offset, 10) + " 00000 n\r\n") }
        b.add("9000000000 1\n0000000000 00001 f\r\n")
        b.add("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n")
        #expect(try PDFFile(bytes: b.bytes).nextObjectNumber == 6)
        _ = try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0)
    }

    // MARK: HI-12: hybrid conflicts are named; LZW and RunLength decode

    @Test func hybridTableFreeVersusStreamIsNamed() throws {
        var b = PDFBuilder(version: "1.5")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(3, "<< /Type /Page /Parent 2 0 R >>")
        let o2 = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        b.stream(10, dict: "/Type /ObjStm /N 1 /First 4", data: Array("2 0 \(o2)".utf8))
        b.xrefStream(num: 11, rows: [2: (2, 10, 0)], trailerKeys: "", size: 12, writeStartxref: false)
        let hidden = b.offsets[11]!.offset
        b.classicXRef(nums: [1, 3, 10], free: [2], trailer: "<< /Size 12 /Root 1 0 R /XRefStm \(hidden) >>")
        do {
            _ = try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0)
            Issue.record("expected a refusal")
        } catch let e as MuluError {
            #expect("\(e)".contains("hybrid xref table marks object 2 free"))
        }
    }

    @Test func lzwAndRunLength() throws {
        // ISO 32000-1 §7.4.4.2 example: "-----A---B".
        let lzw: [UInt8] = [0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01]
        #expect(try Filters.lzwDecode(lzw, earlyChange: true) == Array("-----A---B".utf8))
        #expect(try Filters.runLengthDecode([2, 0x41, 0x42, 0x43, 0xFE, 0x44, 0x80]) == Array("ABCDDD".utf8))
    }

    @Test func decompressionIsCapped() throws {
        let bomb = Filters.zlibCompress([UInt8](repeating: 0, count: Filters.maxDecodedSize + 1))
        #expect(throws: MuluError.self) { try Filters.flateDecode(bomb) }
    }

    // MARK: PM-1: full-width space indentation

    @Test func fullWidthSpaceIndentation() throws {
        let toc = try TOCParser.parse("第一章 1\n\u{3000}第一节 2\n\u{3000}\u{3000}一、定义 3\n\t\u{3000}混合 4\n")
        #expect(toc.map(\.level) == [0, 1, 2, 2])
        #expect(toc.map(\.title) == ["第一章", "第一节", "一、定义", "混合"])
        do {
            _ = try TOCParser.parse("A 1\n\u{00A0}B 2\n")
            Issue.record("expected a refusal")
        } catch let e as MuluError {
            #expect("\(e)".contains("line 2: indentation uses U+00A0"))
        }
    }
}
