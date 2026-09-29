import Foundation
import Testing
@testable import MuluOCR

/// Pure rules behind `mulu auto` and the title vote (no Vision).
@Suite struct TitleVoteTests {
    @Test func lostCharactersAreRecovered() {
        let r = TOCPageReader.voteTitle(primary: "第三章 消费者行理论", alternates: ["第三章 消费者行为理论", "第三章 消费者行为理论"])
        #expect(r?.0 == "第三章 消费者行为理论")
        // one alternate is enough when the other has no reading or agrees with the primary
        #expect(TOCPageReader.voteTitle(primary: "之", alternates: ["之二", nil])?.0 == "之二")
        #expect(TOCPageReader.voteTitle(primary: "第章两汉的政治与经济", alternates: ["第一章 两汉的政治与经济", "第章两汉的政治与经济"])?.0
                == "第一章 两汉的政治与经济")
    }

    @Test func substitutionsAndSeparateWordsAreNotTaken() {
        // Both re-readings misread 荣 as 菜: never substitute.
        #expect(TOCPageReader.voteTitle(primary: "第三章 隋唐的繁荣", alternates: ["第三章 隋唐的繁菜", "第三章 隋唐的繁菜"]) == nil)
        // An added word of its own is a misread leader or page number.
        #expect(TOCPageReader.voteTitle(primary: "4.2.1状态转换", alternates: ["4.2.1状态转换 學", nil]) == nil)
        // Added marks are not characters.
        #expect(TOCPageReader.voteTitle(primary: "三、史料", alternates: ["三、.史料", "三、.史料"]) == nil)
        // A longer alternate that is not part of the other contradicts it.
        #expect(TOCPageReader.voteTitle(primary: "边治理", alternates: ["边疆治理", "边境治理"]) == nil)
        // Latin additions are not taken (only CJK ideographs are dropped silently by Vision).
        #expect(TOCPageReader.voteTitle(primary: "Runing", alternates: ["Running", "Running"]) == nil)
    }

    @Test func strayMarksNeedBothAlternates() {
        #expect(TOCPageReader.voteTitle(primary: "第二节⋅赋役制度", alternates: ["第二节 赋役制度", "第二节 赋役制度"])?.0 == "第二节 赋役制度")
        #expect(TOCPageReader.voteTitle(primary: "第二节⋅赋役制度", alternates: ["第二节 赋役制度", nil]) == nil)
    }

    @Test func emptyTitleIsFilledOnlyWithoutDisagreement() {
        #expect(TOCPageReader.voteTitle(primary: "", alternates: [nil, "之二"])?.0 == "之二")
        #expect(TOCPageReader.voteTitle(primary: "", alternates: ["之一", "之二"]) == nil)
        #expect(TOCPageReader.voteTitle(primary: "", alternates: [nil, nil]) == nil)
    }

    @Test func unstableTitles() {
        // no other resolution reproduces the letters: unstable
        #expect(TOCPageReader.titleUnstable("第 竹 化学性质", alternates: ["节化，枸顾", "第书化学性"]))
        // one agreeing reading is enough; marks and spaces do not count
        #expect(!TOCPageReader.titleUnstable("第一节 化学性质", alternates: ["第一节·化学性质", "第一节 化学性"]))
        // nothing to compare with: not flagged
        #expect(!TOCPageReader.titleUnstable("第一节 化学性质", alternates: [nil, nil]))
        #expect(!TOCPageReader.titleUnstable("", alternates: ["之一", nil]))
    }

    @Test func titleFromTakesTheObservationsOfTheLine() {
        let obs = [box("第一章 绪论", 200, 1000, 500, 1045), box("……", 520, 1010, 1700, 1040), box("12", 1800, 1004, 1830, 1036),
                   box("第一节 背景", 260, 1080, 520, 1125)]
        let t = TOCPageReader.titleFrom(obs, line: PixelRect(minX: 1800, minY: 1004, maxX: 1830, maxY: 1036),
                                        leftLimit: 150, rightLimit: 1780, charH: 40)
        #expect(t?.title == "第一章 绪论")
        #expect(t?.minX == 200)
    }
}

@Suite struct MisreadTailTests {
    func line(_ parts: [(String, Double, Double)]) -> TextLine {
        TextLine(members: parts.map { box($0.0, $0.1, 1000, $0.2, 1040) })
    }

    @Test func dropsANumberReadIntoTheColumn() {
        let l = line([("Acknowledgments", 200, 560), ("×11", 1790, 1830)])
        // the caller passes the column edge minus one character height
        let r = TOCPageReader.dropMisreadTail("Acknowledgments ×11", line: l, columnMinX: 1790 - 40)
        #expect(r?.rest == "Acknowledgments" && r?.tail == "×11")
        let split = line([("1.4量效关系", 260, 600), ("1", 1790, 1805), ("0", 1810, 1825)])
        #expect(TOCPageReader.dropMisreadTail("1.4量效关系 1 0", line: split, columnMinX: 1700)?.rest == "1.4量效关系")
    }

    @Test func keepsTitleWordsLeftOfTheColumn() {
        let l = line([("Windows 10 ........", 200, 1790)])
        #expect(TOCPageReader.dropMisreadTail("Windows 10", line: l, columnMinX: 1700) == nil)
        let p = line([("Part II", 200, 400)])
        #expect(TOCPageReader.dropMisreadTail("Part II", line: p, columnMinX: 1700) == nil)
    }
}

@Suite struct FrontMatterTests {
    @Test func romanOffsetNeedsTwoAgreeingPages() {
        #expect(RomanOffsetVoter.vote([(page: 7, value: 3), (page: 8, value: 4), (page: 9, value: 5)]).offset == 4)
        #expect(RomanOffsetVoter.vote([(page: 7, value: 3)]).offset == nil)
        // 1 vs 1: no winner; 2 vs 1 is not twice the runner-up... 3 vs 1 is.
        #expect(RomanOffsetVoter.vote([(page: 7, value: 3), (page: 8, value: 1)]).offset == nil)
        #expect(RomanOffsetVoter.vote([(page: 5, value: 1), (page: 6, value: 2), (page: 7, value: 3), (page: 8, value: 1)]).offset == 4)
        #expect(RomanOffsetVoter.vote([]).offset == nil)
    }

    @Test func headingMatchIsExactForShortTitles() {
        #expect(HeadingLocator.matches(lines: ["前言"], title: "前 言"))
        #expect(!HeadingLocator.matches(lines: ["前言部分"], title: "前言"))
        #expect(!HeadingLocator.matches(lines: ["本书序言"], title: "序"))
        // two-line chapter heading: 第一章 over 绪论
        #expect(HeadingLocator.matches(lines: ["第一章", "绪论"], title: "第一章 绪论"))
        // longer titles tolerate one OCR slip in five characters
        #expect(HeadingLocator.matches(lines: ["chapter2planningyournetwork"], title: "Chapter 2 Planning Your Netwrk"))
        #expect(!HeadingLocator.matches(lines: ["chapter3routersandaccesspoints"], title: "Chapter 2 Planning Your Network"))
    }
}
