import Foundation
import Testing
@testable import MuluAppModel

@MainActor
@Suite struct MappingTests {
    static func arabic(_ v: Int) -> PrintedPageRef { PrintedPageRef(style: .arabic, value: v) }
    static func roman(_ v: Int) -> PrintedPageRef { PrintedPageRef(style: .roman, value: v) }

    @Test func physicalPages() {
        let map = PageMapping(offset: 3, romanOffset: nil)
        #expect(map.physicalPage(for: OutlineRow(title: "a", level: 0, printedPage: Self.arabic(5))) == 8)
        #expect(map.physicalPage(for: OutlineRow(title: "a", level: 0, printedPage: Self.arabic(5), sectionShift: 2)) == 10)
        #expect(map.physicalPage(for: OutlineRow(title: "r", level: 0, printedPage: Self.roman(2))) == nil)
        #expect(PageMapping(offset: 3, romanOffset: 4).physicalPage(for: OutlineRow(title: "r", level: 0, printedPage: Self.roman(2))) == 6)
        #expect(map.physicalPage(for: OutlineRow(title: "m", level: 0, printedPage: Self.arabic(5), manualPage: 11)) == 11)
        #expect(map.physicalPage(for: OutlineRow(title: "n", level: 0)) == nil)
        #expect(Self.roman(4).display == "iv" && Self.roman(14).display == "xiv" && Self.arabic(12).display == "12")
    }

    @Test func offsetMovesPrintedRowsOnly() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "printed", level: 0, printedPage: Self.arabic(5)),
            OutlineRow(title: "fixed", level: 0, printedPage: Self.arabic(9), manualPage: 10),
            OutlineRow(title: "front", level: 0, printedPage: Self.roman(2)),
        ], pageCount: 50)
        let ids = m.draft.rows.map(\.id)
        #expect(m.setOffset(7))
        #expect(m.physicalPage(of: ids[0]) == 12)
        #expect(m.physicalPage(of: ids[1]) == 10)  // pinned
        #expect(m.physicalPage(of: ids[2]) == nil)
        #expect(m.offsetInfo?.source == .manual)
        #expect(!m.setOffset(7))  // unchanged: no undo step
        #expect(m.setRomanOffset(3))
        #expect(m.physicalPage(of: ids[2]) == 5)
        m.undoManager.undo()
        #expect(m.physicalPage(of: ids[2]) == nil)
        m.undoManager.undo()
        #expect(m.physicalPage(of: ids[0]) == 5 && m.draft.mapping.offset == 0)
    }

    @Test func shiftPagesMovesTheBlock() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "ch", level: 0, printedPage: Self.arabic(5)),
            OutlineRow(title: "fixed child", level: 1, manualPage: 7),
            OutlineRow(title: "no page", level: 2, printedPage: Self.roman(1)),
            OutlineRow(title: "next", level: 0, printedPage: Self.arabic(20)),
        ], pageCount: 50, mapping: PageMapping(offset: 1))
        let ids = m.draft.rows.map(\.id)
        #expect(m.shiftPages([ids[0]], by: 2))
        #expect(m.draft.rows[0].sectionShift == 2 && m.physicalPage(of: ids[0]) == 8)
        #expect(m.draft.rows[1].manualPage == 9 && m.draft.rows[1].sectionShift == 0)
        #expect(m.draft.rows[2].sectionShift == 0 && m.physicalPage(of: ids[2]) == nil)
        #expect(m.physicalPage(of: ids[3]) == 21)  // not selected
        #expect(!m.shiftPages([ids[2]], by: 1))    // a row without a page stays
        #expect(!m.shiftPages([ids[0]], by: 0))
    }

    @Test func calibrate() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "ch", level: 0, printedPage: Self.arabic(12), sectionShift: 1, doubts: [DoubtReason(kind: .pageOrder)]),
            OutlineRow(title: "fixed", level: 0, printedPage: Self.arabic(14), manualPage: 30),
            OutlineRow(title: "front", level: 0, printedPage: Self.roman(3)),
            OutlineRow(title: "other", level: 0, printedPage: Self.arabic(15)),
        ], pageCount: 50)
        let ids = m.draft.rows.map(\.id)
        #expect(m.canCalibrate(using: ids[0]))
        #expect(!m.canCalibrate(using: ids[1]) && !m.canCalibrate(using: ids[2]))
        #expect(!m.calibrateOffset(using: ids[1], physicalPage: 20))
        #expect(m.calibrateOffset(using: ids[0], physicalPage: 20))
        #expect(m.draft.mapping.offset == 7)
        #expect(m.physicalPage(of: ids[0]) == 20)
        #expect(m.physicalPage(of: ids[3]) == 22)
        #expect(m.draft.rows[0].doubts.isEmpty)  // a page edit clears page-scoped doubts
        #expect(m.offsetInfo == OffsetInfo(source: .calibrated, calibratedFromPage: 20))
    }

    @Test func rowIssues() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "ok", level: 0, manualPage: 5),
            OutlineRow(title: "earlier", level: 0, manualPage: 3),
            OutlineRow(title: "beyond", level: 0, printedPage: Self.arabic(9), manualPage: nil),
            OutlineRow(title: "  ", level: 0, manualPage: 6),
            OutlineRow(title: "none", level: 0),
            OutlineRow(title: "zero", level: 0, manualPage: 0),
        ], pageCount: 10, mapping: PageMapping(offset: 3))
        let rows = m.displayRows
        #expect(rows[0].issues.isEmpty && rows[0].status == .ok)
        #expect(rows[1].issues == [.pageBeforePrevious(previous: 5)] && rows[1].status == .doubtful)
        #expect(!RowIssue.pageBeforePrevious(previous: 5).blocksWrite)
        #expect(rows[2].issues == [.pageOutOfRange(page: 12, pageCount: 10)] && rows[2].status == .error)
        #expect(rows[3].issues.contains(.emptyTitle) && rows[3].status == .error)
        #expect(rows[4].issues == [.noPhysicalPage] && rows[4].status == .error)
        #expect(rows[5].issues.contains(.pageOutOfRange(page: 0, pageCount: 10)))
        #expect(m.counts == DraftCounts(rows: 6, doubtful: 1, confirmed: 0, errors: 4))
        let readiness = m.writeReadiness()
        #expect(readiness.blockers.first == .notReady)  // a preview model never writes
        let rowBlockers = readiness.blockers.compactMap { b -> Int? in if case let .row(_, i, _) = b { return i } else { return nil } }
        #expect(Set(rowBlockers) == [2, 3, 4, 5])
        #expect(readiness.orderWarnings == 1)
        #expect(!readiness.canWrite)
    }

    @Test func doubtsClearByScope() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "t", level: 0, manualPage: 4, doubts: [
                DoubtReason(kind: .unstableTitle), DoubtReason(kind: .pageOrder), DoubtReason(kind: .lowConfidence, confidence: 0.5),
            ]),
            OutlineRow(title: "hint", level: 0, manualPage: 5, doubts: [DoubtReason(kind: .locatedFromHeading)]),
        ], pageCount: 10)
        let id = m.draft.rows[0].id
        #expect(m.displayRows[0].status == .doubtful)
        #expect(m.displayRows[1].status == .ok)  // a hint is not a doubt
        #expect(m.setTitle(id, "t2"))
        #expect(m.row(id)?.doubts.map(\.kind) == [.pageOrder, .lowConfidence])
        #expect(m.setPhysicalPage(id, 6))
        #expect(m.row(id)?.doubts.map(\.kind) == [.lowConfidence])
        #expect(m.displayRows[0].status == .doubtful)  // title + page scope: only a check resolves it
        #expect(m.setConfirmed([id], true))
        #expect(m.displayRows[0].status == .confirmed && m.row(id)?.doubts.count == 1)
        #expect(m.counts.confirmed == 1)
        // the page field: nil clears the pin, a non-positive page is refused
        #expect(!m.setPhysicalPage(id, 0) && !m.setPhysicalPage(id, -3))
        #expect(m.setPhysicalPage(id, nil))
        #expect(m.row(id)?.manualPage == nil && m.displayRows[0].issues == [.noPhysicalPage])
    }

    @Test func dirtyLooksOnlyAtWhatWouldBeWritten() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "a", level: 0, manualPage: 1),
            OutlineRow(title: "b", level: 1, manualPage: 2),
        ], pageCount: 10)
        let ids = m.draft.rows.map(\.id)
        #expect(!m.isDirty)
        m.setConfirmed(Set(ids), true)
        #expect(!m.isDirty)
        m.setOffset(5)  // every row is pinned: no physical page changes
        #expect(!m.isDirty)
        m.toggleExpanded(ids[0])
        #expect(!m.isDirty && m.displayRows.count == 1)
        m.setTitle(ids[1], "b2")
        #expect(m.isDirty)
        m.setTitle(ids[1], "b")
        #expect(!m.isDirty)  // back to the written state
        m.setTitle(ids[1], "  b   ")  // normalizes to the same title: no change
        #expect(!m.isDirty)
        m.undoManager.undo()
        #expect(m.isDirty && m.row(ids[1])?.title == "b2")
    }

    @Test func previewFollowsTheFocusedRow() {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "a", level: 0, printedPage: Self.arabic(4)),
            OutlineRow(title: "b", level: 0, printedPage: Self.arabic(9)),
        ], pageCount: 30)
        let ids = m.draft.rows.map(\.id)
        m.select([ids[1]], focus: ids[1])
        let first = m.previewRequest
        #expect(first?.page == 9 && m.previewPage == 9)
        m.select([ids[1]], focus: ids[1])  // the same page again still asks (new serial)
        #expect(m.previewRequest?.page == 9 && m.previewRequest?.serial != first?.serial)
        m.setOffset(2)
        #expect(m.previewRequest?.page == 11)
        m.undoManager.undo()
        #expect(m.previewRequest?.page == 9)
        m.previewDidShow(page: 14)
        #expect(m.pinToPreviewPage(ids[1]))
        #expect(m.physicalPage(of: ids[1]) == 14 && m.row(ids[1])?.pageOverride == true)
        #expect(m.clearOverride([ids[1]]))
        #expect(m.physicalPage(of: ids[1]) == 9)
    }

    @Test func expansion() {
        let m = Tree.model()
        let a = Tree.id(m, "A"), a2 = Tree.id(m, "A2")
        m.setExpanded(a2, false)
        #expect(m.displayRows.map(\.title) == ["A", "A1", "A2", "A3", "B", "B1", "C"])
        m.toggleExpanded(a)
        #expect(m.displayRows.map(\.title) == ["A", "B", "B1", "C"])
        #expect(m.displayRows[0].hasChildren && !m.displayRows[0].isExpanded)
        m.collapseAll()
        #expect(m.displayRows.map(\.title) == ["A", "B", "C"])
        m.expandAll()
        #expect(m.displayRows.count == 8)
        #expect(!m.undoManager.canUndo)  // not undoable
        m.collapseAll()
        m.select([Tree.id(m, "A2a")], focus: Tree.id(m, "A2a"))
        m.startReview(onlyDoubtful: false)  // review reveals the current row
        #expect(m.displayRows.contains { $0.title == m.row(m.review!.current!)?.title })
    }
}
