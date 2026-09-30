import Foundation
import MuluOCR

public enum OffsetSource: String, Sendable, Hashable {
    case given, detected, pageNumbersAndHeadings, bestGuess, none, manual, calibrated, existingOutline
}

public struct OffsetEvidence: Sendable, Hashable {
    public var agreeing: Int
    public var samples: Int
    public var confidence: Double
    public var headingsChecked: Int
    public var headingsConfirmed: Int
    /// OffsetReport.reason, verbatim.
    public var reason: String

    public init(agreeing: Int = 0, samples: Int = 0, confidence: Double = 0, headingsChecked: Int = 0,
                headingsConfirmed: Int = 0, reason: String = "") {
        self.agreeing = agreeing
        self.samples = samples
        self.confidence = confidence
        self.headingsChecked = headingsChecked
        self.headingsConfirmed = headingsConfirmed
        self.reason = reason
    }
}

public struct OffsetInfo: Sendable, Hashable {
    public var source: OffsetSource
    public var evidence: OffsetEvidence?
    public var calibratedFromPage: Int?

    public init(source: OffsetSource, evidence: OffsetEvidence? = nil, calibratedFromPage: Int? = nil) {
        self.source = source
        self.evidence = evidence
        self.calibratedFromPage = calibratedFromPage
    }
}

public enum RecognitionInput: Sendable, Hashable { case tocPages([Int]), text(String) }

public struct RecognitionRequest: Sendable, Hashable {
    public var input: RecognitionInput
    public var knownOffset: Int?
    /// false: use knownOffset ?? 0 and read no body pages at all (no offset detection, heading
    /// check, front-matter search or heading search).
    public var detectOffset: Bool

    public init(input: RecognitionInput, knownOffset: Int? = nil, detectOffset: Bool = true) {
        self.input = input
        self.knownOffset = knownOffset
        self.detectOffset = detectOffset
    }
}

public struct RecognitionProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case readingTOC, parsing, detectingOffset, checkingHeadings, frontMatter, locatingHeadings, finishing
    }
    public var phase: Phase
    /// e.g. TOC page index (0-based) or offset sample count
    public var step: Int
    public var total: Int
    /// overall 0...1, non-decreasing
    public var fraction: Double

    public init(phase: Phase, step: Int, total: Int, fraction: Double) {
        self.phase = phase
        self.step = step
        self.total = total
        self.fraction = fraction
    }
}

/// A finding of recognition that is not about one row: the refusals and warnings of `mulu auto`
/// (GUI_SPEC §4.6). `blocksAuto` marks the ones `auto` refuses on.
public struct Advisory: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case noText, fewEntries, notTOCLike, offsetUncertain, offsetHeadingsDisagree, offsetMayChange,
             firstChapterBeforeTOC, entriesBeyondLastPage, romanUnresolved, tooManyDoubtful,
             ocrWarning, parserWarning
    }
    public enum Severity: String, Sendable, Hashable { case info, warning }
    public let id: UUID
    public var kind: Kind
    public var severity: Severity
    public var blocksAuto: Bool
    /// verbatim English
    public var detail: String

    public init(id: UUID = UUID(), kind: Kind, severity: Severity, blocksAuto: Bool, detail: String) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.blocksAuto = blocksAuto
        self.detail = detail
    }
}

public struct RecognitionResult: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case ocr, pastedText }
    public var source: Source
    public var tocPages: [Int]
    public var rows: [OutlineRow]
    public var mapping: PageMapping
    public var offsetInfo: OffsetInfo
    public var advisories: [Advisory]
    public var ocrLines: Int
    /// counted exactly like `mulu auto`
    public var doubtfulCount: Int
    public var autoWouldAccept: Bool
    /// PrintedTOCResult.muluText(header: true, annotate: true)
    public var muluText: String
    public var seconds: Double

    public init(source: Source, tocPages: [Int], rows: [OutlineRow], mapping: PageMapping, offsetInfo: OffsetInfo,
                advisories: [Advisory], ocrLines: Int, doubtfulCount: Int, autoWouldAccept: Bool, muluText: String,
                seconds: Double) {
        self.source = source
        self.tocPages = tocPages
        self.rows = rows
        self.mapping = mapping
        self.offsetInfo = offsetInfo
        self.advisories = advisories
        self.ocrLines = ocrLines
        self.doubtfulCount = doubtfulCount
        self.autoWouldAccept = autoWouldAccept
        self.muluText = muluText
        self.seconds = seconds
    }
}

public enum RecognitionState: Sendable, Hashable {
    case idle
    case running(RecognitionProgress)
    case finished(RecognitionResult)
    case failed(String)
    case cancelled
}

public enum RecognitionError: Error, Sendable, Hashable, CustomStringConvertible {
    case notReady, alreadyRunning, noPages, tooManyPages(Int), invalidPages(String)

    public var description: String {
        switch self {
        case .notReady: return "the document is not open"
        case .alreadyRunning: return "a recognition is already running"
        case .noPages: return "no TOC pages selected"
        case .tooManyPages(let n):
            return "\(n) pages selected; a printed TOC is rarely longer than \(maxTOCPageCount) pages (each takes about 2.5 s of OCR)"
        case .invalidPages(let s): return s
        }
    }
}
