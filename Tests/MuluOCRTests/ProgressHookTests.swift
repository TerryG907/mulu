import Foundation
import Testing
@testable import MuluOCR

/// The progress hooks the app uses for progress and cancellation (GUI_SPEC §3.2): called in
/// order, and an error thrown by the hook ends the work and comes out unchanged.
@Suite(.serialized) struct ProgressHookTests {
    struct Stop: Error, Equatable {}

    static func threeTOCPages() throws -> (URL, [SyntheticPDF.Entry]) {
        let v = SyntheticPDF.tempURL("hook-vector.pdf"), s = SyntheticPDF.tempURL("hook-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v) }
        let entries = Array(SyntheticPDF.tocEntries.dropFirst().prefix(5))
        try SyntheticPDF.vectorPDF(Array(repeating: SyntheticPDF.tocPage(entries), count: 3), to: v)
        try SyntheticPDF.scanned(v, to: s)
        return (s, entries)
    }

    @Test func readReportsEveryPageThenTheEnd() throws {
        let (url, entries) = try Self.threeTOCPages()
        defer { try? FileManager.default.removeItem(at: url) }
        var calls: [String] = []
        let r = try TOCPageReader(url: url).read(pages: [1, 2, 3]) { done, total in calls.append("\(done)/\(total)") }
        #expect(calls == ["0/3", "1/3", "2/3", "3/3"])
        #expect(r.lines.count == 3 * entries.count)
        #expect(r.pages.map(\.page) == [1, 2, 3])
    }

    @Test func readRethrowsTheHooksError() throws {
        let (url, _) = try Self.threeTOCPages()
        defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        #expect(throws: CancellationError.self) {
            _ = try TOCPageReader(url: url).read(pages: [1, 2, 3]) { _, _ in
                calls += 1
                if calls == 2 { throw CancellationError() }
            }
        }
        #expect(calls == 2)  // stopped before the second page was read
    }

    @Test func detectRethrowsTheHooksError() throws {
        let v = SyntheticPDF.tempURL("hook-book-vector.pdf"), s = SyntheticPDF.tempURL("hook-book-scan.pdf")
        defer { try? FileManager.default.removeItem(at: v); try? FileManager.default.removeItem(at: s) }
        try SyntheticPDF.vectorPDF(SyntheticPDF.book(front: 2, body: 10), to: v)
        try SyntheticPDF.scanned(v, to: s, dpi: 150)
        var o = OffsetDetector.Options()
        o.samples = 4
        var seen = 0
        #expect(throws: Stop()) {
            _ = try OffsetDetector(url: s).detect(options: o) { _ in
                seen += 1
                if seen == 2 { throw Stop() }
            }
        }
        #expect(seen == 2)
        // a hook that does not throw changes nothing
        var pages: [Int] = []
        let a = try OffsetDetector(url: s).detect(options: o) { pages.append($0.page) }
        let b = try OffsetDetector(url: s).detect(options: o)
        #expect(pages == OffsetDetector.samplePages(pageCount: 12, count: 4) || pages.count >= 4)
        #expect(a.offset == b.offset && a.bestGuess == b.bestGuess && a.agreeing == b.agreeing && a.status == b.status)
    }
}
