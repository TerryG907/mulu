import Foundation
import Testing
@testable import MuluOCR

@Suite struct PageTokenTests {
    func split(_ s: String) -> (String, String, Bool)? {
        guard let r = PageToken.splitTrailing(s) else { return nil }
        return (r.title, r.number.text, r.leader)
    }

    @Test func leadersAndSpaces() {
        #expect(split("第一章 绪论 …… 12")! == ("第一章 绪论", "12", true))
        #expect(split("第一节 价格管制的效应 ·········· 2")! == ("第一节 价格管制的效应", "2", true))
        #expect(split("1.1 研究背景 ..... 3")! == ("1.1 研究背景", "3", true))
        #expect(split("二、常见误区——————5")! == ("二、常见误区", "5", true))
        #expect(split("Preface . . . . . vii")! == ("Preface", "vii", true))
        #expect(split("Chapter 3 Memory 41")! == ("Chapter 3 Memory", "41", false))
        #expect(split("前言 i")! == ("前言", "i", false))
    }

    @Test func fullWidthRangesAndNoise() {
        #expect(split("第二章 理论基础 …… １５")! == ("第二章 理论基础", "15", true))
        #expect(split("2.2 分析框架 …… 30-35")! == ("2.2 分析框架", "30-35", true))
        #expect(PageToken.splitTrailing("2.2 分析框架 …… 30–35")!.number.value == 30)
        let n = PageToken.splitTrailing("第三节 短期均衡 …… 1O")!.number
        #expect(n.value == 10 && n.noisy)
        #expect(PageToken.splitTrailing("第三节 短期均衡 …… l2")!.number.value == 12)
        #expect(PageToken.splitTrailing("第三节 短期均衡 …… I")!.number == PageNumber(value: 1, kind: .roman, text: "i", upperRoman: true))
        // stray punctuation after the number
        #expect(PageToken.splitTrailing("本章小结 …… 12.")!.number.value == 12)
    }

    @Test func notPageNumbers() {
        #expect(PageToken.splitTrailing("第一章 绪论") == nil)
        #expect(PageToken.splitTrailing("Section 2.3") == nil)
        #expect(PageToken.splitTrailing("1.1.2") == nil)
        #expect(PageToken.splitTrailing("Part II") == nil)  // upper-case roman needs leaders
        #expect(PageToken.splitTrailing("Appendix C") == nil)
        #expect(PageToken.splitTrailing("Appendix") == nil)
        #expect(PageToken.splitTrailing("COVID19") == nil)
        #expect(PageToken.splitTrailing("本章小结 ……") == nil)
        #expect(PageToken.splitTrailing("Hello") == nil)
    }

    @Test func abuttingCJKDigits() {
        let s = PageToken.splitTrailing("第一章 绪论12")!
        #expect(s.title == "第一章 绪论" && s.number.value == 12 && s.abutting)
        #expect(PageToken.splitTrailing("绪论xii") == nil)  // roman never abuts
    }

    @Test func standaloneFolios() {
        #expect(PageToken.parseStandalone("12")?.value == 12)
        #expect(PageToken.parseStandalone("— 12 —")?.value == 12)
        #expect(PageToken.parseStandalone("· 12 ·")?.value == 12)
        #expect(PageToken.parseStandalone("- 7 -")?.value == 7)
        #expect(PageToken.parseStandalone("第 12 页")?.value == 12)
        #expect(PageToken.parseStandalone("Page 9")?.value == 9)
        #expect(PageToken.parseStandalone("xiv")?.kind == .roman)
        #expect(PageToken.parseStandalone("xiv", allowRoman: false) == nil)
        #expect(PageToken.parseStandalone("第3章") == nil)
        #expect(PageToken.parseStandalone("12 需求理论") == nil)
    }

    @Test func folioCandidatesInRunningHeads() {
        func vals(_ s: String) -> [Int] { PageToken.folioCandidates(s).map(\.value) }
        #expect(vals("12") == [12])
        #expect(PageToken.folioCandidates("— 12 —").first?.standalone == true)
        #expect(vals("需求理论 13") == [13])
        #expect(vals("14 第三章 需求理论") == [14])
        #expect(vals("第 3 章 需求理论") == [])
        #expect(vals("第3章 需求理论") == [])
        #expect(vals("Chapter 3") == [])
        #expect(vals("CHAPTER 3 · MEMORY 45") == [45])
        #expect(vals("需求理论13") == [13])
        #expect(vals("3.2 Section title") == [])
    }

    @Test func titleCleanup() {
        #expect(TOCPageReader.cleanTitle("•二、常见误区") == "二、常见误区")
        #expect(TOCPageReader.cleanTitle("． 第一节 •短期生产分析") == "第一节 短期生产分析")
        #expect(TOCPageReader.cleanTitle("第一节，工资的决定") == "第一节 工资的决定")
        #expect(TOCPageReader.cleanTitle("第一节.古诺模型") == "第一节 古诺模型")
        #expect(TOCPageReader.cleanTitle("第三节厂商的收益") == "第三节 厂商的收益")
        #expect(TOCPageReader.cleanTitle("第十二部分 总结") == "第十二部分 总结")
        #expect(TOCPageReader.cleanTitle("马克思·韦伯") == "马克思·韦伯")
    }
}

@Suite struct OCRRepairTests {
    @Test func romanLookalikes() {
        #expect(PageToken.romanLookalike("... 111")?.text == "iii")
        #expect(PageToken.romanLookalike(".. ifi")?.text == "iii")
        #expect(PageToken.romanLookalike("xii")?.value == 12)
        #expect(PageToken.romanLookalike("12") == nil)
    }

    @Test func romanIReadAsJ() {
        let s = PageToken.splitTrailing("序 ……j")!
        #expect(s.title == "序" && s.number.text == "i" && s.number.noisy)
        #expect(PageToken.splitTrailing("Taj") == nil)
    }

    @Test func spacedWideDigits() {
        #expect(PageToken.splitTrailing("理论基础 …… 1 5")!.number.text == "15")
        #expect(PageToken.splitTrailing("Chapter 3 1")!.number.text == "1")  // no leaders: not merged
        #expect(TOCPageReader.trailingDigits("量效关系 1 0")! == ("10", "量效关系"))
        #expect(TOCPageReader.trailingDigits("理论基础 1")! == ("1", "理论基础"))
        #expect(TOCPageReader.trailingDigits("Section 2.3") == nil)
        #expect(TOCPageReader.trailingDigits("Chapter 3") == nil)
        #expect(TOCPageReader.trailingDigits("附录12") == nil)  // not space-separated
    }

    @Test func glyphAfterSymbolIsNotAbutting() {
        // "×11" (a roman xii misread) must not become page 11 glued to the title
        #expect(PageToken.splitTrailing("Acknowledgments ×11") == nil)
    }

    @Test func nestedDuplicateObservationsAreDropped() {
        let obs = [box("...6", 792, 126, 985, 189), box("6", 938, 138, 982, 198), box("8", 1487, 134, 1685, 190)]
        #expect(TextRecognizer.dedupe(obs).map(\.text) == ["...6", "8"])
    }

    @Test func upsideDownReadingsAreDropped() {
        let flipped = OCRObservation(text: "9", rect: PixelRect(minX: 0, minY: 0, maxX: 20, maxY: 30),
                                     corners: [PixelPoint(x: 20, y: 30), PixelPoint(x: 0, y: 30), PixelPoint(x: 0, y: 0), PixelPoint(x: 20, y: 0)])
        #expect(TextRecognizer.upright([flipped, box("6", 0, 0, 20, 30)]).map(\.text) == ["6"])
    }

    @Test func oneOrIByPrintedOrder() {
        func line(_ t: String, _ n: PageNumber) -> TOCLine {
            TOCLine(sourcePage: 1, column: 0, indentLevel: 0, x: 0, y: 0, width: 0, height: 0, title: t, page: n,
                    pageSource: .inline, confidence: 1, notes: [])
        }
        let i = PageNumber(value: 1, kind: .roman, text: "i"), one = PageNumber(value: 1, kind: .arabic, text: "1")
        var a = [line("前言", i), line("第一章", i), line("第一节", PageNumber(value: 2, kind: .arabic, text: "2"))]
        TOCPageReader.resolveOneOrI(&a)
        #expect(a.map { $0.page!.text } == ["i", "1", "2"])
        var b = [line("序", one), line("前言", PageNumber(value: 3, kind: .roman, text: "iii")), line("第一章", one)]
        TOCPageReader.resolveOneOrI(&b)
        #expect(b.map { $0.page!.text } == ["i", "iii", "1"])
    }

    @Test func loneStrokeShapes() {
        // a "1": one tall thin stroke, a few leader dots on the left
        var img = GrayImage(width: 120, height: 60)
        for y in 12..<46 { for x in 80..<86 { img[x, y] = 0 } }
        for x in stride(from: 5, to: 30, by: 8) { img[x, 40] = 0; img[x + 1, 40] = 0; img[x, 41] = 0; img[x + 1, 41] = 0 }
        #expect(GlyphShape.loneStroke(img, textHeight: 45)?.text == "1")
        // an "i": shorter stroke with a dot above it
        var i = GrayImage(width: 120, height: 60)
        for y in 26..<46 { for x in 80..<85 { i[x, y] = 0 } }
        for y in 16..<21 { for x in 80..<85 { i[x, y] = 0 } }
        #expect(GlyphShape.loneStroke(i, textHeight: 45)?.text == "i")
        // two strokes ("11") are not a lone stroke
        for y in 12..<46 { for x in 95..<101 { img[x, y] = 0 } }
        #expect(GlyphShape.loneStroke(img, textHeight: 45) == nil)
    }

    @Test func rowLayoutOffsets() {
        let a = GrayImage(width: 10, height: 4, fill: 0), b = GrayImage(width: 6, height: 8, fill: 0)
        let (img, xs) = GrayImage.row([a, b], gap: 3)
        #expect(img.width == 10 + 6 + 3 * 3 && img.height == 8 + 6 && xs == [3, 16])
        #expect(img[3, 5] == 0 && img[3, 4] == 255)
    }
}
