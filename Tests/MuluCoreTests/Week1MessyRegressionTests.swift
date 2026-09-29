import Foundation
import Testing
@testable import MuluCore

/// One reproducer per finding of the week-1 "messy TOC" adversarial review
/// (tools/adversarial/week1-messy). Each case was a silent mis-parse before the fix.
@Suite struct Week1MessyRegressionTests {
    private func parse(_ text: String, offset: Int = 0, roman: Int? = nil) -> PrintedTOCResult {
        PrintedTOCParser.parse(text, options: PrintedTOCOptions(offset: offset, romanOffset: roman))
    }

    private func row(_ r: PrintedTOCResult, _ title: String) -> PrintedTOCEntry? {
        r.entries.first { $0.title == title }
    }

    /// c38 / c24: a wrapped title whose first line ends in an in-order number.
    @Test func wrappedTitleEndingInNumberIsOneEntry() {
        let r = parse("第三章 战后经济 …… 19\n  3.1 马歇尔计划 …… 20\n  3.2 回顾20\n   世纪的经济史 …… 26\n  3.3 石油危机 …… 31\n")
        #expect(r.entries.map(\.title) == ["第三章 战后经济", "3.1 马歇尔计划", "3.2 回顾20世纪的经济史", "3.3 石油危机"])
        #expect(row(r, "3.2 回顾20世纪的经济史")?.printedPage?.value == 26)
        #expect(row(r, "3.2 回顾20世纪的经济史")?.level == 1)
        #expect(r.warnings.contains { $0.line == 3 })
        let c24 = parse("""
            第五章 战后经济 ……………… 60
              5.1 马歇尔计划 ……………… 62
              5.2 世界大战后的70
               年代经济 ……………… 72
            第六章 未来100
             年的城市 ……………… 101
              6.1 人口 ……………… 102
              6.2 交通与住房的第2
               次革命 ……………… 106
            第七章 Lessons from Apollo 11
             and Beyond ……………… 115
            参考文献 ……………… 120
            """)
        #expect(c24.entries.map(\.title) == ["第五章 战后经济", "5.1 马歇尔计划", "5.2 世界大战后的70年代经济", "第六章 未来100年的城市",
                                             "6.1 人口", "6.2 交通与住房的第2次革命", "第七章 Lessons from Apollo 11 and Beyond", "参考文献"])
        #expect(c24.entries.map { $0.printedPage?.value } == [60, 62, 72, 101, 102, 106, 115, 120])
    }

    /// c12: "28 至 35" is a range; the first page is used and the leader is not in the title.
    @Test func chineseRangeTakesFirstPage() {
        let r = parse("第一章 导论 …… 1\n  第一节 概念 …… 2\n  第二节 结果 …… 28 至 35\n第二章 方法 …… 40\n")
        #expect(row(r, "第二节 结果")?.printedPage?.value == 28)
        #expect(r.entries.map(\.title) == ["第一章 导论", "第一节 概念", "第二节 结果", "第二章 方法"])
    }

    /// c04: unnumbered titles that start with digits are siblings of the dotted-looking one.
    @Test func digitLeadTitlesStaySiblings() {
        let r = parse("第一章 经济形势 …… 1\n  一、2019年回顾 …… 2\n  二、2020年展望 …… 5\n第二章 第3版说明 …… 11\n"
            + "  1.5倍速播放与学习效率 …… 12\n  3D打印技术 …… 15\n  5G网络与物联网 …… 18\n第三章 中国 …… 21\n")
        #expect(r.entries.map(\.title).contains("1.5倍速播放与学习效率"))
        #expect(row(r, "3D打印技术")?.level == 1)
        #expect(row(r, "5G网络与物联网")?.level == 1)
        #expect(row(r, "1.5倍速播放与学习效率")?.level == 1)
    }

    /// c28: OCR dropped the space in "1.2 1.5万亿投资".
    @Test func gluedNumberingIsSplitAndFlagged() {
        let r = parse("第1章 2020年经济形势 …… 1\n  1.1 总体判断 …… 3\n  1.21.5万亿投资 …… 8\n第2章 政策 …… 13\n")
        let e = row(r, "1.2 1.5万亿投资")
        #expect(e?.level == 1)
        #expect((e?.confidence ?? 1) < 1)
    }

    /// c06: leftover leader glyphs and a digit glued to them are stripped when the page is in the TAB column.
    @Test func leaderLeftoversAreStripped() {
        let r = parse("第一章 总则\t1\n第二章 组织----------- 1\t9\n第三章 权利－－－－ 2\t15\n附则== 11\t32\n")
        #expect(r.entries.map(\.title) == ["第一章 总则", "第二章 组织", "第三章 权利", "附则"])
        #expect(r.entries.map { $0.printedPage?.value } == [1, 9, 15, 32])
    }

    /// c19: a list of figures after the TOC is skipped instead of winning the order check.
    @Test func listOfFiguresIsSkipped() {
        let r = parse("""
            目录
            第一章 市场与价格 …… 1
              第一节 需求 …… 2
              第二节 供给 …… 7
            第二章 消费者理论 …… 12
              第一节 效用 …… 13
            参考文献 …… 35
            图表目录
            图1-1 需求曲线 …… 3
            图1-2 供给曲线 …… 8
            图2-1 无差异曲线 …… 14
            表2-1 效用表 …… 15
            """, offset: 6)
        #expect(r.entries.map(\.title) == ["第一章 市场与价格", "第一节 需求", "第二节 供给", "第二章 消费者理论", "第一节 效用", "参考文献"])
        #expect(r.orderViolations.isEmpty)
        #expect(r.warnings.contains { $0.message.contains("list of figures") })
    }

    /// c08: the TOC page's folio and "目录（续）" between a wrapped title and its continuation.
    @Test func folioBetweenWrappedHalvesIsDropped() {
        let r = parse("第三章 地方政府 …… 21\n  第一节 财政分权 …… 22\n  第二节 土地财政与地方债务的形成机制及其\niii\n目录（续）\n"
            + "   对区域经济的影响 …… 29\n第四章 实证 …… 33\n", offset: 6, roman: 2)
        #expect(r.entries.map(\.title) == ["第三章 地方政府", "第一节 财政分权", "第二节 土地财政与地方债务的形成机制及其对区域经济的影响", "第四章 实证"])
        #expect(row(r, "第二节 土地财政与地方债务的形成机制及其对区域经济的影响")?.physicalPage == 35)
    }

    /// c26: an English title ending in Problem / Part / Chapter keeps its TAB-column page.
    @Test func englishTitleEndingInKeywordKeepsPage() {
        let r = parse("1 Solving the Problem\t7\n2 The Final Part\t19\n7 Last Chapter\t55\n8 Epilogue\t60\n")
        #expect(r.entries.map(\.title) == ["1 Solving the Problem", "2 The Final Part", "7 Last Chapter", "8 Epilogue"])
        #expect(r.entries.map { $0.printedPage?.value } == [7, 19, 55, 60])
        #expect(r.entries.allSatisfy { !$0.pageInherited })
    }

    /// c02: "Index 索引" after the appendices is back matter (level 0).
    @Test func bilingualIndexIsBackMatter() {
        let r = parse("Appendix A 常用命令 …… 45\n附录B Git 速查表 …… 48\nIndex 索引 …… 52\n")
        #expect(r.entries.map(\.level) == [0, 0, 0])
    }

    /// c21: ① under (1) is one level deeper.
    @Test func circledNumbersNestUnderParenNumbers() {
        let r = parse("1.1.1 萌芽阶段 …… 2\n  (1) 早期探索 …… 3\n    ① 理论准备 …… 3\n    ② 技术准备 …… 4\n  (2) 初步形成 …… 5\n")
        #expect(r.entries.map(\.level) == [0, 1, 2, 2, 1])
    }

    /// c23: a subtitle line starting with "——" continues the pageless title above it.
    @Test func dashSubtitleIsMerged() {
        let r = parse("第一章 童年 …… 1\n  父亲的书房\n  ——兼忆八十年代的阅读生活 …… 22\n  母亲 …… 30\n第二章 青年 …… 40\n")
        #expect(r.entries.map(\.title) == ["第一章 童年", "父亲的书房——兼忆八十年代的阅读生活", "母亲", "第二章 青年"])
        #expect(row(r, "父亲的书房——兼忆八十年代的阅读生活")?.level == 1)
    }

    /// c22 / c09 / c16: the misread heading 日录 and a "Chapter … Page" column header are dropped.
    @Test func tocHeadingVariantsAreDropped() {
        let a = parse("日录\n第一章 导论 …… 1\n第二章 方法 …… 9\n第三章 结果 …… 20\n")
        #expect(a.entries.map(\.title) == ["第一章 导论", "第二章 方法", "第三章 结果"])
        let b = parse("Chapter          Page\n1 Introduction\t1\n2 Methods\t9\n3 Results\t20\n")
        #expect(b.entries.map(\.title) == ["1 Introduction", "2 Methods", "3 Results"])
    }

    /// c18: an index (letter heads, comma-separated page lists) is flagged line by line.
    @Test func bookIndexIsFlagged() {
        let r = parse("""
            索引
            A
            阿基米德原理 23, 45
            B
            比热容 31
            边际效用 56
            D
            电磁感应 60, 62
            法拉第定律 64
            G
            惯性系 70
            """, offset: 5)
        #expect(!r.entries.isEmpty)
        #expect(r.entries.allSatisfy { $0.confidence < r.options.lowConfidence })
        #expect(r.warnings.contains { $0.message.contains("book index") })
    }
}
