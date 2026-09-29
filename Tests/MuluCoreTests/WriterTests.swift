import Foundation
import Testing
@testable import MuluCore

let sampleTOC = """
    # comment line
    Preface 1
    Part I: Foundations 2
    \tChapter 1 — 基础 2
    \t\tSection 1.1 🎉 3
    \tChapter 2 3

    Appendix A 4
    """

let sampleExpected: [OutlineItemInfo] = [
    OutlineItemInfo(title: "Preface", level: 0, pageIndex: 0),
    OutlineItemInfo(title: "Part I: Foundations", level: 0, pageIndex: 1),
    OutlineItemInfo(title: "Chapter 1 — 基础", level: 1, pageIndex: 1),
    OutlineItemInfo(title: "Section 1.1 🎉", level: 2, pageIndex: 2),
    OutlineItemInfo(title: "Chapter 2", level: 1, pageIndex: 2),
    OutlineItemInfo(title: "Appendix A", level: 0, pageIndex: 3),
]

func fixture(_ name: String) -> [UInt8] {
    switch name {
    case "classic": return Fixtures.classic(pages: 4)
    case "stream": return Fixtures.xrefStream(pages: 4, pngFilters: [2])
    case "objstm": return Fixtures.objectStreamCatalog(pages: 4)
    default: fatalError(name)
    }
}

/// Checks the outline dictionaries themselves: /Parent, /Prev, /Next, /First, /Last
/// and /Count (all items open: /Count = number of descendants).
func verifyOutlineStructure(_ doc: PDFFile) throws {
    let cat = try #require(try doc.catalog())
    #expect(cat["PageMode"] == .name("UseOutlines"))
    let rootRef = try #require(cat["Outlines"]?.refValue)
    guard case .dict(let root) = try doc.resolve(rootRef) else { Issue.record("no outline root"); return }
    #expect(root["Type"] == .name("Outlines"))

    func check(_ parentRef: ObjRef, _ d: PDFDict) throws -> Int {
        var cur = d["First"]?.refValue
        var prev: ObjRef? = nil
        var total = 0
        while let c = cur {
            guard case .dict(let item) = try doc.resolve(c) else { Issue.record("item \(c) missing"); return total }
            #expect(item["Parent"] == .ref(parentRef))
            #expect(item["Prev"]?.refValue == prev)
            let title = try #require(item["Title"]?.stringBytes)
            #expect(Array(title.prefix(2)) == [0xFE, 0xFF])
            let dest = try #require(item["Dest"]?.arrayValue)
            #expect(dest.count == 5 && dest[1] == .name("XYZ") && dest[2] == .null)
            let descendants = try check(c, item)
            if descendants > 0 {
                #expect(item["Count"] == .int(descendants))
            } else {
                #expect(item["Count"] == nil && item["First"] == nil && item["Last"] == nil)
            }
            total += 1 + descendants
            prev = c
            cur = item["Next"]?.refValue
        }
        #expect(d["Last"]?.refValue == prev)
        return total
    }
    let total = try check(rootRef, root)
    #expect(root["Count"] == .int(total))
}

@Suite struct WriterTests {
    @Test(arguments: ["classic", "stream", "objstm"])
    func applyAppendsAndReadsBack(_ name: String) throws {
        let input = fixture(name)
        let original = try PDFFile(bytes: input)
        let r = try Mulu.apply(pdf: input, tocText: sampleTOC, offset: 0)

        // (a) prefix property
        #expect(Array(r.output[0..<input.count]) == input)
        #expect(r.appendedByteCount == r.output.count - input.count)

        let out = try PDFFile(bytes: r.output)
        #expect(!out.isReconstructed)
        #expect(out.revisionCount == original.revisionCount + 1)
        #expect(out.xrefKind == original.xrefKind)  // xref stream in, xref stream out
        #expect(out.trailer["Prev"] == .int(original.startXRef))
        #expect(out.trailer["Root"] == original.trailer["Root"])
        #expect(out.trailer["Info"] == original.trailer["Info"])
        #expect(out.trailer["ID"] == original.trailer["ID"])
        #expect(out.trailer["Size"] == .int(out.nextObjectNumber))
        #expect(try out.pageRefs() == original.pageRefs())
        #expect(try out.readOutline() == sampleExpected)
        try verifyOutlineStructure(out)

        // The new catalog revision keeps every original key.
        let before = try #require(try original.catalog())
        let after = try #require(try out.catalog())
        for key in before.keys { #expect(after[key] == before[key], "catalog key /\(key)") }
        #expect(Set(after.keys) == Set(before.keys).union(["Outlines", "PageMode"]))
        #expect(try original.readOutline() == [])
    }

    @Test(arguments: ["classic", "stream", "objstm"])
    func reapplyReplacesOutlineAndKeepsPrefix(_ name: String) throws {
        let input = fixture(name)
        let first = try Mulu.apply(pdf: input, tocText: sampleTOC, offset: 0).output
        let second = try Mulu.apply(pdf: first, tocText: "Only one\t4\n  Child 1", offset: 0).output
        #expect(Array(second[0..<first.count]) == first)
        #expect(Array(second[0..<input.count]) == input)
        let doc = try PDFFile(bytes: second)
        #expect(try doc.readOutline() == [
            OutlineItemInfo(title: "Only one", level: 0, pageIndex: 3),
            OutlineItemInfo(title: "Child", level: 1, pageIndex: 0),
        ])
        try verifyOutlineStructure(doc)
        #expect(doc.revisionCount == (try PDFFile(bytes: input).revisionCount) + 2)

        // A third, empty TOC removes the outline again.
        let third = try Mulu.apply(pdf: second, tocText: "# nothing here\n\n", offset: 0).output
        let cleared = try PDFFile(bytes: third)
        #expect(try cleared.readOutline() == [])
        #expect(try cleared.catalog()?["Outlines"] == nil)
        #expect(try cleared.catalog()?["PageMode"] == nil)
        #expect(!cleared.hasOutlineItems())
    }

    @Test func prevChainFileGetsUpdatedCorrectly() throws {
        let (input, _, x2) = XRefTests.twoRevisions()
        let r = try Mulu.apply(pdf: input, tocText: "A 1\nB 2", offset: 0)
        let out = try PDFFile(bytes: r.output)
        #expect(out.trailer["Prev"] == .int(x2))
        #expect(out.revisionCount == 3)
        #expect(try out.catalog()?["Lang"] == .string(Array("de".utf8)))
        #expect(try out.resolve(ObjRef(5, 0)) == .null)
        #expect(out.entries[5] == .free)
        // new objects start at the original /Size (7)
        #expect(try out.catalog()?["Outlines"] == .ref(ObjRef(7, 0)))
    }

    @Test func offsetMapsPrintedPagesToPhysicalPages() throws {
        let input = Fixtures.classic(pages: 10)
        var r = try Mulu.apply(pdf: input, tocText: "Intro 1\nBody 5", offset: 3)
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [3, 7])
        r = try Mulu.apply(pdf: input, tocText: "Last 10", offset: -9)
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [0])
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: input, tocText: "X 8", offset: 3) }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: input, tocText: "X 1", offset: -1) }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: input, tocText: "X 1", offset: Int.max) }
    }

    @Test func refusals() throws {
        // zero pages
        var b = PDFBuilder()
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [] /Count 0 >>")
        b.classicXRef(nums: [1, 2], trailer: "<< /Size 3 /Root 1 0 R >>")
        #expect(throws: MuluError.zeroPages) { try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0) }

        // no /Root
        b = PDFBuilder()
        Fixtures.pageObjects(&b, pages: 1)
        b.classicXRef(nums: [1, 2, 3, 4], trailer: "<< /Size 5 >>")
        #expect(throws: MuluError.noRoot) { try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0) }

        // /Root that is not a dictionary
        b = PDFBuilder()
        Fixtures.pageObjects(&b, pages: 1)
        b.classicXRef(nums: [1, 2, 3, 4], trailer: "<< /Size 5 /Root 9 0 R >>")
        #expect(throws: MuluError.noRoot) { try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0) }

        let good = Fixtures.classic(pages: 3)
        #expect(throws: MuluError.pageOutOfRange(line: 2, page: 4, physical: 4, pageCount: 3)) {
            try Mulu.apply(pdf: good, tocText: "A 1\nB 4", offset: 0)
        }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: good, tocText: "\tIndented first 1", offset: 0) }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: good, tocText: "A 1\n\t\tToo deep 2", offset: 0) }

        // garbage / unparseable xref
        #expect(throws: MuluError.self) {
            try Mulu.apply(pdf: Array("%PDF-1.4\nnothing to see\n%%EOF\n".utf8), tocText: "A 1", offset: 0)
        }
    }

    /// The appended classic table starts with object 0 (pypdf otherwise treats the
    /// table as mis-numbered and may rebuild the whole map), and object 0's entry
    /// repeats the original free-list head unchanged.
    @Test func classicUpdateStartsWithObjectZeroAndKeepsFreeListHead() throws {
        var b = PDFBuilder()
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        b.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
        let x = b.bytes.count
        b.add("xref\n0 5\n0000000004 65535 f\r\n")
        for n in 1...3 { b.add(pad(b.offsets[n]!.offset, 10) + " 00000 n\r\n") }
        b.add("0000000000 00001 f\r\ntrailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(x)\n%%EOF\n")
        #expect(try PDFFile(bytes: b.bytes).freeListHead == 4)

        let first = try Mulu.apply(pdf: b.bytes, tocText: "Only 1", offset: 0).output
        let second = try Mulu.apply(pdf: first, tocText: "Again 1", offset: 0).output
        for (prefix, output) in [(b.bytes, first), (first, second)] {
            let appended = String(decoding: output[prefix.count...], as: UTF8.self)
            let table = try #require(appended.range(of: "\nxref\n"))
            // Rows 0 (free-list head) and 1 (the new catalog revision) form one run.
            #expect(appended[table.upperBound...].hasPrefix("0 2\n0000000004 65535 f\r\n"))
            let doc = try PDFFile(bytes: output)
            #expect(doc.freeListHead == 4)
            #expect(doc.entries[0] == .free)
            #expect(doc.entries[4] == .free)
        }
        #expect(try PDFFile(bytes: second).readOutline() == [OutlineItemInfo(title: "Again", level: 0, pageIndex: 0)])

        // An xref-stream file keeps its own /Index (no classic-table heuristic applies).
        let s = try Mulu.apply(pdf: Fixtures.xrefStream(pages: 2), tocText: "S 1", offset: 0).output
        #expect(try PDFFile(bytes: s).xrefKind == .stream)
    }

    @Test func catalogWithNonZeroGeneration() throws {
        var b = PDFBuilder()
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R /PageMode /UseThumbs >>", gen: 3)
        b.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        b.obj(3, "<< /Type /Page /Parent 2 0 R >>")
        b.classicXRef(nums: [1, 2, 3], trailer: "<< /Size 4 /Root 1 3 R >>")
        let r = try Mulu.apply(pdf: b.bytes, tocText: "Only 1", offset: 0)
        let appended = String(decoding: r.output[b.bytes.count...], as: UTF8.self)
        #expect(appended.contains("\n1 3 obj\n"))
        let out = try PDFFile(bytes: r.output)
        let header = try #require(appended.range(of: "\n1 3 obj\n"))
        let expectedOffset = b.bytes.count + appended.utf8.distance(from: appended.startIndex, to: header.lowerBound) + 1
        #expect(out.entries[1] == .inUse(offset: expectedOffset, gen: 3))
        #expect(try out.readOutline() == [OutlineItemInfo(title: "Only", level: 0, pageIndex: 0)])
        #expect(try out.catalog()?["PageMode"] == .name("UseOutlines"))
    }

    @Test func readsNamedDestinationsActionsAndIntegerPages() throws {
        var b = PDFBuilder()
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /Dests << /chap1 [4 0 R /Fit] >> /Names << /Dests 20 0 R >> >>")
        b.obj(2, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>")
        for i in 3...5 { b.obj(i, "<< /Type /Page /Parent 2 0 R >>") }
        b.obj(10, "<< /Type /Outlines /First 11 0 R /Last 13 0 R /Count 4 >>")
        b.obj(11, "<< /Title (A\\223) /Parent 10 0 R /Next 12 0 R /Dest /chap1 >>")
        b.obj(12, "<< /Title <FEFF0042> /Parent 10 0 R /Prev 11 0 R /Next 13 0 R /A << /S /GoTo /D (sec2) >> >>")
        b.obj(13, "<< /Title (C) /Parent 10 0 R /Prev 12 0 R /First 14 0 R /Last 14 0 R /Count 1 /Dest [3 0 R /Fit] >>")
        b.obj(14, "<< /Title (D) /Parent 13 0 R /Dest [0 /Fit] /Next 14 0 R >>")  // self-loop must not hang
        b.obj(20, "<< /Kids [21 0 R] >>")
        b.obj(21, "<< /Limits [(a) (z)] /Names [(sec1) [3 0 R /Fit] (sec2) << /D [5 0 R /XYZ 0 0 0] >>] >>")
        b.classicXRef(nums: [1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 20, 21], trailer: "<< /Size 22 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(try doc.readOutline() == [
            OutlineItemInfo(title: "A\u{FB01}", level: 0, pageIndex: 1),
            OutlineItemInfo(title: "B", level: 0, pageIndex: 2),
            OutlineItemInfo(title: "C", level: 0, pageIndex: 0),
            OutlineItemInfo(title: "D", level: 1, pageIndex: 0),
        ])
        #expect(doc.info().hasOutline)
    }

    @Test func fiveHundredPagesUnderOneSecond() throws {
        let input = Fixtures.classic(pages: 500)
        var lines: [String] = []
        for p in 1...500 {
            let level = p % 10 == 1 ? 0 : (p % 10 == 2 ? 1 : (p % 2 == 0 ? 1 : 2))
            lines.append(String(repeating: "\t", count: level) + "Entry \(p) 标题 \(p)")
        }
        let toc = lines.joined(separator: "\n")
        let clock = ContinuousClock()
        var result: ApplyResult? = nil
        let elapsed = try clock.measure { result = try Mulu.apply(pdf: input, tocText: toc, offset: 0) }
        #expect(result?.itemCount == 500)
        #expect(elapsed < .seconds(1), "apply took \(elapsed)")
    }
}

/// Writes the in-memory fixtures and their updated versions to $MULU_DUMP_FIXTURES
/// (when set) so external readers can be pointed at them. No-op otherwise.
@Suite struct FixtureDump {
    @Test func dumpWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["MULU_DUMP_FIXTURES"] else { return }
        var cases: [(String, [UInt8])] = [
            ("classic", fixture("classic")), ("stream", fixture("stream")), ("objstm", fixture("objstm")),
            ("two_revisions", XRefTests.twoRevisions().bytes),
            ("broken_startxref", withStartxref(Fixtures.classic(pages: 4)) { $0 + 7 }),
            ("junk_prefix", Array("JUNK\r\n".utf8) + Fixtures.classic(pages: 4)),
        ]
        var b = PDFBuilder(version: "1.5")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        for i in 3...6 { b.obj(i, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>") }
        let o2 = "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>"
        b.stream(20, dict: "/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode", data: Filters.zlibCompress(Array(("2 0 " + o2).utf8)))
        let xs = b.xrefStream(num: 21, rows: [2: (2, 20, 0)], trailerKeys: "", size: 22, pngFilters: [4, 3, 1], writeStartxref: false)
        b.classicXRef(nums: [1, 3, 4, 5, 6, 20, 21], trailer: "<< /Size 22 /Root 1 0 R /XRefStm \(xs) >>")
        cases.append(("hybrid", b.bytes))
        for (name, bytes) in cases {
            let pages = try PDFFile(bytes: bytes).pageRefs().count
            let toc = pages >= 4 ? sampleTOC : "Alpha 1\n\tBeta \(pages)\n"
            let out = try Mulu.apply(pdf: bytes, tocText: toc, offset: 0).output
            try Data(bytes).write(to: URL(fileURLWithPath: "\(dir)/\(name).pdf"))
            try Data(out).write(to: URL(fileURLWithPath: "\(dir)/\(name).out.pdf"))
        }
    }
}
