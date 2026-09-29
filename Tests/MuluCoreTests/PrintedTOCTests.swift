import Foundation
import Testing
@testable import MuluCore

@Suite struct PrintedTOCGoldenTests {
    @Test(arguments: PrintedTOCGolden.cases.map(\.name))
    func golden(_ name: String) throws {
        let c = PrintedTOCGolden.cases.first { $0.name == name }!
        let r = PrintedTOCParser.parse(c.input)
        let text = r.muluText(header: false, annotate: false)
        #expect(text == (c.expected.isEmpty ? "" : c.expected + "\n"), "\(name)")
        let low = r.entries.filter { $0.confidence < 0.75 }.map(\.line)
        #expect(low == c.lowConfidenceLines, "\(name)")
        // The output is always a valid Mulu TOC, with or without review comments.
        let reparsed = try TOCParser.parse(text)
        #expect(reparsed.map(\.title) == r.tocEntries.map(\.title))
        #expect(reparsed.map(\.level) == r.tocEntries.map(\.level))
        #expect(reparsed.map(\.page) == r.tocEntries.map(\.page))
        let annotated = try TOCParser.parse(r.muluText())
        #expect(annotated.map(\.title) == reparsed.map(\.title))
        // Every entry's confidence is in range, and anything below 1 says why.
        for e in r.entries {
            #expect(e.confidence >= 0 && e.confidence <= 1)
            if e.confidence < 0.9 { #expect(!e.notes.isEmpty, "\(name) line \(e.line)") }
        }
    }

    @Test func atLeastSixtySnippets() {
        #expect(PrintedTOCGolden.cases.count >= 60)
        #expect(Set(PrintedTOCGolden.cases.map(\.name)).count == PrintedTOCGolden.cases.count)
    }
}

@Suite struct PageTokenTests {
    struct Case: Sendable, CustomStringConvertible {
        let line: String, title: String, value: Int?, style: PrintedPage.Style?, ocr: Bool
        var description: String { line }
        init(_ line: String, _ title: String, _ value: Int?, _ style: PrintedPage.Style? = .arabic, ocr: Bool = false) {
            self.line = line; self.title = title; self.value = value; self.style = value == nil ? nil : style; self.ocr = ocr
        }
    }

    static let cases: [Case] = [
        Case("第一章 绪论 …… 1", "第一章 绪论", 1),
        Case("1.1 研究背景 ........ 12", "1.1 研究背景", 12),
        Case("1.2 Outline ················ 4", "1.2 Outline", 4),
        Case("第三章 结论 ——— 88", "第三章 结论", 88),
        Case("2.1 Prior Art ____________ 8", "2.1 Prior Art", 8),
        Case("Preface . . . . . . . . xi", "Preface", 11, .roman),
        Case("前言 ········· iii", "前言", 3, .roman),
        Case("Preface xi", "Preface", 11, .roman),
        Case("World War II", "World War II", nil),
        Case("Part 2", "Part 2", nil),
        Case("Chapter IV", "Chapter IV", nil),
        Case("第1章城市规划导论2", "第1章城市规划导论", 2),
        Case("Hello12", "Hello12", nil),
        Case("Matrix", "Matrix", nil),
        Case("Appendix", "Appendix", nil),
        Case("COVID-19", "COVID-19", nil),
        Case("绪论 …… l2", "绪论", 12, ocr: true),
        Case("绪论 …… 1O", "绪论", 10, ocr: true),
        Case("绪论 …… lO", "绪论", 10, ocr: true),
        Case("绪论 …… l", "绪论", 1, ocr: true),
        Case("Methods ..... 2S", "Methods", 25, ocr: true),
        Case("Scope 12-15", "Scope", 12),
        Case("Scope 12 – 15", "Scope", 12),
        Case("第一章 总则（1）", "第一章 总则", 1),
        Case("第三章 附则【30】", "第三章 附则", 30),
        Case("序言 (xii)", "序言", 12, .roman),
        Case("第１２章　总论　……　１２３", "第１２章 总论", 123),
        Case("Intro p. 7", "Intro", 7),
        Case("War Years pp. 45-60", "War Years", 45),
        Case("概述 …… 第12页", "概述", 12),
        Case("引论…………1，", "引论", 1),
        Case("结果………… 30 |", "结果", 30),
        Case("算法 ...... 3O。", "算法", 30, ocr: true),
        Case("Index\tA133", "Index", 133, .prefixed),
        Case("Appendixes ........ A1", "Appendixes", 1, .prefixed),
        Case("Vitamin B12", "Vitamin B12", nil),  // digits glued to a Latin letter are not a page
        Case("第一章 社会主义市场经济体制的建立与", "第一章 社会主义市场经济体制的建立与", nil),
        Case("第三章 新时代思想的形成、", "第三章 新时代思想的形成、", nil),
        Case("Computational Linear Alge-", "Computational Linear Alge-", nil),
        Case("第一章 绪论 ……", "第一章 绪论", nil),
        Case("3.3 线性密码分析TISCUNRTeACnbwelawemwenonances 61", "3.3 线性密码分析", 61),
        Case("4.6 注释与参考文献cuNUaAUeaie 119", "4.6 注释与参考文献", 119),
        Case("使用JavaScript 5", "使用JavaScript", 5),
        Case("深入SpringBootCloud 9", "深入SpringBootCloud", 9),
        Case("目　录", "目录", nil),
        Case("前 言 …… 1", "前言", 1),
        Case("第一章  总论   概述 3", "第一章 总论 概述", 3),
        Case("1.2 你数据结构怎么学的?\t3", "1.2 你数据结构怎么学的?", 3),
        // OCR debris seen in `mulu ocr-toc` output of generated scans
        Case("9.2临床应用 6 O\t60", "9.2临床应用", 60),
        Case("第6章 抗高血压药 4.0", "第6章 抗高血压药", 40, ocr: true),
        Case("9.3 特殊人群用药 0", "9.3 特殊人群用药", nil),
        Case("5.1.1 Further Reading 、 、. .’.一 60", "5.1.1 Further Reading", 60),
        Case("Acknowledgments ×\t11", "Acknowledgments", 11),
        Case("序 …j\t1", "序", 1),
        Case("：二、争论\t90", "二、争论", 90),
        Case("一 ……………… 1", "一", 1),
        Case("Web 2.0 Basics 12", "Web 2.0 Basics", 12),
    ]

    @Test(arguments: cases)
    func split(_ c: Case) {
        let s = PageTokenizer.split(c.line)
        #expect(s.title == c.title)
        #expect(s.page?.value == c.value)
        #expect(s.page?.style == c.style)
        #expect((s.page?.ocrCorrected ?? false) == c.ocr)
    }

    @Test func separationKinds() {
        #expect(PageTokenizer.split("A …… 1").page?.separation == .leader)
        #expect(PageTokenizer.split("A 1").page?.separation == .space)
        #expect(PageTokenizer.split("导论2").page?.separation == .glued)
        #expect(PageTokenizer.split("A (1)").page?.separation == .bracket)
        #expect(PageTokenizer.split("Scope 12-15").page?.isRange == true)
    }

    @Test func pageOnlyLines() {
        #expect(PrintedTOCParser.pageOnlyLine("12")?.value == 12)
        #expect(PrintedTOCParser.pageOnlyLine("- 3 -")?.value == 3)
        #expect(PrintedTOCParser.pageOnlyLine("· 12 ·")?.value == 12)
        #expect(PrintedTOCParser.pageOnlyLine("— 5 —")?.value == 5)
        #expect(PrintedTOCParser.pageOnlyLine("iii")?.style == .roman)
        #expect(PrintedTOCParser.pageOnlyLine("１２")?.value == 12)
        #expect(PrintedTOCParser.pageOnlyLine("Chapter 1") == nil)
        #expect(PrintedTOCParser.pageOnlyLine("第一章") == nil)
    }

    @Test func numerals() {
        #expect(TOCChars.chineseNumber("一") == 1)
        #expect(TOCChars.chineseNumber("十") == 10)
        #expect(TOCChars.chineseNumber("十二") == 12)
        #expect(TOCChars.chineseNumber("二十") == 20)
        #expect(TOCChars.chineseNumber("九十九") == 99)
        #expect(TOCChars.chineseNumber("一百零五") == 105)
        #expect(TOCChars.chineseNumber("一〇五") == 105)
        #expect(TOCChars.chineseNumber("两千零二十") == 2020)
        #expect(TOCChars.chineseNumber("叁拾") == 30)
        #expect(TOCChars.chineseNumber("十百") == nil)
        #expect(TOCChars.chineseNumber("国") == nil)
        #expect(TOCChars.romanValue("xiv") == 14)
        #expect(TOCChars.romanValue("XL") == 40)
        #expect(TOCChars.romanValue("Ⅻ") == 12)
        #expect(TOCChars.romanValue("ⅳ") == 4)
        #expect(TOCChars.romanValue("IIII") == nil)
        #expect(TOCChars.romanValue("VX") == nil)
        #expect(TOCChars.romanValue("Iv") == nil)
        #expect(TOCChars.romanValue("Civil") == nil)
        #expect(TOCChars.englishNumber("Twenty-One") == 21)
        #expect(TOCChars.englishNumber("third") == 3)
        #expect(TOCChars.halfWidth("１２３ＡＢ") == "123AB")
    }
}

@Suite struct HeadingClassifierTests {
    struct Case: Sendable, CustomStringConvertible {
        let title: String, kind: HeadingKind, numbers: [Int]?
        var description: String { title }
        init(_ title: String, _ kind: HeadingKind, _ numbers: [Int]? = nil) {
            self.title = title; self.kind = kind; self.numbers = numbers
        }
    }

    static let cases: [Case] = [
        Case("第一章 绪论", .chapter, [1]), Case("第1章 绪论", .chapter, [1]), Case("第 12 章 总结", .chapter, [12]),
        Case("第十二章", .chapter, [12]), Case("第一百零一回 宴桃园豪杰三结义", .chapter, [101]), Case("第Ⅲ章 方法", .chapter, [3]),
        Case("第１章 起步", .chapter, [1]), Case("第三讲 应用", .chapter, [3]), Case("第2课 抗美援朝", .chapter, [2]),
        Case("第一节 概述", .section, [1]), Case("考点一 函数的概念", .section, [1]), Case("§3 商空间", .section, [3]),
        Case("*§3 商空间", .section, [3]), Case("Section 4 Scope", .section, [4]),
        Case("第一篇 总论", .part, [1]), Case("第一部分 基础知识", .part, [1]), Case("第二编 物权", .part, [2]),
        Case("第一单元 我们的国家", .part, [1]), Case("第一部 疯狂年代", .part, [1]), Case("上篇 理论基础", .part, [1]),
        Case("下篇 实践应用", .part, [3]), Case("第一分编 通则", .subpart, [1]),
        Case("一、总则", .cnEnum, [1]), Case("十二、附则", .cnEnum, [12]), Case("二．方法", .cnEnum, [2]), Case("三 结论", .cnEnum, [3]),
        Case("（一）指导思想", .cnParen, [1]), Case("(二) 基本原则", .cnParen, [2]), Case("〔三〕措施", .cnParen, [3]),
        Case("1. 物质观", .arabic, [1]), Case("1、概述", .arabic, [1]), Case("12 绪论", .arabic, [12]), Case("3 Summary", .arabic, [3]),
        Case("（1）甲说", .arabicParen, [1]), Case("2) item", .arabicParen, [2]), Case("① 背景", .arabicParen, [1]),
        Case("⑵ 其次", .arabicParen, [2]),
        Case("1.1 研究背景", .dotted, [1, 1]), Case("1.1.1 研究背景", .dotted, [1, 1, 1]), Case("1.2.3.4 Deep", .dotted, [1, 2, 3, 4]),
        Case("２．３ 全角", .dotted, [2, 3]), Case("l.1 引言", .dotted, [1, 1]), Case("1:3 方法", .dotted, [1, 3]),
        Case("1。4 总结", .dotted, [1, 4]), Case("A.1 Lemma", .dotted, [1, 1]), Case("§2.1 定义", .dotted, [2, 1]),
        Case("*1.5 选讲", .dotted, [1, 5]), Case("1-1 概述", .dotted, [1, 1]), Case("1.1研究背景", .dotted, [1, 1]),
        Case("Chapter 1 Introduction", .chapter, [1]), Case("CHAPTER ONE", .chapter, [1]), Case("Chapter IV: Rome", .chapter, [4]),
        Case("Ch. 3 Growth", .chapter, [3]), Case("Lecture 5 Estimation", .chapter, [5]), Case("Chapter Three: A Caucus-Race", .chapter, [3]),
        Case("Part I Foundations", .part, [1]), Case("PART TWO", .part, [2]), Case("Book 3", .part, [3]), Case("Unit 2 Genetics", .part, [2]),
        Case("Section 2.3 Scope", .dotted, [2, 3]),
        Case("Appendix A Proofs", .appendix, [1]), Case("APPENDIX B", .appendix, [2]), Case("附录A 符号表", .appendix, [1]),
        Case("附录 B 证明", .appendix, [2]), Case("附录一 证明", .appendix, [1]), Case("附录 历年真题", .appendix, []),
        Case("附录", .container), Case("Appendices", .container), Case("Appendixes", .container),
        Case("前言", .matter), Case("前 言", .matter), Case("第二版序", .matter), Case("中译版序言", .matter), Case("译者前言", .matter),
        Case("参考文献", .matter), Case("致  谢", .matter), Case("攻读硕士学位期间取得的研究成果", .matter), Case("导论", .matter),
        Case("学位论文原创性声明", .matter), Case("Preface to the Second Edition", .matter), Case("Acknowledgments", .matter),
        Case("About the Author", .matter), Case("Index", .matter), Case("LIST OF FIGURES", .matter), Case("Epilogue", .matter),
        Case("目录", .tocHeading), Case("目 录", .tocHeading), Case("Contents", .tocHeading), Case("Table of Contents", .tocHeading),
        Case("本章小结", .trailer), Case("习题1-1", .trailer, [1, 1]), Case("习题一", .trailer, []), Case("思考题", .trailer),
        Case("Exercises", .trailer), Case("Chapter Summary", .trailer), Case("Review Questions", .trailer),
        Case("程序设计", .none), Case("顺序", .none), Case("1984", .none), Case("2020年回顾", .none), Case("三国演义", .none),
        Case("一个人的战争", .none), Case("十万个为什么", .none), Case("一九八四", .none), Case("第二次世界大战", .none),
        Case("Partial Differential Equations", .none), Case("Part of the Problem", .none), Case("Chapters of Life", .none),
        Case("The Boy Who Lived", .none), Case("Unit Testing", .none), Case("3-5岁儿童", .none), Case("A Brief History", .none),
        // OCR lost or garbled the numeral: still recognised (and flagged)
        Case("第节 波谱分析", .section, []), Case("第：节 共振论", .section, []), Case("第章两汉的政治与经济", .chapter, []),
        Case("Chapter s Concurrency Primitives", .chapter, [5]), Case("第 竹 化学性质", .none),
    ]

    @Test(arguments: cases)
    func classify(_ c: Case) {
        let h = HeadingClassifier.classify(c.title)
        #expect(h.kind == c.kind)
        if let n = c.numbers { #expect(h.numbers == n) }
    }

    @Test func ocrFlag() {
        #expect(HeadingClassifier.classify("l.1 引言").ocrCorrected)
        #expect(!HeadingClassifier.classify("1.1 引言").ocrCorrected)
    }
}

@Suite struct PrintedTOCBehaviourTests {
    @Test func offsetMapsPrintedToPhysical() {
        let r = PrintedTOCParser.parse("第一章 绪论 …… 1\n第二章 方法 …… 20\n", options: PrintedTOCOptions(offset: 12))
        #expect(r.tocEntries.map(\.page) == [13, 32])
        #expect(r.entries.map { $0.printedPage?.value } == [1, 20])
        #expect(r.muluText(header: true).hasPrefix("# Mulu TOC from a printed TOC: physical page = printed page + 12\n"))
    }

    @Test func negativeOffsetBelowPageOneIsFlagged() {
        let r = PrintedTOCParser.parse("A …… 1\nB …… 9", options: PrintedTOCOptions(offset: -3))
        #expect(r.tocEntries.map(\.page) == [6])
        #expect(r.entries[0].physicalPage == nil)
        #expect(r.warnings.contains { $0.line == 1 && $0.message.contains("physical page -2") })
    }

    @Test func pagesBeyondTheDocumentAreFlagged() {
        let r = PrintedTOCParser.parse("第一章 …… 1\n第二章 …… 50\n第三章 …… 90", options: PrintedTOCOptions(offset: 10, pageCount: 80))
        #expect(r.tocEntries.map(\.page) == [11, 60])
        #expect(r.warnings.map(\.line) == [3])
        #expect(r.warnings[0].message.contains("the PDF has 80 pages"))
    }

    @Test func romanFrontMatterNeedsItsOwnOffset() {
        let text = "序 …… i\n前言 …… iii\n第一章 开端 …… 1\n"
        let plain = PrintedTOCParser.parse(text, options: PrintedTOCOptions(offset: 6))
        #expect(plain.tocEntries.map(\.title) == ["第一章 开端"])
        #expect(plain.warnings.map(\.line) == [1, 2])
        let muluText = plain.muluText()
        #expect(muluText.contains("# ? line 1: 序 [i] left out"))
        let mapped = PrintedTOCParser.parse(text, options: PrintedTOCOptions(offset: 6, romanOffset: 2))
        #expect(mapped.tocEntries.map(\.page) == [3, 5, 7])
        #expect(mapped.warnings.isEmpty)
    }

    @Test func orderViolationsKeepTheLongestRun() {
        let r = PrintedTOCParser.parse("C1 …… 1\nC2 …… 15\nC3 …… 450\nC4 …… 32\nC5 …… 40")
        #expect(r.orderViolations == [3])
        #expect(r.entries[2].confidence < 0.5)
        #expect(r.warnings.first?.message.contains("previous 15 on line 2, next 32 on line 4") == true)
        #expect(PrintedTOCParser.longestNonDecreasing([1, 5, 3, 7, 7, 2, 9]).count == 5)
        #expect(PrintedTOCParser.longestNonDecreasing([]) == [])
        #expect(PrintedTOCParser.longestNonDecreasing([5, 4, 3]).count == 1)
    }

    @Test func ocrRepairsAreLowConfidenceButKept() {
        let r = PrintedTOCParser.parse("第一章 绪论 ...... l\n第二章 方法 ...... 2O\n第三章 结果 ...... 31\n")
        #expect(r.tocEntries.map(\.page) == [1, 20, 31])
        #expect(r.lowConfidenceEntries.map(\.line) == [1, 2])
        #expect(r.entries[0].notes.contains { $0.contains("OCR repair") })
        #expect(r.entries[2].confidence == 1)
    }

    @Test func xPositionsFromOCR() {
        // Unnumbered novel sections, indented by x-position in points.
        let lines = [
            PrintedTOCLine(text: "Book One\t1", indent: 72.0, lineNumber: 1),
            PrintedTOCLine(text: "The Storm\t3", indent: 90.4, lineNumber: 2),
            PrintedTOCLine(text: "Aftermath\t19", indent: 91.1, lineNumber: 3),
            PrintedTOCLine(text: "A Letter\t20", indent: 108.2, lineNumber: 4),
            PrintedTOCLine(text: "Book Two\t41", indent: 72.3, lineNumber: 5),
            PrintedTOCLine(text: "Harbour\t43", indent: 90.0, lineNumber: 6),
        ]
        let r = PrintedTOCParser.parse(lines: lines, options: PrintedTOCOptions(indentTolerance: 4))
        #expect(r.entries.map(\.level) == [0, 1, 1, 2, 0, 1])
        #expect(r.entries[1].notes.contains("unnumbered: level from indentation"))
    }

    @Test func ocrAgentOutputWithGarbledNumbering() {
        // `mulu ocr-toc` style: 2 spaces per indent step, TAB before the page. The first
        // section's "第一节" came out as "第 竹", and two "一、" lost their numeral; the
        // indentation columns still place them under the right parent.
        let text = """
            前言\t1
            第一章 绪论\t1
              第 竹 化学性质\t2
                数学推导\t3
                二、影响因素\t8
              第二节 反应机理\t9
                、注意事项\t9
            第二章 烷烃\t12
              第节 物理性质\t13
                一、概念界定\t13
            """
        let r = PrintedTOCParser.parse(text, options: PrintedTOCOptions(offset: 7, romanOffset: 4))
        #expect(r.entries.map(\.title) == ["前言", "第一章 绪论", "第 竹 化学性质", "数学推导", "二、影响因素", "第二节 反应机理",
                                           "注意事项", "第二章 烷烃", "第一节 物理性质", "一、概念界定"])
        // "第节" (numeral lost) is restored from its position: the first section after 第二章.
        #expect(r.entries[8].notes.contains { $0.hasPrefix("numeral lost by OCR") })
        #expect(r.entries.map(\.level) == [0, 0, 1, 2, 2, 1, 2, 0, 1, 2])
        // "前言 1" before chapter 1 at page 1 is the front-matter "i" misread.
        #expect(r.entries[0].printedPage?.style == .roman)
        #expect(r.tocEntries.map(\.page) == [5, 8, 9, 10, 15, 16, 16, 19, 20, 20])
        #expect(r.lowConfidenceEntries.map(\.line) == [1])  // the repaired front-matter page
        #expect(HeadingClassifier.spaceAfterNumbering("2.1给药方案") == "2.1 给药方案")
        #expect(HeadingClassifier.spaceAfterNumbering("4.2.1Checklist") == "4.2.1 Checklist")
        #expect(HeadingClassifier.spaceAfterNumbering("1.1 已有空格") == "1.1 已有空格")
    }

    @Test func indentationAloneDecidesForUnnumberedLists() {
        let r = PrintedTOCParser.parse("Getting Started 1\n    Installing 2\n        Hello 3\nAdvanced 9\n    Threads 10\n")
        #expect(r.entries.map(\.level) == [0, 1, 2, 0, 1])
        #expect(r.lowConfidenceEntries.isEmpty)
    }

    @Test func crlfBomAndBlankLines() {
        let r = PrintedTOCParser.parse("\u{FEFF}第一章 绪论 …… 1\r\n\r\n  1.1 背景 …… 2\r第二章 方法 …… 9\r\n")
        #expect(r.tocEntries.map(\.title) == ["第一章 绪论", "1.1 背景", "第二章 方法"])
        #expect(r.tocEntries.map(\.line) == [1, 3, 4])
    }

    @Test func emptyInput() {
        let r = PrintedTOCParser.parse("\n  \n")
        #expect(r.entries.isEmpty)
        #expect(r.muluText(header: false) == "")
        #expect(r.json == "[]")
        #expect(r.meanConfidence == 1)
    }

    @Test func garbageLinesAreReportedNotDropped() {
        let r = PrintedTOCParser.parse("……………\n第一章 …… 1\n")
        #expect(r.entries.count == 1)
        #expect(r.warnings.map(\.line) == [1])
    }

    @Test func jsonDump() throws {
        let r = PrintedTOCParser.parse("前言 …… iii\n第一章 绪论 …… l\n", options: PrintedTOCOptions(offset: 4))
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(r.json.utf8)) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["printed"] as? String == "iii")
        #expect(rows[0]["page"] is NSNull)
        #expect(rows[1]["page"] as? Int == 5)
        #expect(rows[1]["kind"] as? String == "chapter")
        #expect((rows[1]["notes"] as? [String])?.first?.contains("OCR repair") == true)
    }

    @Test func titlesThatLookLikeComments() throws {
        let r = PrintedTOCParser.parse("#1 Hit …… 3\n")
        let text = r.muluText(header: false, annotate: false)
        #expect(text == "＃1 Hit 3\n")
        #expect(try TOCParser.parse(text).count == 1)
    }

    @Test func levelsReclampWhenFrontMatterIsLeftOut() throws {
        // An unmapped parent is left out; its child must not start at level 1.
        func entry(_ t: String, _ level: Int, _ page: Int?, _ line: Int) -> PrintedTOCEntry {
            PrintedTOCEntry(title: t, level: level, heading: Heading(kind: .none), printedPage: nil, physicalPage: page,
                            lines: [line], confidence: 1, notes: [], pageInherited: false)
        }
        let r = PrintedTOCResult(entries: [entry("Front", 0, nil, 1), entry("Note", 1, 5, 2), entry("Deeper", 2, 6, 3), entry("Body", 0, 9, 4)],
                                 warnings: [], options: PrintedTOCOptions())
        #expect(r.tocEntries.map(\.level) == [0, 1, 0])
        #expect(try TOCParser.parse(r.muluText()).map(\.level) == [0, 1, 0])
    }
}

@Suite struct PrintedTOCFuzzTests {
    /// Deterministic xorshift generator so failures reproduce.
    struct XorShift: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    static let pool = ["第", "一", "十", "章", "节", "篇", "、", "（", "）", "1", "2", "9", ".", "…", "·", " ", "  ", "\t", "\u{3000}",
                       "l", "O", "I", "i", "x", "v", "A", "S", "Chapter", "Part", "Section", "附录", "前言", "参考文献", "习题",
                       "-", "—", "(", ")", "【", "】", "#", "目录", "12", "３", "é", "😀", "p.", "页", "§", "①", "\u{00A0}", "×", "：", "0"]

    @Test func randomLinesNeverCrashAndAlwaysYieldAValidTOC() throws {
        var rng = XorShift(state: 0x9E37_79B9_7F4A_7C15)
        for doc in 0..<400 {
            var lines: [String] = []
            for _ in 0..<Int.random(in: 1...14, using: &rng) {
                var line = ""
                for _ in 0..<Int.random(in: 0...10, using: &rng) { line += Self.pool.randomElement(using: &rng)! }
                lines.append(line)
            }
            let text = lines.joined(separator: "\n")
            let options = PrintedTOCOptions(offset: Int.random(in: -5...5, using: &rng),
                                            romanOffset: Bool.random(using: &rng) ? 2 : nil,
                                            pageCount: Bool.random(using: &rng) ? 40 : nil)
            let r = PrintedTOCParser.parse(text, options: options)
            let parsed = try TOCParser.parse(r.muluText())
            #expect(parsed.count == r.tocEntries.count, "doc \(doc)")
            #expect(try JSONSerialization.jsonObject(with: Data(r.json.utf8)) is [Any], "doc \(doc)")
            for e in r.tocEntries { #expect(e.page >= 1 && (options.pageCount.map { e.page <= $0 } ?? true)) }
        }
    }

    @Test func largeTOCIsLinear() {
        var text = ""
        for c in 1...1500 {
            text += "第\(c)章 标题\(c) …………………… \(c * 10)\n"
            text += "  \(c).1 小节 …………………… \(c * 10 + 1)\n"
            text += "  \(c).2 小节 \n"          // pageless: inherits
            text += "    （一）要点 …………………… \(c * 10 + 3)\n"
        }
        let clock = ContinuousClock()
        let start = clock.now
        let r = PrintedTOCParser.parse(text)
        let elapsed = clock.now - start
        #expect(r.entries.count == 6000)
        #expect(elapsed < .seconds(10))
        #expect(r.orderViolations.isEmpty)
    }
}
