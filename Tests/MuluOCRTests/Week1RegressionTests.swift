import Foundation
import Testing
@testable import MuluOCR

/// Reproducers of the week-1 no-regression review (tools/adversarial/week1-noregress) that do
/// not need Vision: the offset vote and the title-stability rule.
@Suite struct Week1RegressionTests {
    /// The 24 sample pages of the 121-page w1_plates_late book.
    private var latePages: [Int] { OffsetDetector.samplePages(pageCount: 121, count: 24) }

    @Test func lateOffsetChangeIsRefused() {
        // 4 unnumbered plates after physical page 104: offset 9 before, 13 after. Only the last
        // two samples see the change (a 19 : 2 vote), but every entry after it would be wrong.
        let samples = latePages.map { p in OffsetSample(page: p, printed: [p - (p <= 104 ? 9 : 13)], standalone: [p - (p <= 104 ? 9 : 13)]) }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .lowConfidence && r.offset == nil)
        #expect(r.reason.contains("near the end"))
        #expect(r.conflict?.offset == 13)
    }

    @Test func midBookPlatesWithCloseVoteAreRefused() {
        // w1_plates_mid / mid8: 12 : 11 and 10 : 10 splits between two offsets.
        for shift in [4, 8] {
            let pages = OffsetDetector.samplePages(pageCount: 117 + shift, count: 24)
            let samples = pages.map { p in OffsetSample(page: p, printed: [p - (p <= 63 ? 9 : 9 + shift)]) }
            let r = OffsetVoter.vote(samples)
            #expect(r.status == .lowConfidence && r.offset == nil, "shift \(shift)")
            #expect(r.conflict != nil, "shift \(shift)")
        }
    }

    @Test func sawtoothFoliosAreNotTrusted() {
        // printed folios restart every 13 pages: few samples agree on any one offset
        let samples = OffsetDetector.samplePages(pageCount: 117, count: 24).map { p in OffsetSample(page: p, printed: [(p - 1) % 13 + 1]) }
        let r = OffsetVoter.vote(samples)
        #expect(r.status != .ok && r.offset == nil)
    }

    @Test func unreadableSamplesDoNotBlockTheVote() {
        // big2000_zerobox: the first sampled page cannot be rendered; it counts as unreadable.
        var samples = OffsetDetector.samplePages(pageCount: 2000, count: 24).map { OffsetSample(page: $0, printed: [$0 - 8]) }
        samples[0] = OffsetSample(page: samples[0].page, printed: [], texts: ["(could not render)"])
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .ok && r.offset == 8 && r.agreeing == 23)
    }

    @Test func textBeforeLeadersIsFoundFromTheInk() {
        // zh_essays_unnumbered page 8: a speck in the margin, "之一" (a tall glyph, then a flat
        // one), then a long run of leader dots. charH 40.
        var img = GrayImage(width: 1200, height: 80)
        func ink(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            for y in y0..<y1 { for x in x0..<x1 { img.pixels[y * img.width + x] = 0 } }
        }
        ink(100, 50, 104, 54)                              // speck
        ink(300, 20, 338, 60)                              // 之
        ink(345, 38, 385, 42)                              // 一 (flat, but wide)
        for x in stride(from: 420, to: 1180, by: 16) { ink(x, 55, x + 4, 59) }  // leaders
        let span = img.leadingTextSpan(charH: 40)
        #expect(span?.start == 300)
        #expect(span?.end == 384)
        #expect(GrayImage(width: 50, height: 20).leadingTextSpan(charH: 40) == nil)
    }

    @Test func trailingNumberSplitIsNotTitleInstability() {
        // c24 / c38: one resolution reads "70" into the first line of a wrapped title, another as its page
        #expect(!TOCPageReader.titleUnstable("5.2 世界大战后的70", alternates: ["5.2 世界大战后的", "5.2 世界大战后的"]))
        #expect(!TOCPageReader.titleUnstable("3.2 回顾", alternates: ["3.2 回顾20", nil]))
        // a changed digit or letter is still instability
        #expect(TOCPageReader.titleUnstable("Windows 10", alternates: ["Windows 1", "Windows 11"]))
        #expect(TOCPageReader.titleUnstable("第三章 隋唐的繁荣", alternates: ["第三章 隋唐的繁菜", "第三章 隋唐的繁菜"]))
    }
}
