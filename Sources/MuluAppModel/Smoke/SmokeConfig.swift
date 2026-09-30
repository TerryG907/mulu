import Foundation

/// The `MULU_SMOKE` environment (GUI_SPEC §9.3).
public struct SmokeConfig: Sendable, Hashable {
    public enum Target: Sendable, Hashable { case file(URL), openEvent }
    public var target: Target
    /// MULU_SMOKE_TOC, e.g. "4-5": recognize these pages and use the result (.replace).
    public var tocPages: String?
    /// MULU_SMOKE_OFFSET
    public var knownOffset: Int?
    /// MULU_SMOKE_WRITE
    public var writeTo: URL?
    /// MULU_SMOKE_OUT (nil: stdout)
    public var output: URL?
    /// MULU_SMOKE_TIMEOUT seconds, default 20, clamped to 5...120.
    public var timeout: Double
    /// MULU_SMOKE_CLOSE=1: after the report, close the window and check that the document
    /// (model, PDF, thumbnails) is freed; the exit code is 0 when it is, 4 when it is not.
    public var closeCheck = false
    /// MULU_SMOKE_HOLD seconds (0...60, default 0): keep the window open this long after the
    /// report is written, before quitting (for a screenshot of the state the run ended in).
    public var hold: Double = 0
    /// MULU_SMOKE_STOP: end the run early, for a screenshot of an intermediate state together
    /// with MULU_SMOKE_HOLD. Needs MULU_SMOKE_TOC; the preview shows the first TOC page.
    /// Anything else (or unset) runs to the end.
    public var stop: Stop?

    public enum Stop: String, Sendable, Hashable {
        /// The TOC pages are marked; nothing is recognized.
        case marked
        /// Recognition has finished and its result is left waiting (the app shows the result
        /// panel); the draft stays empty and nothing is written.
        case result
        /// The result is in the draft and the review has started on its first doubtful row (on
        /// the first row when none is doubtful); nothing is written.
        case review
    }

    public static let defaultTimeout = 20.0

    /// nil unless MULU_SMOKE is set (a PDF path, or "@odoc" to wait for an open event).
    public init?(environment: [String: String]) {
        func value(_ k: String) -> String? {
            guard let v = environment[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        guard let target = value("MULU_SMOKE") else { return nil }
        self.target = target == "@odoc" ? .openEvent : .file(URL(fileURLWithPath: target).standardizedFileURL)
        tocPages = value("MULU_SMOKE_TOC")
        knownOffset = value("MULU_SMOKE_OFFSET").flatMap { Int($0) }
        writeTo = value("MULU_SMOKE_WRITE").map { URL(fileURLWithPath: $0).standardizedFileURL }
        output = value("MULU_SMOKE_OUT").map { URL(fileURLWithPath: $0).standardizedFileURL }
        let t = value("MULU_SMOKE_TIMEOUT").flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } ?? SmokeConfig.defaultTimeout
        timeout = min(120, max(5, t))
        closeCheck = value("MULU_SMOKE_CLOSE") == "1"
        let h = value("MULU_SMOKE_HOLD").flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } ?? 0
        hold = min(60, max(0, h))
        stop = value("MULU_SMOKE_STOP").flatMap { Stop(rawValue: $0) }
    }

    public init(target: Target, tocPages: String? = nil, knownOffset: Int? = nil, writeTo: URL? = nil, output: URL? = nil,
                timeout: Double = SmokeConfig.defaultTimeout) {
        self.target = target
        self.tocPages = tocPages
        self.knownOffset = knownOffset
        self.writeTo = writeTo
        self.output = output
        self.timeout = min(120, max(5, timeout))
    }
}
