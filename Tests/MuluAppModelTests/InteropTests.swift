import Foundation
import MuluCore
import Testing
@testable import MuluAppModel

@MainActor
@Suite struct InteropTests {
    /// Mixed rows: fixed and printed pages, three levels, titles that need escaping or
    /// normalizing, and a level-0 title starting with '#'.
    static func source() -> DocumentModel {
        DocumentModel(previewRows: [
            OutlineRow(title: "#井号开头", level: 0, manualPage: 3),
            OutlineRow(title: "中英 Mixed 标题", level: 1, printedPage: PrintedPageRef(style: .arabic, value: 2)),
            OutlineRow(title: "A & B <C> \"D\" 'E'", level: 2, printedPage: PrintedPageRef(style: .arabic, value: 4), sectionShift: 1),
            OutlineRow(title: "全角　空格", level: 1, manualPage: 11),
            OutlineRow(title: "第二章 结论", level: 0, printedPage: PrintedPageRef(style: .arabic, value: 20)),
        ], pageCount: 60, mapping: PageMapping(offset: 5))
    }

    static func projection(_ m: DocumentModel) -> [String] {
        m.draft.rows.map { "\(MuluTOCFormat.oneLine($0.title))|\($0.level)|\(m.draft.mapping.physicalPage(for: $0).map(String.init) ?? "-")" }
    }

    /// What each format gives back: every format normalizes whitespace (U+3000 → space); only
    /// the Mulu text format writes a level-0 '#' as '＃' (else it would be a comment).
    static func expected(_ format: TOCFormat) -> [String] {
        let hash = format == .mulu ? "＃井号开头" : "#井号开头"
        return ["\(hash)|0|3", "中英 Mixed 标题|1|7", "A & B <C> \"D\" 'E'|2|10", "全角 空格|1|11", "第二章 结论|0|25"]
    }

    @Test(arguments: TOCFormat.allCases)
    func exportImportRoundTrip(_ format: TOCFormat) throws {
        let src = Self.source()
        let text = try src.exportText(format: format)
        let dst = DocumentModel(previewRows: [], pageCount: 60)
        let report = try dst.importOutline(bytes: Array(text.utf8), fileName: "toc.\(format.fileExtension)", format: format, mode: .replace)
        #expect(report.format == format && report.count == 5 && report.mode == .replace)
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        #expect(Self.projection(dst) == Self.expected(format), "\(format): \(text)")
        #expect(dst.banner == .imported(report))
        if format == .pdfdir {
            // pdfdir numbers are printed pages: they follow the offset (which is 0 after a replace)
            #expect(dst.draft.mapping.offset == 0)
            #expect(dst.draft.rows.allSatisfy { $0.printedPage?.style == .arabic && $0.manualPage == nil })
            dst.setOffset(1)
            #expect(dst.physicalPage(of: dst.draft.rows[0].id) == 4)
        } else {
            #expect(dst.draft.rows.allSatisfy { $0.manualPage != nil && $0.printedPage == nil })
        }
        // one undo step
        #expect(dst.undoManager.canUndo)
        if format != .pdfdir {
            dst.undoManager.undo()
            #expect(dst.draft.rows.isEmpty)
        }
    }

    @Test func formatDetails() throws {
        let src = Self.source()
        let xml = try src.exportText(format: .pdfpatcherXML)
        #expect(xml.contains("<PDF信息") && xml.contains("<文档书签>") && xml.contains("<书签 文本=\"A &amp; B &lt;C&gt; &quot;D&quot;"))
        #expect(xml.contains("页码=\"10\""))
        let mulu = try src.exportText(format: .mulu)
        #expect(mulu.hasPrefix("＃井号开头 3\n\t中英 Mixed 标题 7\n\t\tA & B"))
        let pdfdir = try src.exportText(format: .pdfdir)
        #expect(pdfdir.contains("  中英 Mixed 标题 7\n"))  // physical pages, as `mulu export-outline`
        let opml = try src.exportText(format: .opml)
        #expect(opml.contains("<title>") && opml.contains("page=\"25\""))
        let json = try src.exportText(format: .json)
        #expect(json.contains("\"title\": \"第二章 结论\", \"level\": 0, \"page\": 25"))
        #expect(src.defaultExportURL(format: .pdfpatcherXML).lastPathComponent == "Preview-目录.xml")
        #expect(src.defaultExportURL(format: .mulu, suffix: "-outline").lastPathComponent == "Preview-outline.txt")
    }

    @Test func gb18030PdfdirText() throws {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let bytes = [UInt8]("第一章 总论 1\n  第一节 概念 3\n第二章 方法 9\n".data(using: enc)!)
        #expect(String(bytes: bytes, encoding: .utf8) == nil)  // really not UTF-8
        let m = DocumentModel(previewRows: [], pageCount: 30)
        let report = try m.importOutline(bytes: bytes, fileName: "目录.txt", format: nil, mode: .replace)
        #expect(report.format == .pdfdir)
        #expect(Self.projection(m) == ["第一章 总论|0|1", "第一节 概念|1|3", "第二章 方法|0|9"])
    }

    @Test func warningsAttachToTheirRow() throws {
        let json = """
            [{"title": "有页", "level": 0, "page": 2},
             {"title": "没页", "level": 0},
             {"title": "跳级", "level": 3, "page": 5}]
            """
        let m = DocumentModel(previewRows: [], pageCount: 30)
        let report = try m.importOutline(bytes: Array(json.utf8), fileName: nil, format: nil, mode: .replace)
        #expect(report.format == .json && report.warnings.count == 2)
        #expect(m.draft.rows[0].doubts.isEmpty)
        #expect(m.draft.rows[1].doubts.map(\.kind) == [.importWarning] && m.draft.rows[1].manualPage == 2)
        #expect(m.draft.rows[2].doubts.map(\.kind) == [.importWarning] && m.draft.rows[2].level == 1)
        #expect(m.displayRows[1].status == .doubtful)
        #expect(DocumentModel.warningLine("outline item 4: x") == 4 && DocumentModel.warningLine("line 12: y") == 12)
        #expect(DocumentModel.warningLine("no number: z") == nil)
    }

    @Test func appendAndInsertCompensateTheOffset() throws {
        let m = DocumentModel(previewRows: [
            OutlineRow(title: "A", level: 0, printedPage: PrintedPageRef(style: .arabic, value: 1)),
            OutlineRow(title: "A1", level: 1, printedPage: PrintedPageRef(style: .arabic, value: 2)),
            OutlineRow(title: "B", level: 0, printedPage: PrintedPageRef(style: .arabic, value: 9)),
        ], pageCount: 60, mapping: PageMapping(offset: 5))
        let pdfdir = "X 30\n  X1 31\n"
        try m.importOutline(bytes: Array(pdfdir.utf8), fileName: nil, format: .pdfdir, mode: .append)
        #expect(Self.projection(m) == ["A|0|6", "A1|1|7", "B|0|14", "X|0|30", "X1|1|31"])
        #expect(m.draft.mapping.offset == 5)
        // the imported printed pages keep following the global offset
        m.setOffset(6)
        #expect(Self.projection(m) == ["A|0|7", "A1|1|8", "B|0|15", "X|0|31", "X1|1|32"])
        m.undoManager.undo()
        // insert after the focused level-1 row: at its level, after its block
        let a1 = m.draft.rows[1].id
        m.select([a1], focus: a1)
        try m.importOutline(bytes: Array("Y 3\n\tY1 4\n".utf8), fileName: nil, format: .mulu, mode: .insertAfterFocused)
        #expect(Self.projection(m) == ["A|0|6", "A1|1|7", "Y|1|3", "Y1|2|4", "B|0|14", "X|0|30", "X1|1|31"])
        #expect(OutlineDraft.levelsAreValid(m.draft.rows))
        m.undoManager.undo()
        m.undoManager.undo()
        #expect(Self.projection(m) == ["A|0|6", "A1|1|7", "B|0|14"])
    }

    @Test func exportRefusesTheOpenPDFAndWritesAtomically() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 10)
        let out = SyntheticBook.tempURL("export-\(UUID().uuidString).json")
        defer { SyntheticBook.remove(pdf, out) }
        let m = DocumentModel(url: pdf)
        await m.load()
        let id = m.addSibling(after: nil, title: "Only")
        m.setPhysicalPage(id, 4)
        #expect(throws: WriteError.wouldOverwriteInput) { try m.export(to: pdf, format: .json) }
        try m.export(to: out, format: .json)
        let back = try TOCInterop.read([UInt8](Data(contentsOf: out)), format: .json)
        #expect(back.entries.map(\.title) == ["Only"] && back.entries.map(\.page) == [4])
        #expect(m.defaultExportURL(format: .opml).deletingLastPathComponent() == pdf.deletingLastPathComponent())
        let empty = DocumentModel(previewRows: [], pageCount: 3)
        #expect(throws: WriteError.blocked([.noRows])) { try empty.exportText(format: .mulu) }
    }
}
