import CryptoKit
import Foundation
import MuluCore
import Testing
@testable import MuluAppModel

@MainActor
@Suite struct DocumentRoundTripTests {
    static func undoManager() -> UndoManager {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// (title, level, page) as written.
    static func projection(_ m: DocumentModel) -> [String] {
        m.draft.rows.map { "\(MuluTOCFormat.oneLine($0.title))|\($0.level)|\(m.draft.mapping.physicalPage(for: $0).map(String.init) ?? "-")" }
    }

    static func outline(_ url: URL) throws -> [String] {
        try PDFFile(bytes: [UInt8](Data(contentsOf: url))).readOutline().map { "\($0.title)|\($0.level)|\(($0.pageIndex ?? -2) + 1)" }
    }

    static let printedTOC = """
        第一章 导论 …… 1
        第二章 需求 …… 5
        第三章 供给 …… 11
        第四章 均衡 …… 18
        第五章 福利 …… 26

        """

    @Test func mainRoundTrip() async throws {
        let input = try SyntheticBook.plainPDF(pages: 40)
        let out = SyntheticBook.tempURL("roundtrip-out-\(UUID().uuidString).pdf")
        let link = SyntheticBook.tempURL("roundtrip-link-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(input, out, link) }
        let inputHash = try Self.sha256(input)

        let m = DocumentModel(url: input, undoManager: Self.undoManager())
        #expect(m.phase == .loading)
        await m.load()
        #expect(m.phase == .ready)
        #expect(m.pageCount == 40 && m.draft.rows.isEmpty && !m.isDirty)
        #expect(m.summary?.existingOutline.isEmpty == true)

        // pasted printed TOC, no offset detection
        try m.startRecognition(RecognitionRequest(input: .text(Self.printedTOC), knownOffset: nil, detectOffset: false))
        await m.waitForRecognition()
        guard case .finished(let result) = m.recognition else {
            Issue.record("recognition did not finish: \(m.recognition)")
            return
        }
        #expect(result.source == .pastedText)
        #expect(result.rows.count == 5)
        #expect(result.rows.map { $0.printedPage?.value } == [1, 5, 11, 18, 26])
        #expect(result.mapping.offset == 0)
        #expect(result.advisories.contains { $0.kind == .offsetUncertain })
        #expect(!m.undoManager.canUndo)  // nothing in the draft yet

        var history: [[String]] = [Self.projection(m)]
        func step(_ label: String, _ body: () -> Void) {
            body()
            history.append(Self.projection(m))
        }
        step("accept") { m.acceptRecognition(.replace) }
        #expect(m.recognition == .idle && m.draft.rows.count == 5 && m.isDirty)
        let ids = m.draft.rows.map(\.id)
        step("offset") { m.setOffset(4) }
        #expect(m.draft.rows.map { m.physicalPage(of: $0.id)! } == [5, 9, 15, 22, 30])
        step("shift") { m.shiftPages([ids[3], ids[4]], by: 2) }
        #expect(m.draft.rows.map { m.physicalPage(of: $0.id)! } == [5, 9, 15, 24, 32])
        step("title") { m.setTitle(ids[0], "第一章  导论与方法") }
        #expect(m.row(ids[0])?.title == "第一章 导论与方法")
        step("indent") { m.indent([ids[1]]) }
        #expect(m.row(ids[1])?.level == 1)
        step("moveUp") { m.moveUp([ids[3]]) }
        #expect(m.draft.rows.map(\.id) == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        m.previewDidShow(page: 38)
        var added = UUID()
        step("add") { added = m.addSibling(after: ids[4], title: "附录 数据") }
        #expect(m.physicalPage(of: added) == 38)
        step("delete") { m.delete([ids[2]]) }
        let final = Self.projection(m)
        #expect(final == ["第一章 导论与方法|0|5", "第二章 需求|1|9", "第四章 均衡|0|24", "第五章 福利|0|32", "附录 数据|0|38"])

        // undo step by step, then redo back
        for k in stride(from: history.count - 1, to: 0, by: -1) {
            #expect(Self.projection(m) == history[k], "before undoing step \(k)")
            m.undoManager.undo()
            #expect(Self.projection(m) == history[k - 1], "after undoing step \(k)")
        }
        #expect(m.draft.rows.isEmpty && !m.isDirty)
        while m.undoManager.canRedo { m.undoManager.redo() }
        #expect(Self.projection(m) == final)

        // write
        let readiness = m.writeReadiness()
        #expect(readiness.canWrite, "\(readiness)")
        #expect(readiness.orderWarnings == 0)
        let report = try await m.write(to: out)
        #expect(report.originalBytesUnchanged && report.appendedBytes > 0 && report.items == 5)
        #expect(report.pageCount == 40 && report.output == out.standardizedFileURL)
        let inBytes = [UInt8](try Data(contentsOf: input))
        let outBytes = [UInt8](try Data(contentsOf: out))
        #expect(report.inputSize == inBytes.count && report.outputSize == outBytes.count)
        #expect(outBytes.count == inBytes.count + report.appendedBytes)
        #expect(Array(outBytes.prefix(inBytes.count)) == inBytes)
        #expect(try Self.outline(out) == final)
        #expect(try Self.sha256(input) == inputHash)
        #expect(!m.isDirty && m.lastWrite == report)
        #expect(m.banner == .wrote(report))
        #expect(m.undoManager.canUndo)  // writing keeps the undo stack

        // again to the same path: replaced
        m.setTitle(added, "附录 数据来源")
        #expect(m.isDirty)
        let again = try await m.write(to: out)
        #expect(again.items == 5 && !m.isDirty)
        #expect(try Self.outline(out).last == "附录 数据来源|0|38")
        #expect(try Self.sha256(input) == inputHash)

        // never the input: directly, through a symbolic link, or a different spelling
        #expect(throws: WriteError.wouldOverwriteInput) { try m.validateOutputURL(input) }
        await #expect(throws: WriteError.wouldOverwriteInput) { try await m.write(to: input) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        #expect(throws: WriteError.wouldOverwriteInput) { try m.validateOutputURL(link) }
        await #expect(throws: WriteError.wouldOverwriteInput) { try await m.write(to: link) }
        let dotted = input.deletingLastPathComponent().appendingPathComponent(".").appendingPathComponent(input.lastPathComponent)
        #expect(throws: WriteError.wouldOverwriteInput) { try m.validateOutputURL(dotted) }
        #expect(try Self.sha256(input) == inputHash)

        #expect(m.defaultOutputURL(suffix: "-目录").lastPathComponent == input.deletingPathExtension().lastPathComponent + "-目录.pdf")
        #expect(m.defaultOutputURL().deletingLastPathComponent() == input.deletingLastPathComponent())
    }

    @Test func existingOutlineIsLoadedAsTheBaseline() async throws {
        let plain = try SyntheticBook.plainPDF(pages: 12)
        let withOutline = SyntheticBook.tempURL("existing-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(plain, withOutline) }
        let applied = try Mulu.apply(pdf: [UInt8](Data(contentsOf: plain)), tocText: "Part One 2\n\tChapter A 3\nPart Two 9\n", offset: 0)
        try Data(applied.output).write(to: withOutline)

        let m = DocumentModel(url: withOutline, undoManager: Self.undoManager())
        await m.load()
        #expect(m.phase == .ready)
        #expect(m.draft.rows.map(\.title) == ["Part One", "Chapter A", "Part Two"])
        #expect(m.draft.rows.map(\.level) == [0, 1, 0])
        #expect(m.draft.rows.map(\.manualPage) == [2, 3, 9])
        #expect(m.summary?.existingOutline.count == 3)
        #expect(m.offsetInfo?.source == .existingOutline)
        #expect(m.banner == .loadedExisting(count: 3))
        #expect(!m.isDirty && !m.undoManager.canUndo)
        // a second load does nothing; concurrent loads share one
        await m.load()
        #expect(m.draft.rows.count == 3 && !m.undoManager.canUndo)
    }

    @Test func unresolvedDestinationsBorrowThePreviousPage() {
        let rows = DocumentLoader.rows(fromOutline: [
            OutlineItemInfo(title: "lost first", level: 0, pageIndex: nil),
            OutlineItemInfo(title: "a", level: 0, pageIndex: 4),
            OutlineItemInfo(title: "lost", level: 2, pageIndex: nil),
        ])
        #expect(rows.map(\.manualPage) == [nil, 5, 5])
        #expect(rows.map(\.level) == [0, 0, 1])  // clamped
        #expect(rows[0].doubts.map(\.kind) == [.unresolvedDestination])
        #expect(rows[2].doubts.map(\.kind) == [.unresolvedDestination])
        #expect(rows[1].doubts.isEmpty)
    }

    @Test func openFailures() async throws {
        let notPDF = SyntheticBook.tempURL("not-a-pdf-\(UUID().uuidString).pdf")
        let missing = SyntheticBook.tempURL("missing-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(notPDF) }
        try Data("hello, not a pdf".utf8).write(to: notPDF)
        let a = DocumentModel(url: notPDF)
        await a.load()
        guard case .failed(.notPDF(let why)) = a.phase else {
            Issue.record("expected notPDF, got \(a.phase)")
            return
        }
        #expect(why.contains("not a PDF"))
        #expect(throws: RecognitionError.notReady) { try a.startRecognition(pages: [1]) }
        let b = DocumentModel(url: missing)
        await b.load()
        guard case .failed(.unreadable) = b.phase else {
            Issue.record("expected unreadable, got \(b.phase)")
            return
        }
    }

    @Test func writeFailures() async throws {
        let input = try SyntheticBook.plainPDF(pages: 5)
        let dir = SyntheticBook.tempURL("readonly-\(UUID().uuidString)")
        defer {
            chmod(dir.path, 0o755)
            SyntheticBook.remove(input, dir)
        }
        let m = DocumentModel(url: input, undoManager: Self.undoManager())
        await m.load()
        let a = m.addSibling(after: nil, title: "A")
        m.setPhysicalPage(a, 2)

        // no such folder
        let nowhere = SyntheticBook.tempURL("no-such-folder-\(UUID().uuidString)").appendingPathComponent("out.pdf")
        await #expect(throws: WriteError.self) { try await m.write(to: nowhere) }
        do {
            _ = try await m.write(to: nowhere)
        } catch let e as WriteError {
            if case .notWritable = e {} else { Issue.record("expected notWritable, got \(e)") }
        }
        // a read-only folder: refused before anything is written, nothing left behind
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o555)
        do {
            _ = try await m.write(to: dir.appendingPathComponent("out.pdf"))
            Issue.record("wrote into a read-only folder")
        } catch let e as WriteError {
            switch e {
            case .notWritable, .io: break
            default: Issue.record("expected notWritable or io, got \(e)")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        // a folder as the output
        #expect(throws: WriteError.self) { try m.validateOutputURL(dir) }

        // blocked rows: empty title, no page, out of range
        let b = m.addSibling(after: nil, title: "")
        let c = m.addSibling(after: nil, title: "C")
        m.setPhysicalPage(c, nil)
        let d = m.addSibling(after: nil, title: "D")
        m.setPhysicalPage(d, 99)
        let blockers = m.writeReadiness().blockers
        #expect(blockers.contains(.row(id: b, index: 1, issue: .emptyTitle)))
        #expect(blockers.contains(.row(id: c, index: 2, issue: .noPhysicalPage)))
        #expect(blockers.contains(.row(id: d, index: 3, issue: .pageOutOfRange(page: 99, pageCount: 5))))
        let out = SyntheticBook.tempURL("blocked-\(UUID().uuidString).pdf")
        do {
            _ = try await m.write(to: out)
            Issue.record("wrote a blocked outline")
        } catch let e as WriteError {
            guard case .blocked(let bs) = e else {
                Issue.record("expected blocked, got \(e)")
                return
            }
            #expect(bs.count == 3)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(throws: WriteError.self) { try m.exportText(format: .mulu) }
        m.delete([b, c, d])

        // the input changed after opening
        let h = try FileHandle(forWritingTo: input)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0x0A]))
        try h.close()
        await #expect(throws: WriteError.inputChanged) { try await m.write(to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        // nothing temporary left next to the output
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".\(out.lastPathComponent).mulu-") }
        #expect(leftovers.isEmpty)
    }

    @Test func refusedByTheWriterIsReportedVerbatim() throws {
        // A draft whose text would not parse can only come from outside the model; the writer
        // still reports MuluCore's own words.
        #expect(WriteError.refused(MuluError.encrypted.description).description == "the PDF is encrypted; refusing to modify it")
        #expect(WriteError.inputChanged.description.contains("changed"))
    }
}
