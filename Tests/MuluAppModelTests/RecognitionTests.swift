import Foundation
import MuluCore
import Testing
@testable import MuluAppModel

/// End-to-end recognition on generated scans (Vision). Serialized: OCR is CPU-heavy.
@MainActor
@Suite(.serialized) struct RecognitionTests {
    static func undoManager() -> UndoManager {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }

    static func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// Generates the book off the main actor (rasterizing 35+ pages takes seconds).
    nonisolated static func makeBook(tocCopies: Int = 1, folios: Bool = true, runningHeads: Bool = true, name: String) async throws
        -> (url: URL, tocPages: [Int], offset: Int, entries: [(title: String, printed: Int, level: Int)]) {
        try await Task.detached {
            try SyntheticBook.scannedBook(tocCopies: tocCopies, folios: folios, runningHeads: runningHeads, name: name)
        }.value
    }

    @Test func recognizesTheSyntheticScannedBook() async throws {
        let book = try await Self.makeBook(name: "rec-\(UUID().uuidString)")
        let out = SyntheticBook.tempURL("rec-out-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(book.url, out) }
        let m = DocumentModel(url: book.url, undoManager: Self.undoManager())
        await m.load()
        #expect(m.pageCount == 35)
        try m.setTOCPages(spec: "2")
        #expect(m.tocPages == book.tocPages && m.tocPagesSpec == "2")
        try m.startRecognition(pages: book.tocPages)
        #expect(throws: RecognitionError.alreadyRunning) { try m.startRecognition(pages: book.tocPages) }
        await m.waitForRecognition()
        guard case .finished(let r) = m.recognition else {
            Issue.record("recognition did not finish: \(m.recognition)")
            return
        }
        #expect(r.source == .ocr && r.tocPages == [2])
        #expect(r.rows.count == book.entries.count, "\(r.rows.map(\.title))")
        for (row, e) in zip(r.rows, book.entries) {
            #expect(similarity(Self.squash(row.title), Self.squash(e.title)) >= 0.9, "\(row.title) vs \(e.title)")
            #expect(row.level == e.level, "\(row.title)")
            #expect(row.printedPage == PrintedPageRef(style: .arabic, value: e.printed), "\(row.title)")
        }
        #expect(r.mapping.offset == book.offset)
        #expect(r.offsetInfo.source == .detected, "\(r.offsetInfo) \(r.advisories)")
        #expect((r.offsetInfo.evidence?.agreeing ?? 0) >= 6)
        #expect(r.doubtfulCount == 0, "\(r.rows.map(\.doubts))")
        #expect(r.autoWouldAccept, "\(r.advisories)")
        #expect(r.muluText.hasPrefix("# Mulu TOC from a printed TOC: physical page = printed page + 3\n"))

        // progress: reading the TOC and detecting the offset were reported, never going back
        let log = m.recognitionProgressLog
        #expect(log.contains { $0.phase == .readingTOC })
        #expect(log.contains { $0.phase == .detectingOffset })
        #expect(zip(log, log.dropFirst()).allSatisfy { $0.fraction <= $1.fraction }, "\(log.map(\.fraction))")
        #expect(log.last?.fraction == 1)

        m.acceptRecognition(.replace)
        #expect(m.draft.rows.count == 6 && m.draft.mapping.offset == 3)
        #expect(m.offsetInfo?.source == .detected)
        #expect(m.banner == .recognitionApplied(count: 6, doubtful: 0))
        let report = try await m.write(to: out)
        #expect(report.items == 6 && report.originalBytesUnchanged)
        let items = try PDFFile(bytes: [UInt8](Data(contentsOf: out))).readOutline()
        #expect(items.map(\.pageIndex) == book.entries.map { Optional($0.printed + book.offset - 1) })
        #expect(items.map(\.level) == book.entries.map(\.level))
    }

    @Test func cancelStopsAtTheNextPage() async throws {
        let book = try await Self.makeBook(tocCopies: 6, name: "cancel-\(UUID().uuidString)")
        defer { SyntheticBook.remove(book.url) }
        #expect(book.tocPages == [2, 3, 4, 5, 6, 7])
        let m = DocumentModel(url: book.url, undoManager: Self.undoManager())
        await m.load()
        let before = m.draft
        try m.startRecognition(pages: book.tocPages)
        // wait for the first progress report of the TOC reader itself
        let clock = ContinuousClock()
        let waitStart = clock.now
        while !m.recognitionProgressLog.dropFirst().contains(where: { $0.phase == .readingTOC }), clock.now - waitStart < .seconds(30) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(m.recognitionProgressLog.dropFirst().contains { $0.phase == .readingTOC })
        let cancelledAt = clock.now
        m.cancelRecognition()
        await m.waitForRecognition()
        let took = clock.now - cancelledAt
        #expect(m.recognition == .cancelled)
        #expect(took < .seconds(5), "cancellation took \(took)")
        print("cancelStopsAtTheNextPage: cancellation took \(took)")
        #expect(m.draft == before && !m.undoManager.canUndo)
        // it can start again
        m.discardRecognition()
        #expect(m.recognition == .idle)
        try m.startRecognition(RecognitionRequest(input: .text("第一章 甲 1\n第二章 乙 5\n第三章 丙 9\n"), knownOffset: 3, detectOffset: false))
        await m.waitForRecognition()
        guard case .finished(let r) = m.recognition else {
            Issue.record("second recognition did not finish: \(m.recognition)")
            return
        }
        #expect(r.rows.count == 3 && r.mapping.offset == 3 && r.offsetInfo.source == .given)
    }

    @Test func unknownOffsetStillGivesADraft() async throws {
        // No folios and no running heads: the offset cannot be read anywhere (and the detector
        // has no ink to re-read, which keeps the test fast).
        let book = try await Self.makeBook(folios: false, runningHeads: false, name: "nofolio-\(UUID().uuidString)")
        defer { SyntheticBook.remove(book.url) }
        let m = DocumentModel(url: book.url, undoManager: Self.undoManager())
        await m.load()
        try m.startRecognition(pages: book.tocPages)
        await m.waitForRecognition()
        guard case .finished(let r) = m.recognition else {
            Issue.record("recognition did not finish: \(m.recognition)")
            return
        }
        #expect(r.rows.count == book.entries.count, "\(r.rows.map(\.title))")
        #expect([OffsetSource.bestGuess, .none].contains(r.offsetInfo.source), "\(r.offsetInfo)")
        #expect(r.advisories.contains { $0.kind == .offsetUncertain && $0.blocksAuto })
        #expect(!r.autoWouldAccept)
        m.acceptRecognition(.replace)
        let first = m.draft.rows[0]
        #expect(m.canCalibrate(using: first.id))
        #expect(m.calibrateOffset(using: first.id, physicalPage: 4))
        #expect(m.draft.mapping.offset == 3)
        #expect(m.offsetInfo?.source == .calibrated && m.offsetInfo?.calibratedFromPage == 4)
        #expect(m.draft.rows.map { m.physicalPage(of: $0.id) } == book.entries.map { Optional($0.printed + 3) })
    }

    @Test func requestValidation() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 50)
        defer { SyntheticBook.remove(pdf) }
        let m = DocumentModel(url: pdf, undoManager: Self.undoManager())
        #expect(throws: RecognitionError.notReady) { try m.startRecognition(pages: [1]) }
        await m.load()
        #expect(throws: RecognitionError.noPages) { try m.startRecognition(pages: []) }
        #expect(throws: RecognitionError.noPages) { try m.startRecognition() }  // no TOC pages marked
        #expect(throws: RecognitionError.tooManyPages(41)) { try m.startRecognition(pages: Array(1...41)) }
        #expect(throws: RecognitionError.self) { try m.startRecognition(pages: [51]) }
        #expect(throws: RecognitionError.self) { try m.setTOCPages(spec: "9-3") }
        #expect(throws: RecognitionError.tooManyPages(45)) { try m.setTOCPages(spec: "1-45") }
        try m.setTOCPages(spec: "5-7, 9")
        #expect(m.tocPages == [5, 6, 7, 9] && m.tocPagesSpec == "5-7,9")
        m.toggleTOCPage(8)
        #expect(m.tocPagesSpec == "5-9")
        m.toggleTOCPage(5)
        m.toggleTOCPage(99)  // out of range: ignored
        #expect(m.tocPagesSpec == "6-9")
        try m.setTOCPages(spec: "")
        #expect(m.tocPages.isEmpty)
        #expect(m.recognition == .idle && !m.undoManager.canUndo)

        let preview = DocumentModel(previewRows: [], pageCount: 10)
        #expect(throws: RecognitionError.notReady) { try preview.startRecognition(pages: [1]) }
    }

    /// Pasted text needs no OCR: the refusals of `mulu auto` become advisories.
    @Test func pastedTextAdvisories() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 20)
        defer { SyntheticBook.remove(pdf) }
        let m = DocumentModel(url: pdf, undoManager: Self.undoManager())
        await m.load()
        try m.startRecognition(RecognitionRequest(input: .text("前言 …… iii\n第一章 甲 …… 1\n第二章 乙 …… 40\n"), knownOffset: 2, detectOffset: false))
        await m.waitForRecognition()
        guard case .finished(let r) = m.recognition else {
            Issue.record("recognition did not finish: \(m.recognition)")
            return
        }
        let kinds = Set(r.advisories.map(\.kind))
        #expect(kinds.contains(.fewEntries))          // 2 arabic pages (need 3)
        #expect(kinds.contains(.romanUnresolved))     // front matter not searched
        #expect(!r.autoWouldAccept)
        #expect(r.rows.count == 3)
        #expect(r.rows[0].printedPage?.style == .roman && r.rows[0].doubts.contains { $0.kind == .noPage })
        #expect(r.rows[2].doubts.contains { $0.kind == .noPage })  // 40 + 2 > 20 pages
        m.acceptRecognition(.replace)
        #expect(m.displayRows[0].issues == [.noPhysicalPage])
        #expect(m.displayRows[2].issues == [.pageOutOfRange(page: 42, pageCount: 20)])
        #expect(m.counts.errors == 2)

        // empty text: noText, nothing else
        try m.startRecognition(RecognitionRequest(input: .text("  \n"), knownOffset: nil, detectOffset: false))
        await m.waitForRecognition()
        guard case .finished(let empty) = m.recognition else {
            Issue.record("recognition did not finish: \(m.recognition)")
            return
        }
        #expect(empty.rows.isEmpty && empty.advisories.map(\.kind) == [.noText] && !empty.autoWouldAccept)
    }

    @Test func appendAndInsertKeepPhysicalPages() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 60)
        defer { SyntheticBook.remove(pdf) }
        let m = DocumentModel(url: pdf, undoManager: Self.undoManager())
        await m.load()
        try m.startRecognition(RecognitionRequest(input: .text("第一章 甲 1\n第二章 乙 5\n第三章 丙 9\n"), knownOffset: 2, detectOffset: false))
        await m.waitForRecognition()
        m.acceptRecognition(.replace)
        #expect(m.draft.mapping.offset == 2)
        let first = m.draft.rows[0].id
        // a second result with another offset, inserted after the first chapter's block at its level
        try m.startRecognition(RecognitionRequest(input: .text("第一节 子 2\n第二节 丑 3\n第三节 寅 4\n"), knownOffset: 10, detectOffset: false))
        await m.waitForRecognition()
        m.select([first], focus: first)
        m.acceptRecognition(.insertAfterFocused)
        #expect(m.draft.rows.map(\.title) == ["第一章 甲", "第一节 子", "第二节 丑", "第三节 寅", "第二章 乙", "第三章 丙"])
        #expect(m.draft.rows.map(\.level) == [0, 0, 0, 0, 0, 0])
        #expect(m.draft.mapping.offset == 2)
        #expect(m.draft.rows.map { m.physicalPage(of: $0.id)! } == [3, 12, 13, 14, 7, 11])
        // append at the end, level 0
        try m.startRecognition(RecognitionRequest(input: .text("附录一 表 50\n附录二 图 51\n附录三 注 52\n"), knownOffset: 0, detectOffset: false))
        await m.waitForRecognition()
        m.acceptRecognition(.append)
        #expect(Array(m.draft.rows.suffix(3).map { m.physicalPage(of: $0.id)! }) == [50, 51, 52])
        #expect(Array(m.draft.rows.suffix(3).map(\.level)) == [0, 0, 0])
        // one undo step each
        m.undoManager.undo()
        m.undoManager.undo()
        #expect(m.draft.rows.count == 3)
    }
}
