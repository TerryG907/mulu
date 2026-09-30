import Foundation

/// App-level facts the app fills in (the model cannot see NSApp).
public struct SmokeAppFacts: Sendable, Hashable, Codable {
    public var bundled: Bool
    public var bundleIdentifier: String?
    public var version: String?
    public var activationPolicy: String
    public var windowsVisible: Int
    public var language: String?

    public init(bundled: Bool, bundleIdentifier: String?, version: String?, activationPolicy: String,
                windowsVisible: Int, language: String?) {
        self.bundled = bundled
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.activationPolicy = activationPolicy
        self.windowsVisible = windowsVisible
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case bundled, bundleIdentifier, version, activationPolicy, windowsVisible, language
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundled, forKey: .bundled)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encode(version, forKey: .version)
        try c.encode(activationPolicy, forKey: .activationPolicy)
        try c.encode(windowsVisible, forKey: .windowsVisible)
        try c.encode(language, forKey: .language)
    }
}

/// The smoke run's JSON (`schema: 1`; GUI_SPEC §9.3). Absent parts are encoded as null.
public struct SmokeReport: Sendable, Hashable, Codable {
    public struct Document: Sendable, Hashable, Codable {
        public var path: String
        /// "loading" | "ready" | "failed"
        public var phase: String
        public var pageCount: Int
        public var existingOutlineItems: Int
        public init(path: String, phase: String, pageCount: Int, existingOutlineItems: Int) {
            self.path = path
            self.phase = phase
            self.pageCount = pageCount
            self.existingOutlineItems = existingOutlineItems
        }
    }

    public struct AdvisoryItem: Sendable, Hashable, Codable {
        public var kind: String
        public var blocksAuto: Bool
        public var detail: String
        public init(kind: String, blocksAuto: Bool, detail: String) {
            self.kind = kind
            self.blocksAuto = blocksAuto
            self.detail = detail
        }
    }

    public struct Recognition: Sendable, Hashable, Codable {
        /// "finished" | "failed" | "cancelled" | "running" | "idle"
        public var status: String
        public var tocPages: [Int]
        public var rows: Int
        public var doubtful: Int
        public var offset: Int?
        public var offsetSource: String?
        public var autoWouldAccept: Bool
        public var advisories: [AdvisoryItem]
        public var seconds: Double
        public var muluText: String?

        public init(status: String, tocPages: [Int], rows: Int, doubtful: Int, offset: Int?, offsetSource: String?,
                    autoWouldAccept: Bool, advisories: [AdvisoryItem], seconds: Double, muluText: String?) {
            self.status = status
            self.tocPages = tocPages
            self.rows = rows
            self.doubtful = doubtful
            self.offset = offset
            self.offsetSource = offsetSource
            self.autoWouldAccept = autoWouldAccept
            self.advisories = advisories
            self.seconds = seconds
            self.muluText = muluText
        }

        private enum CodingKeys: String, CodingKey {
            case status, tocPages, rows, doubtful, offset, offsetSource, autoWouldAccept, advisories, seconds, muluText
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try c.encode(tocPages, forKey: .tocPages)
            try c.encode(rows, forKey: .rows)
            try c.encode(doubtful, forKey: .doubtful)
            try c.encode(offset, forKey: .offset)
            try c.encode(offsetSource, forKey: .offsetSource)
            try c.encode(autoWouldAccept, forKey: .autoWouldAccept)
            try c.encode(advisories, forKey: .advisories)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(muluText, forKey: .muluText)
        }
    }

    public struct Draft: Sendable, Hashable, Codable {
        public var rows: Int
        public var errors: Int
        public var doubtful: Int
        public var dirty: Bool
        public init(rows: Int, errors: Int, doubtful: Int, dirty: Bool) {
            self.rows = rows
            self.errors = errors
            self.doubtful = doubtful
            self.dirty = dirty
        }
    }

    public struct Write: Sendable, Hashable, Codable {
        public var output: String
        public var appendedBytes: Int
        public var items: Int
        public var originalBytesUnchanged: Bool
        public init(output: String, appendedBytes: Int, items: Int, originalBytesUnchanged: Bool) {
            self.output = output
            self.appendedBytes = appendedBytes
            self.items = items
            self.originalBytesUnchanged = originalBytesUnchanged
        }
    }

    public var schema: Int = 1
    /// "ok" | "error" | "timeout"
    public var status: String
    public var error: String?
    public var elapsed: Double
    public var app: SmokeAppFacts?
    public var document: Document?
    public var recognition: Recognition?
    public var draft: Draft?
    public var write: Write?

    public init(status: String, error: String? = nil, elapsed: Double = 0, app: SmokeAppFacts? = nil, document: Document? = nil,
                recognition: Recognition? = nil, draft: Draft? = nil, write: Write? = nil) {
        self.status = status
        self.error = error
        self.elapsed = elapsed
        self.app = app
        self.document = document
        self.recognition = recognition
        self.draft = draft
        self.write = write
    }

    private enum CodingKeys: String, CodingKey {
        case schema, status, error, elapsed, app, document, recognition, draft, write
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(status, forKey: .status)
        try c.encode(error, forKey: .error)
        try c.encode(elapsed, forKey: .elapsed)
        try c.encode(app, forKey: .app)
        try c.encode(document, forKey: .document)
        try c.encode(recognition, forKey: .recognition)
        try c.encode(draft, forKey: .draft)
        try c.encode(write, forKey: .write)
    }

    /// Sorted keys, nulls written out, "schema": 1.
    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
