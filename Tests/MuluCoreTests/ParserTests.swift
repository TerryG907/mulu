import Foundation
import Testing
@testable import MuluCore

@Suite struct LexerParserTests {
    func parse(_ s: String) throws -> PDFObject {
        var p = Parser(lexer: Lexer(Array(s.utf8)))
        return try p.parseObject()
    }

    @Test func literalStringsEscapesAndNesting() throws {
        let o = try parse(#"(a\(b\)c (nested) \101\102\7 \n\\ line\#ncont)"#)
        let expected: [UInt8] = Array("a(b)c (nested) AB".utf8) + [7, 0x20, 0x0A, 0x5C] + Array(" line\ncont".utf8)
        #expect(o == .string(expected))
        // Backslash-EOL is a continuation; an unescaped CRLF reads as LF.
        #expect(try parse("(ab\\\r\ncd\r\nef)") == .string(Array("abcd\nef".utf8)))
    }

    @Test func hexStringsNamesNumbers() throws {
        #expect(try parse("<48 65 6c6C 6>") == .string([0x48, 0x65, 0x6C, 0x6C, 0x60]))
        #expect(try parse("/A#20B#2f") == .name("A B/"))
        #expect(try parse("-.5") == .real(-0.5, "-0.5"))
        #expect(try parse("+17") == .int(17))
        #expect(try parse("--3") == .int(-3))
        #expect(try parse("4.") == .real(4, "4.0"))
    }

    @Test func dictionariesArraysAndReferences() throws {
        let o = try parse("<< /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612.5 792] /X null /B true >>")
        guard case .dict(let d) = o else { Issue.record("not a dict"); return }
        #expect(d["Kids"] == .array([.ref(ObjRef(3, 0)), .ref(ObjRef(4, 0))]))
        #expect(d["Count"] == .int(2))
        #expect(d["MediaBox"] == .array([.int(0), .int(0), .real(612.5, "612.5"), .int(792)]))
        #expect(d["B"] == .bool(true))
        #expect(d.keys == ["Kids", "Count", "MediaBox", "X", "B"])
    }

    @Test func duplicateKeysLastWins() throws {
        guard case .dict(let d) = try parse("<< /A 1 /A 2 >>") else { Issue.record("not a dict"); return }
        #expect(d["A"] == .int(2))
        var out: [UInt8] = []
        try Serializer.writeDict(d, into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "<< /A 2 >>")
    }

    @Test func deepNestingIsRejectedNotCrashing() {
        let s = String(repeating: "[", count: 100_000)
        #expect(throws: MuluError.self) { try parse(s) }
    }

    @Test func serializerRoundTrip() throws {
        let src = "<< /Type /Catalog /Name#20X /S <00FF28> /L (a\\)b) /R -0.25 /A [1 0 R null true] /D << /K /V >> >>"
        let o = try parse(src)
        guard case .dict(let d) = o else { Issue.record("not a dict"); return }
        var out: [UInt8] = []
        try Serializer.writeDict(d, into: &out)
        let reparsed = try parse(String(decoding: out, as: UTF8.self))
        #expect(reparsed == o)
    }

    @Test func textStringDecoding() {
        #expect(PDFText.decode([0xFE, 0xFF, 0x4E, 0x2D, 0xD8, 0x3C, 0xDF, 0x89]) == "中🎉")
        #expect(PDFText.decode([0x41, 0x80, 0x93]) == "A\u{2022}\u{FB01}")
        #expect(PDFText.decode([0xEF, 0xBB, 0xBF, 0xC3, 0xA9]) == "é")
        let hex = String(decoding: PDFText.utf16BEHex("A🎉"), as: UTF8.self)
        #expect(hex == "<FEFF0041D83CDF89>")
    }
}

@Suite struct FilterTests {
    @Test func flateRoundTripWithZlibHeader() throws {
        let data = Array((0..<5000).map { UInt8($0 % 251) })
        let z = Filters.zlibCompress(data)
        #expect(z[0] == 0x78)
        #expect(try Filters.flateDecode(z) == data)
        #expect(try Filters.flateDecode(Filters.zlibCompress([])) == [])
    }

    @Test func flateRejectsPresetDictionaryAndGarbage() {
        // CMF=0x78, FLG with FDICT set and a valid FCHECK.
        var flg: UInt8 = 0x20
        while (UInt16(0x78) << 8 | UInt16(flg)) % 31 != 0 { flg += 1 }
        #expect(throws: MuluError.self) { try Filters.flateDecode([0x78, flg, 1, 2, 3, 4]) }
        #expect(throws: MuluError.self) { try Filters.flateDecode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) }
    }

    @Test(arguments: [UInt8(0), 1, 2, 3, 4])
    func pngPredictorEachFilterType(_ ft: UInt8) throws {
        let rows: [[UInt8]] = (0..<40).map { (r: Int) -> [UInt8] in (0..<7).map { (c: Int) -> UInt8 in let v: Int = r * 37 + c * 91 + r * c; return UInt8(v & 0xFF) } }
        let encoded = PDFBuilder.pngEncode(rows, filterTypes: [ft], bpp: 1)
        let parms = PDFDict([("Predictor", .int(12)), ("Columns", .int(7))])
        #expect(try Filters.applyPredictor(encoded, parms: parms) == rows.flatMap { $0 })
    }

    @Test func pngPredictorMixedRowsMultiByte() throws {
        // 3 colours x 8 bits: bytes-per-pixel 3 exercises Sub/Average/Paeth offsets.
        let rows: [[UInt8]] = (0..<25).map { (r: Int) -> [UInt8] in (0..<12).map { (c: Int) -> UInt8 in let v: Int = r * 13 + c * 29 + (r ^ c); return UInt8(v & 0xFF) } }
        let encoded = PDFBuilder.pngEncode(rows, filterTypes: [0, 1, 2, 3, 4, 4, 3], bpp: 3)
        let parms = PDFDict([("Predictor", .int(15)), ("Columns", .int(4)), ("Colors", .int(3))])
        #expect(try Filters.applyPredictor(encoded, parms: parms) == rows.flatMap { $0 })
    }

    @Test func tiffPredictor() throws {
        let raw: [UInt8] = [10, 20, 30, 40, 1, 2, 3, 4]  // 2 rows of 4 columns, 1 colour
        var encoded = raw
        for r in 0..<2 { for c in stride(from: 3, through: 1, by: -1) { encoded[r * 4 + c] = raw[r * 4 + c] &- raw[r * 4 + c - 1] } }
        let parms = PDFDict([("Predictor", .int(2)), ("Columns", .int(4))])
        #expect(try Filters.applyPredictor(encoded, parms: parms) == raw)
    }

    @Test func asciiFilters() throws {
        #expect(Filters.asciiHexDecode(Array("48 65 6C6c 6F>".utf8)) == Array("Hello".utf8))
        #expect(try Filters.ascii85Decode(Array("<~87cURD]i,\"Ebo7~>".utf8)) == Array("Hello World".utf8))
    }
}
