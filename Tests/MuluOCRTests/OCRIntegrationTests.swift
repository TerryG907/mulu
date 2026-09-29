import Foundation
import Testing
@testable import MuluOCR

/// End-to-end Vision tests on generated black-and-white "scans" (see SyntheticPDF).
@Suite(.serialized) struct OCRIntegrationTests {
    static func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var d = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var prev = d[0]
            d[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let t = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = t
            }
        }
        return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
    }

    /// Compares read lines with the printed entries: every entry must be found in order,
    /// with its page number.
    static func check(_ lines: [TOCLine], _ entries: [SyntheticPDF.Entry]) -> [String] {
        var problems: [String] = []
        let got = lines.map { (squash($0.title), $0.page?.text) }
        if got.count != entries.count { problems.append("expected \(entries.count) lines, got \(got.count): \(lines.map(\.text))") }
        for (i, e) in entries.enumerated() where i < got.count {
            let wantPage = PageToken.parse(e.page)!.text
            // Titles may carry an OCR slip (one wrong letter in eight); page numbers must be exact.
            if similarity(got[i].0, squash(e.title)) < 0.85 || got[i].1 != wantPage {
                problems.append("line \(i + 1): got \(got[i].0) | \(got[i].1 ?? "-"), want \(squash(e.title)) | \(wantPage)")
            }
        }
        return problems
    }

    @Test func singleColumnTOCPage() throws {
        let v = SyntheticPDF.tempURL("toc-vector.pdf"), s = SyntheticPDF.tempURL("toc-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF([SyntheticPDF.tocPage(SyntheticPDF.tocEntries)], to: v)
        try SyntheticPDF.scanned(v, to: s)
        let r = try TOCPageReader(url: s).read(pages: [1])
        let problems = OCRIntegrationTests.check(r.lines, SyntheticPDF.tocEntries)
        #expect(problems.isEmpty, "\(problems)")
        // indentation follows the printed levels
        #expect(r.lines.map(\.indentLevel) == SyntheticPDF.tocEntries.map(\.level))
        #expect(r.lines.first?.page?.kind == .roman)
        #expect(r.pages.first?.columns == 1)
    }

    @Test func skewedTOCPage() throws {
        let v = SyntheticPDF.tempURL("toc-vector2.pdf"), s = SyntheticPDF.tempURL("toc-skew.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF([SyntheticPDF.tocPage(SyntheticPDF.tocEntries)], to: v)
        try SyntheticPDF.scanned(v, to: s, skew: { _ in 1.1 })
        let r = try TOCPageReader(url: s).read(pages: [1])
        #expect(abs(abs(r.pages[0].skewDegrees) - 1.1) < 0.3)
        let problems = OCRIntegrationTests.check(r.lines, SyntheticPDF.tocEntries)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func twoColumnTOCPage() throws {
        let left = Array(SyntheticPDF.tocEntries.prefix(8)).map { e -> SyntheticPDF.Entry in var e = e; e.level = min(e.level, 1); return e }
        let right = Array(SyntheticPDF.tocEntries.dropFirst(8)).map { e -> SyntheticPDF.Entry in var e = e; e.level = min(e.level, 1); return e }
        let v = SyntheticPDF.tempURL("toc2-vector.pdf"), s = SyntheticPDF.tempURL("toc2-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF([SyntheticPDF.twoColumnTOCPage(left, right)], to: v)
        try SyntheticPDF.scanned(v, to: s)
        let r = try TOCPageReader(url: s).read(pages: [1])
        #expect(r.pages.first?.columns == 2)
        let problems = OCRIntegrationTests.check(r.lines, left + right)
        #expect(problems.isEmpty, "\(problems)")
        #expect(r.lines.map(\.column) == Array(repeating: 0, count: left.count) + Array(repeating: 1, count: right.count))
    }

    @Test func detectOffsetOnAGeneratedBook() throws {
        let v = SyntheticPDF.tempURL("book-vector.pdf"), s = SyntheticPDF.tempURL("book-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF(SyntheticPDF.book(front: 6, body: 34), to: v)
        try SyntheticPDF.scanned(v, to: s, dpi: 200, skew: { p in p % 3 == 0 ? 0.6 : -0.4 })
        let r = try OffsetDetector(url: s).detect()
        #expect(r.status == .ok, "\(r.json)")
        #expect(r.offset == 6)
        #expect(r.agreeing >= 6 && r.confidence >= 0.6, "\(r.json)")
    }

    @Test func detectOffsetRefusesWithoutFolios() throws {
        let v = SyntheticPDF.tempURL("book2-vector.pdf"), s = SyntheticPDF.tempURL("book2-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF(SyntheticPDF.book(front: 3, body: 16, folios: false), to: v)
        try SyntheticPDF.scanned(v, to: s, dpi: 150)
        var o = OffsetDetector.Options()
        o.samples = 10
        let r = try OffsetDetector(url: s).detect(options: o)
        #expect(r.status != .ok && r.offset == nil, "\(r.json)")
    }
}
