import Foundation
import MuluCore
import MuluOCR

extension DocumentModel {
    // MARK: - TOC pages (not undoable)

    /// "5-7,9"
    public var tocPagesSpec: String {
        var parts: [String] = []
        var k = 0
        let p = tocPages
        while k < p.count {
            var j = k
            while j + 1 < p.count && p[j + 1] == p[j] + 1 { j += 1 }
            parts.append(j == k ? "\(p[k])" : "\(p[k])-\(p[j])")
            k = j + 1
        }
        return parts.joined(separator: ",")
    }

    public func toggleTOCPage(_ page: Int) {
        guard page >= 1, pageCount == 0 || page <= pageCount else { return }
        if let i = tocPages.firstIndex(of: page) {
            tocPages.remove(at: i)
        } else {
            tocPages = (tocPages + [page]).sorted()
        }
    }

    public func setTOCPages(_ pages: [Int]) {
        tocPages = Array(Set(pages.filter { $0 >= 1 && (pageCount == 0 || $0 <= pageCount) })).sorted()
    }

    /// Parses "5-7", "3,5,8-9" (1-based physical pages); an empty spec clears the selection.
    /// Throws RecognitionError.invalidPages / .tooManyPages.
    public func setTOCPages(spec: String) throws {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            tocPages = []
            return
        }
        let pages: [Int]
        do {
            pages = try parsePageList(s, pageCount: pageCount)
        } catch {
            throw RecognitionError.invalidPages("\(error)")
        }
        guard pages.count <= maxTOCPageCount else { throw RecognitionError.tooManyPages(pages.count) }
        tocPages = Array(Set(pages)).sorted()
    }

    // MARK: - Recognition

    /// Recognizes the given TOC pages (nil: the marked `tocPages`), like `mulu auto`.
    public func startRecognition(pages: [Int]? = nil, knownOffset: Int? = nil) throws {
        try startRecognition(RecognitionRequest(input: .tocPages(pages ?? tocPages), knownOffset: knownOffset, detectOffset: true))
    }

    /// Runs the pipeline in a detached task; progress and the outcome arrive in `recognition`.
    /// One recognition at a time.
    public func startRecognition(_ request: RecognitionRequest) throws {
        guard !isPreview, phase == .ready, summary != nil else { throw RecognitionError.notReady }
        if case .running = recognition { throw RecognitionError.alreadyRunning }
        if recognitionTask != nil { throw RecognitionError.alreadyRunning }
        var request = request
        let firstPhase: RecognitionProgress.Phase
        let firstTotal: Int
        switch request.input {
        case .tocPages(let pages):
            let valid = try RecognitionPipeline.validatedPages(pages, pageCount: pageCount)
            request.input = .tocPages(valid)
            firstPhase = .readingTOC
            firstTotal = valid.count
        case .text:
            firstPhase = .parsing
            firstTotal = 1
        }
        if let k = request.knownOffset, abs(k) > TOCParser.maxPage {
            throw RecognitionError.invalidPages("offset \(k) is out of range")
        }

        let pipeline = RecognitionPipeline(url: url, pageCount: pageCount)
        let (stream, continuation) = AsyncStream.makeStream(of: RecognitionProgress.self, bufferingPolicy: .bufferingNewest(1))
        let req = request
        let worker = Task.detached(priority: .userInitiated) { () throws -> RecognitionResult in
            defer { continuation.finish() }
            return try pipeline.run(req) { continuation.yield($0) }
        }
        let workerID = UUID()
        workers.add(workerID) { worker.cancel() }
        recognitionSerial += 1
        let serial = recognitionSerial
        recognitionCancel = { worker.cancel() }
        let first = RecognitionProgress(phase: firstPhase, step: 0, total: firstTotal, fraction: 0)
        recognitionProgressLog = [first]
        recognition = .running(first)
        recognitionTask = Task { [weak self] in
            for await p in stream {
                guard let self else { break }
                guard self.recognitionSerial == serial, case .running = self.recognition else { continue }
                self.recognitionProgressLog.append(p)
                self.recognition = .running(p)
            }
            let outcome = await worker.result
            guard let self else { return }
            self.workers.remove(workerID)
            guard self.recognitionSerial == serial else { return }
            self.recognitionTask = nil
            self.recognitionCancel = nil
            switch outcome {
            case .success(let r):
                self.recognition = .finished(r)
            case .failure(let e):
                if e is CancellationError || worker.isCancelled {
                    self.recognition = .cancelled
                } else if let e = e as? RecognitionError {
                    self.recognition = .failed(e.description)
                } else {
                    self.recognition = .failed("\(e)")
                }
            }
        }
    }

    /// Stops the running recognition at its next check (at most one TOC page or one sampled
    /// page later); the state becomes `.cancelled` and the draft is untouched.
    public func cancelRecognition() {
        recognitionCancel?()
    }

    /// Returns when the current recognition (if any) has finished, failed or been cancelled.
    public func waitForRecognition() async {
        if let t = recognitionTask { await t.value }
    }

    /// Puts the finished result into the draft (one undo step) and returns to `.idle`.
    public func acceptRecognition(_ mode: MergeMode) {
        guard case .finished(let r) = recognition else { return }
        let focus = focusedRowID.flatMap { index(of: $0) }
        let wasEmpty = draft.rows.isEmpty
        let merged = DocumentModel.merge(r.rows, mapping: r.mapping, into: draft, mode: mode, after: focus)
        let replaced = mode == .replace || wasEmpty
        let firstNew = r.rows.first.map(\.id)
        commit(merged, action: ActionName.useRecognition,
               selection: firstNew.map { [$0] } ?? [], focus: .some(firstNew),
               offsetInfo: replaced ? .some(r.offsetInfo) : .none, annotated: true)
        advisories = r.advisories
        banner = .recognitionApplied(count: r.rows.count, doubtful: r.rows.filter { $0.doubts.contains(where: \.isDoubt) }.count)
        recognition = .idle
        if let f = firstNew { reveal(f) }
        if let f = firstNew, let p = physicalPage(of: f) { issuePreview(p) }
    }

    /// Drops a finished, failed or cancelled result.
    public func discardRecognition() {
        switch recognition {
        case .running: return
        default: recognition = .idle
        }
    }
}
