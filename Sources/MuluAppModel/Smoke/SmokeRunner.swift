import Foundation

/// Drives one document through open → optional recognition → optional write and reports
/// (GUI_SPEC §9.3). The app adds `app`, writes the JSON and quits; it also owns the timeout
/// watchdog (`timeoutReport`).
@MainActor public enum SmokeRunner {
    public static func run(_ config: SmokeConfig, document: DocumentModel) async -> SmokeReport {
        let clock = ContinuousClock()
        let t0 = clock.now
        func elapsed() -> Double {
            let d = clock.now - t0
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            return (s * 1000).rounded() / 1000
        }
        var report = SmokeReport(status: "ok")
        func finish(_ error: String?) -> SmokeReport {
            report.document = documentPart(document)
            report.draft = SmokeReport.Draft(rows: document.counts.rows, errors: document.counts.errors,
                                             doubtful: document.counts.doubtful, dirty: document.isDirty)
            if let error {
                report.status = "error"
                report.error = error
            }
            report.elapsed = elapsed()
            return report
        }

        await document.load()
        if case .failed(let f) = document.phase { return finish(f.description) }

        if let spec = config.tocPages {
            do {
                try document.setTOCPages(spec: spec)
                // A stopped run is for a screenshot: show the first TOC page, as a user would have.
                if config.stop != nil, let first = document.tocPages.first { document.requestPreview(page: first) }
                if config.stop == .marked { return finish(nil) }
                try document.startRecognition(pages: document.tocPages, knownOffset: config.knownOffset)
            } catch {
                return finish("recognition: \(error)")
            }
            await document.waitForRecognition()
            let state = document.recognition
            report.recognition = recognitionPart(state, pages: document.tocPages)
            switch state {
            case .finished:
                if config.stop == .result { return finish(nil) }
                document.acceptRecognition(.replace)
                if config.stop == .review {
                    document.startReview(onlyDoubtful: document.counts.doubtful + document.counts.errors > 0)
                    return finish(nil)
                }
            case .failed(let why):
                return finish("recognition failed: \(why)")
            case .cancelled:
                return finish("recognition cancelled")
            case .idle, .running:
                return finish("recognition did not finish")
            }
        }

        if let out = config.writeTo {
            do {
                let w = try await document.write(to: out)
                report.write = SmokeReport.Write(output: w.output.path, appendedBytes: w.appendedBytes, items: w.items,
                                                 originalBytesUnchanged: w.originalBytesUnchanged)
            } catch {
                return finish("write: \(error)")
            }
        }
        return finish(nil)
    }

    public static func timeoutReport(_ config: SmokeConfig, elapsed: Double) -> SmokeReport {
        SmokeReport(status: "timeout", error: "timed out after \(Int(config.timeout.rounded())) s", elapsed: (elapsed * 1000).rounded() / 1000)
    }

    /// Writes the JSON atomically to `url`, or to stdout when nil.
    public static func write(_ report: SmokeReport, to url: URL?) throws {
        var data = try report.jsonData()
        data.append(0x0A)
        guard let url else {
            FileHandle.standardOutput.write(data)
            return
        }
        try FileIdentity.writeAtomically([UInt8](data), to: url)
    }

    static func documentPart(_ d: DocumentModel) -> SmokeReport.Document {
        let phase: String
        switch d.phase {
        case .loading: phase = "loading"
        case .ready: phase = "ready"
        case .failed: phase = "failed"
        }
        return SmokeReport.Document(path: d.url.path, phase: phase, pageCount: d.pageCount,
                                    existingOutlineItems: d.summary?.existingOutline.count ?? 0)
    }

    static func recognitionPart(_ state: RecognitionState, pages: [Int]) -> SmokeReport.Recognition {
        switch state {
        case .finished(let r):
            return SmokeReport.Recognition(
                status: "finished", tocPages: r.tocPages, rows: r.rows.count, doubtful: r.doubtfulCount, offset: r.mapping.offset,
                offsetSource: r.offsetInfo.source.rawValue, autoWouldAccept: r.autoWouldAccept,
                advisories: r.advisories.map { SmokeReport.AdvisoryItem(kind: $0.kind.rawValue, blocksAuto: $0.blocksAuto, detail: $0.detail) },
                seconds: (r.seconds * 100).rounded() / 100, muluText: r.muluText)
        case .failed:
            return empty("failed", pages)
        case .cancelled:
            return empty("cancelled", pages)
        case .running:
            return empty("running", pages)
        case .idle:
            return empty("idle", pages)
        }
    }

    private static func empty(_ status: String, _ pages: [Int]) -> SmokeReport.Recognition {
        SmokeReport.Recognition(status: status, tocPages: pages, rows: 0, doubtful: 0, offset: nil, offsetSource: nil,
                                autoWouldAccept: false, advisories: [], seconds: 0, muluText: nil)
    }
}
