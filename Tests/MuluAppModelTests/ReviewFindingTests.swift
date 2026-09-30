import CoreGraphics
import Foundation
import MuluCore
import MuluOCR
import Testing
@testable import MuluAppModel

/// Tests for the fixes of the GUI review (writer, undo, review, calibration, input parsing).
@MainActor
@Suite struct ReviewFindingTests {
    static func undoManager() -> UndoManager {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }

    static let printedTOC = """
        第一章 导论 …… 1
        第二章 需求 …… 5
        第三章 供给 …… 11
        第四章 均衡 …… 18
        第五章 福利 …… 26

        """

    // MARK: - Writing

    @Test func leadingHashIsWrittenFullWidthAndVerifiedAgainstTheDraft() async throws {
        let input = try SyntheticBook.plainPDF(pages: 5)
        let out = SyntheticBook.tempURL("hash-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(input, out) }
        let m = DocumentModel(url: input, undoManager: Self.undoManager())
        await m.load()
        let a = m.addSibling(after: nil, title: "#1 Introduction")
        m.setPhysicalPage(a, 2)
        let b = m.addChild(of: a, title: "#child")
        m.setPhysicalPage(b, 3)
        #expect(m.displayRows[0].issues == [.leadingHash])
        #expect(m.displayRows[0].status == .doubtful)
        #expect(m.displayRows[1].issues.isEmpty)  // only a top-level '#' is a comment marker
        #expect(m.writeReadiness().canWrite)
        _ = try await m.write(to: out)
        let items = try PDFFile(bytes: [UInt8](Data(contentsOf: out))).readOutline()
        #expect(items.map(\.title) == ["＃1 Introduction", "#child"])
        m.setConfirmed([a], true)
        #expect(m.displayRows[0].status == .confirmed)
    }

    @Test func aFailedCheckLeavesAnExistingOutputAlone() async throws {
        let input = try SyntheticBook.plainPDF(pages: 4)
        let dir = SyntheticBook.tempURL("verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { SyntheticBook.remove(input, dir) }
        let out = dir.appendingPathComponent("out.pdf")
        let existing = Data("the file the user chose to replace".utf8)
        try existing.write(to: out)

        let fingerprint = try FileFingerprint.of(input)
        let entries = [TOCEntry(title: "A", level: 0, page: 1, line: 1), TOCEntry(title: "B", level: 0, page: 3, line: 2)]
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            try OutlineWriter.write(input: input, fingerprint: fingerprint, entries: entries, output: out) { _, _, _ in
                throw Refused()
            }
        }
        #expect(try Data(contentsOf: out) == existing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.pdf"])  // no temporary file left

        // the real check passes and replaces the file
        let report = try OutlineWriter.write(input: input, fingerprint: fingerprint, entries: entries, output: out)
        #expect(report.items == 2 && report.originalBytesUnchanged)
        let original = try Data(contentsOf: input)
        let written = try Data(contentsOf: out)
        #expect(written.count == original.count + report.appendedBytes && written.prefix(original.count) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.pdf"])
    }

    @Test func verificationComparesWithTheDraft() throws {
        let input = try SyntheticBook.plainPDF(pages: 4)
        let out = SyntheticBook.tempURL("verify-draft-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(input, out) }
        let entries = [TOCEntry(title: "A", level: 0, page: 1, line: 1), TOCEntry(title: "B", level: 1, page: 2, line: 2)]
        _ = try OutlineWriter.write(input: input, fingerprint: try FileFingerprint.of(input), entries: entries, output: out)
        let original = try FileIdentity.readBytes(input)
        try OutlineWriter.verifyWritten(out, original: original, entries: entries)
        var other = entries
        other[1].page = 3
        #expect(throws: WriteError.self) { try OutlineWriter.verifyWritten(out, original: original, entries: other) }
        other = entries
        other[1].title = "B2"
        #expect(throws: WriteError.self) { try OutlineWriter.verifyWritten(out, original: original, entries: other) }
    }

    // MARK: - Undo

    @Test func undoingARecognitionTakesItsNotesAway() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 40)
        defer { SyntheticBook.remove(pdf) }
        let m = DocumentModel(url: pdf, undoManager: Self.undoManager())
        await m.load()
        try m.startRecognition(RecognitionRequest(input: .text(Self.printedTOC), knownOffset: nil, detectOffset: false))
        await m.waitForRecognition()
        m.acceptRecognition(.replace)
        let advisories = m.advisories
        #expect(!advisories.isEmpty)  // the offset was not detected
        guard case .recognitionApplied(count: 5, doubtful: _)? = m.banner else {
            Issue.record("unexpected banner \(String(describing: m.banner))")
            return
        }

        // an ordinary edit and its undo leave the notes alone
        m.setOffset(4)
        m.dismissBanner()
        m.undoManager.undo()
        #expect(m.draft.mapping.offset == 0 && m.banner == nil && m.advisories == advisories)

        // undoing the recognition restores the notes from before it; redo brings them back
        m.undoManager.undo()
        #expect(m.draft.rows.isEmpty && m.advisories.isEmpty && m.banner == nil)
        m.undoManager.redo()
        #expect(m.draft.rows.count == 5 && m.advisories == advisories && m.banner == nil)
    }

    /// A window's undo manager groups by event: its group closes at the end of a run loop pass.
    /// Commits made in separate passes (as two real clicks or key presses are) must stay separate
    /// undo steps. Not async: `RunLoop.run(until:)` is not available in async code, and the pass
    /// needs a timer, because a run loop without sources returns at once.
    @Test func eventGroupedUndoKeepsCommitsOfSeparateTurnsApart() {
        func turnRunLoop() {
            let timer = Timer(timeInterval: 0.01, repeats: false) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let m = DocumentModel(previewRows: Tree.rows(Tree.base), pageCount: 100)
        let window = UndoManager()  // groupsByEvent = true, like a window's
        m.undoManager = window
        let a = Tree.id(m, "A")
        m.setTitle(a, "A one")
        #expect(window.groupingLevel == 1)  // the event group is still open
        turnRunLoop()
        #expect(window.groupingLevel == 0)
        m.setTitle(a, "A two")
        turnRunLoop()
        #expect(window.canUndo)
        window.undo()
        #expect(m.row(a)?.title == "A one")
        window.undo()
        #expect(m.row(a)?.title == "A")
        turnRunLoop()
        window.redo()
        #expect(m.row(a)?.title == "A one")
        turnRunLoop()

        // Two commits in one pass share the event group and undo together (no code path of
        // the app does this; if one ever does, this is the behaviour to expect).
        m.setTitle(a, "A three")
        m.setTitle(a, "A four")
        turnRunLoop()
        window.undo()
        #expect(m.row(a)?.title == "A one")
    }

    // MARK: - Review

    @Test func reviewDoesNotConfirmAnErrorRow() {
        var rows = Tree.rows([("A", 0), ("B", 0), ("C", 0)])
        rows[1].manualPage = nil  // no page: an error
        rows[2].doubts = [DoubtReason(kind: .lowConfidence, detail: "", confidence: 0.4)]
        let m = DocumentModel(previewRows: rows, pageCount: 100)
        m.startReview(onlyDoubtful: true)
        #expect(m.review?.current == rows[1].id)
        #expect(!m.reviewConfirmAndAdvance())
        #expect(m.row(rows[1].id)?.confirmed == false && m.review?.current == rows[1].id)
        m.reviewMove(1)
        #expect(m.reviewConfirmAndAdvance())
        #expect(m.row(rows[2].id)?.confirmed == true && m.review?.finished == true)
    }

    @Test func afterTheDoubtfulPassTheRestCanBeReviewed() {
        var rows = Tree.rows([("A", 0), ("B", 0), ("C", 0), ("D", 0)])
        rows[1].doubts = [DoubtReason(kind: .lowConfidence, detail: "", confidence: 0.4)]
        rows[3].confirmed = true
        let m = DocumentModel(previewRows: rows, pageCount: 100)
        m.startReview(onlyDoubtful: true)
        #expect(m.review?.queue == [rows[1].id])
        m.reviewConfirmAndAdvance()
        #expect(m.review?.finished == true)
        #expect(m.reviewUnseenCount == 2)  // A and C; D is checked already
        #expect(m.continueReviewWithUnseen())
        #expect(m.review?.queue == [rows[0].id, rows[2].id] && m.review?.onlyDoubtful == false)
        #expect(m.review?.current == rows[0].id && m.focusedRowID == rows[0].id)
        m.reviewConfirmAndAdvance()
        m.reviewConfirmAndAdvance()
        #expect(m.review?.finished == true && m.counts.confirmed == 4)
    }

    // MARK: - Finding rows, calibrating from a row on

    @Test func nextRowWithStatusWrapsAround() {
        var rows = Tree.rows([("A", 0), ("B", 0), ("C", 0), ("D", 0)])
        rows[0].doubts = [DoubtReason(kind: .lowConfidence, detail: "", confidence: 0.4)]
        rows[2].manualPage = nil
        let m = DocumentModel(previewRows: rows, pageCount: 100)
        #expect(m.nextRow(withStatus: [.doubtful], after: nil) == rows[0].id)
        #expect(m.nextRow(withStatus: [.doubtful, .error], after: rows[0].id) == rows[2].id)
        #expect(m.nextRow(withStatus: [.doubtful, .error], after: rows[2].id) == rows[0].id)
        #expect(m.nextRow(withStatus: [.confirmed], after: nil) == nil)
        #expect(m.selectNextRow(withStatus: [.error]))
        #expect(m.focusedRowID == rows[2].id && m.selection == [rows[2].id])
    }

    @Test func calibrateFromARowMovesOnlyThatRowAndTheOnesAfterIt() {
        func printed(_ title: String, _ page: Int, level: Int = 0) -> OutlineRow {
            OutlineRow(title: title, level: level, printedPage: PrintedPageRef(style: .arabic, value: page))
        }
        var fixed = printed("图版", 30)
        fixed.manualPage = 40
        let rows = [printed("一", 1), printed("二", 10), printed("三", 20), printed("3.1", 22, level: 1), fixed, printed("四", 31)]
        let m = DocumentModel(previewRows: rows, pageCount: 200, mapping: PageMapping(offset: 8))
        func pages() -> [Int?] { m.draft.rows.map { m.physicalPage(of: $0.id) } }
        #expect(pages() == [9, 18, 28, 30, 40, 39])
        let third = rows[2].id
        #expect(m.canCalibrateFrom(third) && !m.canCalibrateFrom(fixed.id))
        // chapter three really starts on page 30: two unnumbered plates were inserted before it
        #expect(m.calibrateFrom(third, physicalPage: 30))
        #expect(pages() == [9, 18, 30, 32, 40, 41])
        #expect(m.draft.mapping.offset == 8)
        #expect(m.draft.rows[2].sectionShift == 2 && m.draft.rows[4].sectionShift == 0)
        #expect(!m.calibrateFrom(third, physicalPage: 30))  // already there
        m.undoManager.undo()
        #expect(pages() == [9, 18, 28, 30, 40, 39])

        m.select([third], focus: third)
        #expect(m.selectToEnd())
        #expect(m.selection == Set(rows[2...].map(\.id)) && m.focusedRowID == third)
    }

    // MARK: - Input

    @Test func pageRangesTypedWithAChineseInputMethod() throws {
        #expect(PageNumberInput.normalizeRange("3，5，8－9") == "3,5,8-9")
        #expect(PageNumberInput.normalizeRange("５～７") == "5-7")
        #expect(PageNumberInput.normalizeRange("5—7、9") == "5-7,9")
        #expect(PageNumberInput.normalizeRange("5 至 7；9") == "5-7,9")
        #expect(PageNumberInput.normalizeRange("5到7") == "5-7")
        #expect(try parsePageList(PageNumberInput.normalizeRange("3，5，8－9"), pageCount: 20) == [3, 5, 8, 9])
        #expect(PageNumberInput.normalize(" ２２ ") == "22")
        #expect(PageNumberInput.integer("－３") == -3 && PageNumberInput.integer("＋８") == 8)
        #expect(PageNumberInput.integer("−3") == -3 && PageNumberInput.integer("12") == 12)
        #expect(PageNumberInput.integer("abc") == nil && PageNumberInput.integer("") == nil)
    }

    @Test func outlineFilesAreReadWithASizeLimit() async throws {
        let small = SyntheticBook.tempURL("small-\(UUID().uuidString).txt")
        let big = SyntheticBook.tempURL("big-\(UUID().uuidString).txt")
        defer { SyntheticBook.remove(small, big) }
        try Data("A 1\n".utf8).write(to: small)
        try Data(repeating: 0x41, count: 2048).write(to: big)
        #expect(try await DocumentModel.readOutlineFile(at: small, limit: 1024) == Array("A 1\n".utf8))
        await #expect(throws: ImportError.tooLarge(size: 2048, limit: 1024)) {
            _ = try await DocumentModel.readOutlineFile(at: big, limit: 1024)
        }
    }

    // MARK: - Notes

    @Test func parserNotesAreRecognized() {
        let detail = "no page number; using the next entry's page (“第二章 方法”); unnumbered: level from indentation; something new"
        #expect(ParserNote.parse(detail) == [.noPageUsingNext("第二章 方法"), .unnumberedIndentation, .other("something new")])
        #expect(ParserNote.parse("no page number; using the previous entry's page (line 7)") == [.noPageUsingPrevious(nil)])
        #expect(ParserNote.parse("no page number") == [.noPage])
        #expect(ParserNote.parse("page number 12 was split by OCR; title OCR fix: 'a' → 'b'")
            == [.pageSplit("12"), .titleChanged(from: "a", to: "b")])
        #expect(ParserNote.parse(TOCPageReader.unstableNote) == [.unstableTitle])
        #expect(ParserNote.parse("page order: page 3 is out of order (after 9)") == [.pageOrder])
        #expect(ParserNote.parse("") == [])
        #expect(ParserNote.pageNumber(in: "ocr: page 5: two-column layout") == 5)
        #expect(ParserNote.withoutCLIAdvice("ocr: 3 of 9 entries are doubtful (lines 4, 5); review the TOC with --toc-out")
            == "3 of 9 entries are doubtful (lines 4, 5)")
    }

    @Test func notesNameTheEntryInsteadOfAParserLine() {
        let titles = [6: "第二章 方法"]
        #expect(DraftBuilder.namingLines("no page number; using the next entry's page (line 6)", titles)
            == "no page number; using the next entry's page (“第二章 方法”)")
        #expect(DraftBuilder.namingLines("x (line 9) y", titles) == "x (line 9) y")
        #expect(DraftBuilder.namingLines("no line here", titles) == "no line here")
    }

    // MARK: - Thumbnails

    @Test func thumbnailsHonourCancellationAndTheCacheLimit() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 6)
        defer { SyntheticBook.remove(pdf) }
        let one = try ThumbnailRenderer(url: pdf)
        let image = try await one.thumbnail(page: 1, maxPixelWidth: 120)
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        // room for two thumbnails
        let r = try ThumbnailRenderer(url: pdf, cacheByteLimit: cost * 2 + cost / 2)
        for page in 1...4 { _ = try await r.thumbnail(page: page, maxPixelWidth: 120) }
        #expect(await r.cachedByteCount <= r.cacheByteLimit)
        #expect(await r.renderCount == 4)
        _ = try await r.thumbnail(page: 4, maxPixelWidth: 120)  // still cached
        #expect(await r.renderCount == 4)
        _ = try await r.thumbnail(page: 1, maxPixelWidth: 120)  // evicted
        #expect(await r.renderCount == 5)

        let task = Task { try await r.thumbnail(page: 6, maxPixelWidth: 120) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await r.renderCount == 5)
    }
}
