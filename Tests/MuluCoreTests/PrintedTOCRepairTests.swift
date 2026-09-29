import Foundation
import Testing
@testable import MuluCore

/// OCR repairs of the numbering text and of wrapped titles in OCR output (no leaders).
@Suite struct PrintedTOCRepairTests {
    @Test func numberingSlipsAreRepaired() {
        #expect(HeadingClassifier.repairNumbering("1:1.2 计算实例")?.title == "1.1.2 计算实例")
        #expect(HeadingClassifier.repairNumbering("3.1.1.配置示例")?.title == "3.1.1 配置示例")
        #expect(HeadingClassifier.repairNumbering("Part Iil Running in Production")?.title == "Part III Running in Production")
        #expect(HeadingClassifier.repairNumbering("第二节 ⋅赋役制度")?.title == "第二节 赋役制度")
    }

    @Test func correctNumberingIsLeftAlone() {
        for t in ["1.1.2 计算实例", "1-1 集合", "2-3 习题", "Part I Foundations", "Part II", "Chapter 1 Getting Started",
                  "第一章 绪论", "3.1.1 配置示例", "1.2. 引言", "Section 2.3 Timers", "Windows 10 入门", "· 引子"] {
            #expect(HeadingClassifier.repairNumbering(t) == nil, "\(t)")
        }
    }

    @Test func lostOrdinalIsRestoredFromNeighbours() {
        let text = """
            第一篇 先秦\t1
            第一章 夏商周\t1
            第二章 春秋战国\t9
            第二篇 秦汉\t20
            第章 秦的统一\t21
            第二章 两汉\t30
            第三章 三国\t40
            第节 群雄\t41
            第二节 鼎立\t45
            """
        let r = PrintedTOCParser.parse(text)
        #expect(r.entries.map(\.title) == ["第一篇 先秦", "第一章 夏商周", "第二章 春秋战国", "第二篇 秦汉", "第一章 秦的统一",
                                           "第二章 两汉", "第三章 三国", "第一节 群雄", "第二节 鼎立"])
        #expect(r.entries.map(\.level) == [0, 1, 1, 0, 1, 1, 1, 2, 2])
    }

    @Test func conflictingNeighboursLeaveTheOrdinalOut() {
        // 第三章 … 第章 … 第六章: 4 or 5? Not guessed.
        let r = PrintedTOCParser.parse("第三章 甲\t1\n第章 乙\t5\n第六章 丙\t9\n")
        #expect(r.entries[1].title == "第章 乙")
    }

    @Test func lostClosingBracketNeedsSiblings() {
        let text = "（一）原理\t1\n（二定投的原理\t3\n（三）实践\t5\n"
        #expect(PrintedTOCParser.parse(text).entries.map(\.title) == ["（一）原理", "（二）定投的原理", "（三）实践"])
        // a lone "（一般…" title is not numbering
        #expect(PrintedTOCParser.parse("（一般原理）\t1\n结论\t3\n").entries[0].title == "（一般原理）")
    }

    @Test func wrappedTitleInOCROutputIsMerged() {
        // `mulu ocr-toc` output: leaders removed, the continuation indented like a child.
        let text = """
            前言\ti
            第一章 新时代基层社会治理体系和治理能力现代化的理论基础与历
                史演进\t1
              第一节 区域化党建联席会议制度在跨部门协调中的实际运行状况调查\t3
              第二节 改革开放以来我国基层治理体制机制演变的主要阶段与基本经验\t5
            第二章 城乡基层治理中党建引领机制的形成逻辑与运行方式\t6
              第一节 基于十二个城市社区问卷调查数据的治理成效实证分析\t11
            第三章 短\t14
            """
        let r = PrintedTOCParser.parse(text)
        #expect(r.entries.map(\.title)[1] == "第一章 新时代基层社会治理体系和治理能力现代化的理论基础与历史演进")
        #expect(r.entries.count == 7)
        #expect(r.entries.map(\.level) == [0, 0, 1, 1, 0, 1, 0])
    }

    @Test func shortPagelessHeadingIsNotMerged() {
        let text = """
            第一辑 故园
              北方的冬天\t41
              灯下\t44
              父亲的手表\t47
              春分\t50
              远去的邻居\t53
            """
        let r = PrintedTOCParser.parse(text)
        #expect(r.entries.map(\.title) == ["第一辑 故园", "北方的冬天", "灯下", "父亲的手表", "春分", "远去的邻居"])
    }
}
