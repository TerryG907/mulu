import Foundation
import MuluCore
import Testing
@testable import MuluAppModel

@MainActor
@Suite struct SmokeTests {
    @Test func configFromEnvironment() {
        #expect(SmokeConfig(environment: [:]) == nil)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "  "]) == nil)
        let c = SmokeConfig(environment: [
            "MULU_SMOKE": "/tmp/book.pdf", "MULU_SMOKE_TOC": "4-5", "MULU_SMOKE_OFFSET": "6",
            "MULU_SMOKE_WRITE": "/tmp/out.pdf", "MULU_SMOKE_OUT": "/tmp/smoke.json", "MULU_SMOKE_TIMEOUT": "45",
        ])
        #expect(c?.target == .file(URL(fileURLWithPath: "/tmp/book.pdf")))
        #expect(c?.tocPages == "4-5" && c?.knownOffset == 6 && c?.timeout == 45)
        #expect(c?.writeTo == URL(fileURLWithPath: "/tmp/out.pdf") && c?.output == URL(fileURLWithPath: "/tmp/smoke.json"))
        let odoc = SmokeConfig(environment: ["MULU_SMOKE": "@odoc"])
        #expect(odoc?.target == .openEvent && odoc?.timeout == 20 && odoc?.tocPages == nil && odoc?.output == nil)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_TIMEOUT": "1"])?.timeout == 5)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_TIMEOUT": "999"])?.timeout == 120)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_TIMEOUT": "soon"])?.timeout == 20)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_OFFSET": "six"])?.knownOffset == nil)
        #expect(c?.closeCheck == false && c?.hold == 0)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_HOLD": "8"])?.hold == 8)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_HOLD": "999"])?.hold == 60)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_CLOSE": "1"])?.closeCheck == true)
        #expect(c?.stop == nil)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_STOP": "marked"])?.stop == .marked)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_STOP": "result"])?.stop == .result)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_STOP": "review"])?.stop == .review)
        #expect(SmokeConfig(environment: ["MULU_SMOKE": "/x.pdf", "MULU_SMOKE_STOP": "later"])?.stop == nil)
    }

    /// The field names of GUI_SPEC §9.3, locked: sorted keys, nulls written out.
    @Test func reportJSONSchema() throws {
        var r = SmokeReport(status: "ok", elapsed: 7.5)
        r.app = SmokeAppFacts(bundled: true, bundleIdentifier: "io.github.terryg907.mulu", version: "0.1.0",
                              activationPolicy: "regular", windowsVisible: 1, language: "zh-Hans")
        r.document = SmokeReport.Document(path: "/b/book.pdf", phase: "ready", pageCount: 42, existingOutlineItems: 0)
        r.recognition = SmokeReport.Recognition(
            status: "finished", tocPages: [4, 5], rows: 33, doubtful: 0, offset: 6, offsetSource: "detected", autoWouldAccept: true,
            advisories: [SmokeReport.AdvisoryItem(kind: "ocrWarning", blocksAuto: false, detail: "x")], seconds: 8.25, muluText: "# M\n")
        r.draft = SmokeReport.Draft(rows: 33, errors: 0, doubtful: 0, dirty: true)
        r.write = SmokeReport.Write(output: "/b/out.pdf", appendedBytes: 6973, items: 33, originalBytesUnchanged: true)
        let full = String(decoding: try r.jsonData(), as: UTF8.self)
        let want = """
            {
              "app" : {
                "activationPolicy" : "regular",
                "bundleIdentifier" : "io.github.terryg907.mulu",
                "bundled" : true,
                "language" : "zh-Hans",
                "version" : "0.1.0",
                "windowsVisible" : 1
              },
              "document" : {
                "existingOutlineItems" : 0,
                "pageCount" : 42,
                "path" : "/b/book.pdf",
                "phase" : "ready"
              },
              "draft" : {
                "dirty" : true,
                "doubtful" : 0,
                "errors" : 0,
                "rows" : 33
              },
              "elapsed" : 7.5,
              "error" : null,
              "recognition" : {
                "advisories" : [
                  {
                    "blocksAuto" : false,
                    "detail" : "x",
                    "kind" : "ocrWarning"
                  }
                ],
                "autoWouldAccept" : true,
                "doubtful" : 0,
                "muluText" : "# M\\n",
                "offset" : 6,
                "offsetSource" : "detected",
                "rows" : 33,
                "seconds" : 8.25,
                "status" : "finished",
                "tocPages" : [
                  4,
                  5
                ]
              },
              "schema" : 1,
              "status" : "ok",
              "write" : {
                "appendedBytes" : 6973,
                "items" : 33,
                "originalBytesUnchanged" : true,
                "output" : "/b/out.pdf"
              }
            }
            """
        #expect(full == want)

        // absent parts are null, not missing
        let bare = try JSONSerialization.jsonObject(with: SmokeReport(status: "error", error: "boom").jsonData()) as! [String: Any]
        #expect(Set(bare.keys) == ["schema", "status", "error", "elapsed", "app", "document", "recognition", "draft", "write"])
        #expect(bare["recognition"] is NSNull && bare["write"] is NSNull && bare["error"] as? String == "boom")
        // and it decodes back
        let back = try JSONDecoder().decode(SmokeReport.self, from: r.jsonData())
        #expect(back == r)
        let t = SmokeRunner.timeoutReport(SmokeConfig(target: .openEvent, timeout: 20), elapsed: 19.5)
        #expect(t.status == "timeout" && t.error != nil && t.elapsed == 19.5)
    }

    @Test func runOpensAndWrites() async throws {
        let plain = try SyntheticBook.plainPDF(pages: 8)
        let input = SyntheticBook.tempURL("smoke-in-\(UUID().uuidString).pdf")
        let out = SyntheticBook.tempURL("smoke-out-\(UUID().uuidString).pdf")
        let json = SyntheticBook.tempURL("smoke-\(UUID().uuidString).json")
        defer { SyntheticBook.remove(plain, input, out, json) }
        // an existing outline gives the draft something to write
        let applied = try Mulu.apply(pdf: [UInt8](Data(contentsOf: plain)), tocText: "One 1\n\tTwo 3\nThree 6\n", offset: 0)
        try Data(applied.output).write(to: input)

        let config = SmokeConfig(environment: ["MULU_SMOKE": input.path, "MULU_SMOKE_WRITE": out.path, "MULU_SMOKE_OUT": json.path])!
        guard case .file(let target) = config.target else {
            Issue.record("expected a file target")
            return
        }
        let m = DocumentModel(url: target)
        var report = await SmokeRunner.run(config, document: m)
        #expect(report.status == "ok", "\(report)")
        #expect(report.error == nil && report.recognition == nil)
        #expect(report.document?.phase == "ready" && report.document?.pageCount == 8 && report.document?.existingOutlineItems == 3)
        #expect(report.draft == SmokeReport.Draft(rows: 3, errors: 0, doubtful: 0, dirty: false))
        #expect(report.write?.items == 3 && report.write?.originalBytesUnchanged == true && (report.write?.appendedBytes ?? 0) > 0)
        let items = try PDFFile(bytes: [UInt8](Data(contentsOf: out))).readOutline()
        #expect(items.map(\.title) == ["One", "Two", "Three"] && items.map(\.pageIndex) == [0, 2, 5])
        let written = [UInt8](try Data(contentsOf: out))
        #expect(Array(written.prefix(applied.output.count)) == applied.output)

        report.app = SmokeAppFacts(bundled: false, bundleIdentifier: nil, version: nil, activationPolicy: "regular", windowsVisible: 1, language: nil)
        try SmokeRunner.write(report, to: config.output)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as! [String: Any]
        #expect(obj["status"] as? String == "ok" && obj["schema"] as? Int == 1)

        // MULU_SMOKE_STOP=marked: the TOC pages are marked and shown; nothing is recognized or written
        let unwritten = SyntheticBook.tempURL("smoke-stop-\(UUID().uuidString).pdf")
        let marked = SmokeConfig(environment: [
            "MULU_SMOKE": input.path, "MULU_SMOKE_TOC": "2-3", "MULU_SMOKE_STOP": "marked", "MULU_SMOKE_WRITE": unwritten.path,
        ])!
        let held = DocumentModel(url: target)
        let stopped = await SmokeRunner.run(marked, document: held)
        #expect(stopped.status == "ok" && stopped.recognition == nil && stopped.write == nil)
        #expect(held.tocPages == [2, 3] && held.previewPage == 2)
        #expect(!FileManager.default.fileExists(atPath: unwritten.path))

        // a failed open is an error report
        let missing = DocumentModel(url: SyntheticBook.tempURL("smoke-missing-\(UUID().uuidString).pdf"))
        let bad = await SmokeRunner.run(SmokeConfig(target: .file(missing.url)), document: missing)
        #expect(bad.status == "error" && bad.error != nil && bad.document?.phase == "failed")
    }
}
