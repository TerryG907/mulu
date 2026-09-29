import Foundation
import Testing
@testable import MuluCore

@Suite struct XRefTests {
    @Test func classicXRef() throws {
        let doc = try PDFFile(bytes: Fixtures.classic(pages: 3))
        #expect(doc.xrefKind == .classic)
        #expect(doc.revisionCount == 1)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs() == [ObjRef(3, 0), ObjRef(4, 0), ObjRef(5, 0)])
        #expect(doc.objectCount == 6)
        #expect(doc.nextObjectNumber == 7)
        let info = doc.info()
        #expect(info == DocumentInfo(xref: "classic", revisions: 1, objects: 6, pages: 3, encrypted: false,
                                     hasOutline: false, linearized: false, size: doc.bytes.count))
    }

    @Test func xrefStreamWithPNGUpPredictor() throws {
        let bytes = Fixtures.xrefStream(pages: 4, pngFilters: [2])
        let doc = try PDFFile(bytes: bytes)
        #expect(doc.xrefKind == .stream)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 4)
        #expect(doc.entries[0] == .free)
        #expect(doc.trailer["Info"] == .ref(ObjRef(7, 0)))
        guard case .inUse(let off, 0)? = doc.entries[3] else { Issue.record("entry 3"); return }
        #expect(bytes.matches(Array("3 0 obj".utf8), at: off))
    }

    @Test func xrefStreamWithEveryPNGFilterType() throws {
        let doc = try PDFFile(bytes: Fixtures.xrefStream(pages: 9, pngFilters: [0, 1, 2, 3, 4]))
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 9)
    }

    @Test func uncompressedXRefStreamWithWideFields() throws {
        var b = PDFBuilder(version: "1.5")
        Fixtures.pageObjects(&b, pages: 2)
        var rows: [Int: (Int, Int, Int)] = [:]
        for k in 1...5 { rows[k] = (1, b.offsets[k]!.offset, 0) }
        b.xrefStream(num: 6, rows: rows, trailerKeys: "/Root 1 0 R", pngFilters: nil, compress: false, w: (2, 8, 3))
        let doc = try PDFFile(bytes: b.bytes)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 2)
    }

    @Test func xrefStreamWithIndirectLength() throws {
        var b = PDFBuilder(version: "1.5")
        Fixtures.pageObjects(&b, pages: 2)
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535)]
        for k in 1...5 { rows[k] = (1, b.offsets[k]!.offset, 0) }
        b.xrefStream(num: 7, rows: rows, trailerKeys: "/Root 1 0 R", pngFilters: nil, compress: false, lengthObject: 6)
        let doc = try PDFFile(bytes: b.bytes)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 2)
        // /Length 6 0 R could not be resolved while the xref was being read; the value
        // cached then must not leak into later lookups.
        #expect(try doc.resolve(ObjRef(6, 0)) == .int(8 * 7))
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 2", offset: 0)
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [1])
    }

    @Test func objectStreamHoldingTheCatalog() throws {
        let doc = try PDFFile(bytes: Fixtures.objectStreamCatalog(pages: 3))
        #expect(doc.xrefKind == .stream)
        #expect(doc.entries[1] == .compressed(stream: 100, index: 0))
        let cat = try #require(try doc.catalog())
        #expect(cat["Lang"] == .string(Array("en-US".utf8)))
        #expect(try doc.pageRefs() == [ObjRef(3, 0), ObjRef(4, 0), ObjRef(5, 0)])
    }

    /// Revision 1 defines objects 1-6; revision 2 rewrites the catalog and frees 5.
    static func twoRevisions(encryptInOld: Bool = false) -> (bytes: [UInt8], firstXRef: Int, secondXRef: Int) {
        var b = PDFBuilder(version: "1.4")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
        b.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
        b.obj(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
        b.obj(5, "<< /Marker (old) >>")
        b.obj(6, "<< /Producer (rev1) >>")
        let enc = encryptInOld ? " /Encrypt 5 0 R" : ""
        let x1 = b.classicXRef(nums: [1, 2, 3, 4, 5, 6], trailer: "<< /Size 7 /Root 1 0 R /Info 6 0 R\(enc) >>")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R /Lang (de) >>")
        let x2 = b.classicXRef(nums: [1], free: [5], includeZero: false, trailer: "<< /Size 7 /Root 1 0 R /Info 6 0 R /Prev \(x1) >>")
        return (b.bytes, x1, x2)
    }

    @Test func prevChainNewestWinsAndFreeEntriesAreHonoured() throws {
        let (bytes, _, x2) = XRefTests.twoRevisions()
        let doc = try PDFFile(bytes: bytes)
        #expect(doc.revisionCount == 2)
        #expect(doc.startXRef == x2)
        #expect(doc.entries[5] == .free)
        #expect(try doc.resolve(ObjRef(5, 0)) == .null)
        #expect(try doc.catalog()?["Lang"] == .string(Array("de".utf8)))
        #expect(try doc.pageRefs().count == 2)
        #expect(doc.info().objects == 5)
    }

    @Test func hybridReferenceFile() throws {
        var b = PDFBuilder(version: "1.5")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        for i in 3...5 { b.obj(i, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>") }
        let o2 = "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"
        b.stream(20, dict: "/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode", data: Filters.zlibCompress(Array(("2 0 " + o2).utf8)))
        // Hidden xref stream: only object 2 (compressed in 20).
        let xs = b.xrefStream(num: 21, rows: [2: (2, 20, 0)], trailerKeys: "", size: 22, pngFilters: [2], writeStartxref: false)
        // The classic table does not mention object 2 at all.
        b.classicXRef(nums: [1, 3, 4, 5, 20, 21], trailer: "<< /Size 22 /Root 1 0 R /XRefStm \(xs) >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(doc.xrefKind == .hybrid)
        #expect(doc.entries[2] == .compressed(stream: 20, index: 0))
        #expect(try doc.pageRefs().count == 3)

        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 1\nB 3\n", offset: 0)
        let appended = String(decoding: r.output[b.bytes.count...], as: UTF8.self)
        #expect(appended.contains("\nxref\n"))
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [0, 2])
    }

    @Test func encryptedTrailerIsDetectedInAnyRevision() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 1)
        b.obj(5, "<< /Filter /Standard /V 1 /R 2 /O <00> /U <00> /P -4 >>")
        b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R /Encrypt 5 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(doc.isEncrypted)
        #expect(throws: MuluError.encrypted) { try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0) }

        let (older, _, _) = XRefTests.twoRevisions(encryptInOld: true)
        #expect(try PDFFile(bytes: older).isEncrypted)
        #expect(throws: MuluError.encrypted) { try Mulu.apply(pdf: older, tocText: "A 1", offset: 0) }
    }

    @Test func crOnlyLineEndingsAndTrailingGarbage() throws {
        let crOnly = Fixtures.classic(pages: 2).map { $0 == 0x0A ? 0x0D : $0 }
        var doc = try PDFFile(bytes: crOnly)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 2)

        let garbage = Fixtures.classic(pages: 2) + [0, 0, 0] + Array("junk after eof\r\n  \u{01}".utf8)
        doc = try PDFFile(bytes: garbage)
        #expect(!doc.isReconstructed)
        let r = try Mulu.apply(pdf: garbage, tocText: "Only 2", offset: 0)
        #expect(Array(r.output[0..<garbage.count]) == garbage)
        #expect(r.output[garbage.count] == 0x0A)  // the input did not end in an EOL
    }

    @Test func wrongStartxrefFallsBackToUnambiguousReconstruction() throws {
        let bytes = withStartxref(Fixtures.classic(pages: 3)) { $0 + 7 }
        let doc = try PDFFile(bytes: bytes)
        #expect(doc.isReconstructed)
        #expect(try doc.pageRefs().count == 3)

        let r = try Mulu.apply(pdf: bytes, tocText: "One 1\n\tTwo 2\nThree 3", offset: 0)
        let out = try PDFFile(bytes: r.output)
        #expect(!out.isReconstructed)
        #expect(out.trailer["Prev"] == nil)  // the new section is complete
        #expect(try out.readOutline() == [
            OutlineItemInfo(title: "One", level: 0, pageIndex: 0),
            OutlineItemInfo(title: "Two", level: 1, pageIndex: 1),
            OutlineItemInfo(title: "Three", level: 0, pageIndex: 2),
        ])
    }

    @Test func ambiguousReconstructionIsRefused() throws {
        let broken = withStartxref(XRefTests.twoRevisions().bytes) { $0 + 3 }
        #expect(throws: MuluError.self) { try PDFFile(bytes: broken) }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: broken, tocText: "A 1", offset: 0) }
    }

    @Test func wrongObjectOffsetIsRepairedWhenUnique() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 2)
        b.offsets[4]!.offset += 3  // points into the middle of "4 0 obj"
        b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs() == [ObjRef(3, 0), ObjRef(4, 0)])
    }

    @Test func indirectAndWrongStreamLengths() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 1)
        let payload = Array("BT /F1 12 Tf (hello world) Tj ET".utf8)
        b.offsets[6] = (b.bytes.count, 0)
        b.add("6 0 obj\n<< /Length 7 0 R >>\nstream\n")
        b.add(payload)
        b.add("\nendstream\nendobj\n")
        b.obj(7, "\(payload.count)")
        b.offsets[8] = (b.bytes.count, 0)
        b.add("8 0 obj\n<< /Length 3 >>\nstream\r\n")  // wrong /Length: must fall back to endstream
        b.add(payload)
        b.add("\r\nendstream\nendobj\n")
        b.classicXRef(nums: [1, 2, 3, 4, 6, 7, 8], trailer: "<< /Size 9 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        guard case .stream(let s6) = try doc.resolve(ObjRef(6, 0)),
              case .stream(let s8) = try doc.resolve(ObjRef(8, 0))
        else { Issue.record("not streams"); return }
        #expect(try doc.decodeStream(s6) == payload)
        #expect(try doc.decodeStream(s8) == payload)
    }

    @Test func offByOneFirstSubsectionIsCorrected() throws {
        var b = PDFBuilder(version: "1.4")
        Fixtures.pageObjects(&b, pages: 1)
        let start = b.bytes.count
        b.add("xref\n1 5\n0000000000 65535 f\r\n")
        for n in 1...4 { b.add(pad(b.offsets[n]!.offset, 10) + " 00000 n\r\n") }
        b.add("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(!doc.isReconstructed)
        #expect(try doc.pageRefs().count == 1)
    }

    @Test func pageTreeCyclesAndNesting() throws {
        var b = PDFBuilder(version: "1.4")
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        b.obj(2, "<< /Type /Pages /Kids [3 0 R 6 0 R 2 0 R] /Count 3 >>")  // 2 lists itself
        b.obj(3, "<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>")
        b.obj(4, "<< /Type /Page /Parent 3 0 R >>")
        b.obj(5, "<< /Type /Page /Parent 3 0 R >>")
        b.obj(6, "<< /Type /Page /Parent 2 0 R >>")
        b.classicXRef(nums: Array(1...6), trailer: "<< /Size 7 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        // Readers disagree about cyclic trees (qpdf and pypdf refuse them), so Mulu refuses.
        #expect(throws: MuluError.self) { try doc.pageRefs() }
        #expect(throws: MuluError.self) { try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0) }
    }

    @Test func junkBeforeHeaderWithHeaderRelativeOffsets() throws {
        let junk = Array("JUNK-BEFORE-HEADER\r\n0123456789 obj junk\n".utf8)
        let input = junk + Fixtures.classic(pages: 3)  // offsets are now relative to "%PDF-"
        let doc = try PDFFile(bytes: input)
        #expect(!doc.isReconstructed)
        #expect(doc.offsetBase == junk.count)
        #expect(try doc.pageRefs().count == 3)
        let r = try Mulu.apply(pdf: input, tocText: "A 1\nB 3", offset: 0)
        let out = try PDFFile(bytes: r.output)
        #expect(!out.isReconstructed)
        #expect(out.offsetBase == junk.count)  // the update follows the file's convention
        #expect(try out.readOutline().map(\.pageIndex) == [0, 2])
    }

    @Test func junkBeforeHeaderWithAbsoluteOffsets() throws {
        var b = PDFBuilder(version: "1.4")
        b.bytes = Array("garbage\n".utf8) + b.bytes
        Fixtures.pageObjects(&b, pages: 2)
        b.classicXRef(nums: [1, 2, 3, 4, 5], trailer: "<< /Size 6 /Root 1 0 R >>")
        let doc = try PDFFile(bytes: b.bytes)
        #expect(doc.offsetBase == 0)
        #expect(!doc.isReconstructed)
        let r = try Mulu.apply(pdf: b.bytes, tocText: "A 2", offset: 0)
        #expect(try PDFFile(bytes: r.output).readOutline().map(\.pageIndex) == [1])
    }

    @Test func notAPDF() {
        #expect(throws: MuluError.notPDF) { try PDFFile(bytes: Array("hello world".utf8)) }
        #expect(throws: MuluError.notPDF) { try PDFFile(bytes: []) }
    }

    @Test func linearizationDictionaryIsDetected() throws {
        var b = PDFBuilder(version: "1.4")
        b.obj(9, "<< /Linearized 1 /L @@@@@@@@@@ /O 3 /E 100 /N 1 /T 900 /H [0 0] >>")
        Fixtures.pageObjects(&b, pages: 1)
        b.classicXRef(nums: [1, 2, 3, 4, 9], trailer: "<< /Size 10 /Root 1 0 R >>")
        let at = try #require(b.bytes.firstIndex(of: Array("@@@@@@@@@@".utf8), from: 0))
        b.bytes.replaceSubrange(at..<(at + 10), with: Array(pad(b.bytes.count, 10).utf8))
        #expect(try PDFFile(bytes: b.bytes).isLinearized)
        #expect(try !PDFFile(bytes: Fixtures.classic(pages: 1)).isLinearized)
        // After an incremental update /L no longer matches: no longer linearized.
        let updated = try Mulu.apply(pdf: b.bytes, tocText: "A 1", offset: 0).output
        #expect(try !PDFFile(bytes: updated).isLinearized)
    }
}
