import Foundation
import Testing
@testable import MuluOCR

func box(_ text: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> OCRObservation {
    OCRObservation(text: text, rect: PixelRect(minX: x0, minY: y0, maxX: x1, maxY: y1))
}

@Suite struct LayoutTests {
    @Test func groupsTitleAndNumberIntoOneLine() {
        let obs = [box("12", 1800, 1004, 1830, 1036), box("第一章 绪论", 200, 1000, 500, 1045),
                   box("第一节 背景", 260, 1080, 520, 1125), box("13", 1800, 1088, 1830, 1120)]
        let lines = LineLayout.groupLines(obs)
        #expect(lines.map(\.text) == ["第一章 绪论 12", "第一节 背景 13"])
    }

    @Test func stackedBoxesDoNotMerge() {
        // Two lines whose boxes overlap a little vertically but also horizontally.
        let obs = [box("上一行", 200, 1000, 600, 1045), box("下一行", 200, 1030, 600, 1075)]
        #expect(LineLayout.groupLines(obs).count == 2)
    }

    @Test func skewIsEstimatedAndUndone() {
        // A 1 degree skew: each line descends to the right.
        let a = 1.0 * Double.pi / 180
        var obs: [OCRObservation] = []
        for i in 0..<5 {
            let y = 500.0 + Double(i) * 80
            let x0 = 200.0, x1 = 1400.0
            let corners = [PixelPoint(x: x0, y: y), PixelPoint(x: x1, y: y + (x1 - x0) * tan(a)),
                           PixelPoint(x: x1, y: y + 40 + (x1 - x0) * tan(a)), PixelPoint(x: x0, y: y + 40)]
            obs.append(OCRObservation(text: "line \(i)", rect: PixelRect(minX: x0, minY: y, maxX: x1, maxY: y + 40 + (x1 - x0) * tan(a)),
                                      corners: corners))
        }
        let skew = LineLayout.estimateSkew(obs)
        #expect(abs(skew - a) < 1e-6)
        let d = obs[0].deskewed(angle: skew, center: PixelPoint(x: 1000, y: 1000))
        #expect(abs(d.rect.height - 40) < 1)
    }

    @Test func twoColumnsAreSplitAtTheGutter() {
        var obs: [OCRObservation] = []
        for i in 0..<10 {
            let y = 300.0 + Double(i) * 60
            obs.append(box("第\(i)节 左栏标题", 100, y, 700, y + 40))
            obs.append(box("\(i + 1)", 880, y, 920, y + 40))
            obs.append(box("第\(i)节 右栏标题", 1100, y, 1700, y + 40))
            obs.append(box("\(i + 50)", 1880, y, 1920, y + 40))
        }
        let (groups, gutter) = LineLayout.splitColumns(obs, pageWidth: 2000)
        #expect(groups.count == 2)
        #expect(gutter! > 920 && gutter! < 1100)
        #expect(groups[0].allSatisfy { $0.rect.maxX < 1000 })
    }

    @Test func titlesAndAFarNumberColumnAreOneColumn() {
        // No leaders: short titles on the left, numbers far right. Not two columns.
        var obs: [OCRObservation] = []
        for i in 0..<12 {
            let y = 300.0 + Double(i) * 60
            obs.append(box("第\(i)节 标题", 150, y, 600, y + 40))
            obs.append(box("\(i * 3 + 1)", 1850, y, 1900, y + 40))
        }
        #expect(LineLayout.splitColumns(obs, pageWidth: 2000).groups.count == 1)
    }

    @Test func numberColumnFromRightEdges() {
        let rects = [PixelRect(minX: 1880, minY: 0, maxX: 1900, maxY: 30), PixelRect(minX: 1860, minY: 50, maxX: 1901, maxY: 80),
                     PixelRect(minX: 1840, minY: 100, maxX: 1899, maxY: 130), PixelRect(minX: 900, minY: 150, maxX: 930, maxY: 180)]
        let col = LineLayout.numberColumn(tokenRects: rects, charHeight: 40)!
        #expect(col.minX == 1840 && col.maxX == 1901)
        #expect(LineLayout.numberColumn(tokenRects: Array(rects.prefix(2)), charHeight: 40) == nil)
    }

    @Test func indentLevels() {
        #expect(LineLayout.indentLevels([100, 160, 220, 101, 158, 100], tolerance: 25) == [0, 1, 2, 0, 1, 0])
    }
}

@Suite struct OffsetVoteTests {
    @Test func samplePagesSkipTheEnds() {
        let s = OffsetDetector.samplePages(pageCount: 300, count: 24)
        #expect(s.count == 24 && s.first == 16 && s.last == 285)
        #expect(OffsetDetector.samplePages(pageCount: 20, count: 24) == Array(2...19))
    }

    @Test func alternatingFoliosAndNoise() {
        // offset 9; folio left on even, right on odd pages (either way it is one number);
        // some pages also show a chapter number or year; two pages have no folio.
        var samples: [OffsetSample] = []
        for p in stride(from: 20, through: 250, by: 10) {
            if p == 100 || p == 200 { samples.append(OffsetSample(page: p, printed: [])); continue }
            samples.append(OffsetSample(page: p, printed: p % 20 == 0 ? [p - 9, 3] : [p - 9], standalone: [p - 9]))
        }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .ok && r.offset == 9)
        #expect(r.agreeing == samples.count - 2 && r.samples == samples.count)
        #expect(abs(r.confidence - Double(samples.count - 2) / Double(samples.count)) < 1e-9)
    }

    @Test func tooFewAgreeingPagesIsNotTrusted() {
        let samples = (1...5).map { OffsetSample(page: $0 * 10, printed: [$0 * 10 - 4]) }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .lowConfidence && r.offset == nil && r.bestGuess == 4)
    }

    @Test func offsetThatChangesInsideTheBookIsNotTrusted() {
        // unnumbered plates after page 120 shift the offset from 8 to 16
        let samples = stride(from: 20, through: 240, by: 10).map { OffsetSample(page: $0, printed: [$0 - ($0 <= 120 ? 8 : 16)]) }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .lowConfidence && r.offset == nil)
        #expect(r.reason.contains("may change"))
    }

    @Test func digitSlipsOfTheWinnerDoNotCountAsAnotherOffset() {
        // A noisy scan (offset 7): 10 pages read their folio, 4 pages in the thirties/forties
        // lose or misread the tens digit ("5" for 35, "7" for 37, "10" for 40, "16" for 46),
        // which all look like offset 37; the rest read nothing.
        var samples: [OffsetSample] = []
        let good: Set<Int> = [20, 23, 26, 28, 31, 34, 39, 50, 61, 63]
        let slips: [Int: Int] = [42: 5, 44: 7, 47: 10, 53: 16]
        for p in [9, 12, 15, 17, 20, 23, 26, 28, 31, 34, 36, 39, 42, 44, 47, 50, 53, 55, 58, 61, 63, 66] {
            if good.contains(p) { samples.append(OffsetSample(page: p, printed: [p - 7], standalone: [p - 7])) }
            else if let s = slips[p] { samples.append(OffsetSample(page: p, printed: [s], standalone: [s])) }
            else { samples.append(OffsetSample(page: p, printed: [])) }
        }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .ok && r.offset == 7 && r.agreeing == 10)
        #expect(r.votes.first { $0.offset == 37 }?.count == 4)  // still reported
    }

    @Test func offsetChangeByTenIsNotMistakenForDigitSlips() {
        // Ten unnumbered plates after page 150: offset 8 before, 18 after. The later folios
        // look like tens-digit slips of the earlier offset, but no agreeing page follows them.
        let samples = stride(from: 20, through: 250, by: 10).map { OffsetSample(page: $0, printed: [$0 - ($0 <= 150 ? 8 : 18)]) }
        let r = OffsetVoter.vote(samples)
        #expect(r.status == .lowConfidence && r.offset == nil)
        #expect(r.reason.contains("may change"))
    }

    @Test func digitSlipShapes() {
        #expect(OffsetVoter.isDigitSlip(read: 7, expected: 37))
        #expect(OffsetVoter.isDigitSlip(read: 3, expected: 37))
        #expect(OffsetVoter.isDigitSlip(read: 16, expected: 46))
        #expect(OffsetVoter.isDigitSlip(read: 15, expected: 105))
        #expect(!OffsetVoter.isDigitSlip(read: 38, expected: 37))  // last digit differs: a real ±1
        #expect(!OffsetVoter.isDigitSlip(read: 37, expected: 37))
        #expect(!OffsetVoter.isDigitSlip(read: 4, expected: 5))
        #expect(!OffsetVoter.isDigitSlip(read: 137, expected: 37))
    }

    @Test func nothingFound() {
        let r = OffsetVoter.vote((1...24).map { OffsetSample(page: $0, printed: []) })
        #expect(r.status == .notFound && r.offset == nil && r.confidence == 0)
        #expect(r.json.hasPrefix("{\"offset\":null,"))
    }
}

@Suite struct GrayImageFilterTests {
    @Test func thickenedGrowsInkAndBoxDownscaleAverages() {
        var img = GrayImage(width: 6, height: 4)
        img.pixels[1 * 6 + 2] = 0  // one ink pixel at (2, 1)
        let t = img.thickened(radius: 1)
        let ink = (0..<t.pixels.count).filter { t.pixels[$0] == 0 }.map { ($0 % 6, $0 / 6) }
        #expect(ink.count == 9 && ink.allSatisfy { abs($0.0 - 2) <= 1 && abs($0.1 - 1) <= 1 })
        #expect(img.thickened(radius: 0).pixels == img.pixels)
        let h = t.boxDownscaled(by: 2)
        #expect(h.width == 3 && h.height == 2)
        #expect(h.pixels == [127, 0, 255, 191, 127, 255])  // mean of each 2x2 block
    }
}
