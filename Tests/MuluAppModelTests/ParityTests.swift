import Foundation
import MuluCore
import Testing
@testable import MuluAppModel

/// The ported `mulu auto` heuristics must agree with the CLI (GUI_SPEC §3.3, §9.4): on the
/// same PDF and TOC pages, `autoWouldAccept` equals "auto exits 0", and when it accepts,
/// `muluText` equals the stdout of `mulu auto --dry-run` byte for byte.
///
/// Off by default (minutes of OCR, and Fixtures/books is generated, not tracked). Run with
///   MULU_PARITY=all swift test --filter ParityTests                 (every book in the manifest)
///   MULU_PARITY=zh_econ_textbook,zh_mgmt_twocol swift test --filter ParityTests
/// The CLI is `.build/debug/mulu` unless MULU_CLI names another binary; build it first.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MULU_PARITY"] != nil))
struct ParityTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Book {
        var name: String
        var tocPages: [Int]
    }

    static func books() throws -> [Book] {
        let want = Set((ProcessInfo.processInfo.environment["MULU_PARITY"] ?? "").split(separator: ",").map(String.init))
        let manifest = root.appendingPathComponent("Fixtures/books/manifest.json")
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let list = obj["books"] as? [[String: Any]] else { return [] }
        return list.compactMap { b in
            guard let name = b["book"] as? String, let pages = b["toc_pages"] as? [Int] else { return nil }
            guard want.contains("all") || want.contains(name) else { return nil }
            return Book(name: name, tocPages: pages)
        }
    }

    static func runCLI(_ args: [String]) throws -> (status: Int32, stdout: String) {
        let cli = ProcessInfo.processInfo.environment["MULU_CLI"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/debug/mulu")
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func recognitionMatchesMuluAuto() throws {
        let books = try Self.books()
        #expect(!books.isEmpty, "no book in Fixtures/books/manifest.json matches MULU_PARITY (run tools/run_all.sh --books once)")
        for book in books {
            let pdf = Self.root.appendingPathComponent("Fixtures/books/\(book.name).pdf")
            let pageCount = try PDFFile(bytes: [UInt8](Data(contentsOf: pdf))).pageRefs().count
            let result = try RecognitionPipeline(url: pdf, pageCount: pageCount)
                .run(RecognitionRequest(input: .tocPages(book.tocPages)), progress: { _ in })
            let spec = book.tocPages.map(String.init).joined(separator: ",")
            let cli = try Self.runCLI(["auto", pdf.path, "--toc-pages", spec, "--dry-run"])
            #expect(result.autoWouldAccept == (cli.status == 0),
                    "\(book.name): app accepts \(result.autoWouldAccept), auto exit \(cli.status); \(result.advisories.filter(\.blocksAuto).map(\.detail))")
            if cli.status == 0 && result.autoWouldAccept {
                #expect(result.muluText == cli.stdout, "\(book.name): muluText differs from `mulu auto --dry-run`")
                // every entry auto writes is in the draft with the same page
                let draft = OutlineDraft(rows: result.rows.filter { result.mapping.physicalPage(for: $0) != nil }, mapping: result.mapping)
                let written = try TOCParser.parse(cli.stdout)
                #expect(draft.outputEntries()?.map { "\($0.title)|\($0.page)" } == written.map { "\(MuluTOCFormat.oneLine($0.title))|\($0.page)" },
                        "\(book.name): draft pages differ")
            }
            print("parity \(book.name): accept=\(result.autoWouldAccept) exit=\(cli.status) rows=\(result.rows.count) doubtful=\(result.doubtfulCount) offset=\(result.mapping.offset) \(result.offsetInfo.source) \(String(format: "%.1f", result.seconds)) s")
        }
    }
}
