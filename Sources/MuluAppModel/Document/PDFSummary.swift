import Foundation
import MuluCore

/// What opening the PDF found. The bytes themselves are not kept: writing reads the file again.
public struct PDFSummary: Sendable, Equatable {
    public var pageCount: Int
    public var fileSize: Int
    public var info: DocumentInfo                  // MuluCore
    public var existingOutline: [OutlineItemInfo]  // MuluCore
    public var fingerprint: FileFingerprint

    public init(pageCount: Int, fileSize: Int, info: DocumentInfo, existingOutline: [OutlineItemInfo], fingerprint: FileFingerprint) {
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.info = info
        self.existingOutline = existingOutline
        self.fingerprint = fingerprint
    }
}

public enum OpenFailure: Error, Sendable, Hashable, CustomStringConvertible {
    case notPDF(String), encrypted, noPages, unreadable(String)

    /// English detail (MuluError text).
    public var description: String {
        switch self {
        case .notPDF(let s): return s
        case .encrypted: return MuluError.encrypted.description
        case .noPages: return MuluError.zeroPages.description
        case .unreadable(let s): return s
        }
    }
}

public enum DocumentPhase: Sendable, Hashable { case loading, ready, failed(OpenFailure) }

/// Ask the preview to show a physical page; `serial` changes even when the page does not.
public struct PreviewRequest: Sendable, Hashable {
    public var page: Int
    public var serial: Int
    public init(page: Int, serial: Int) {
        self.page = page
        self.serial = serial
    }
}

/// Ask the table to start editing a cell.
public struct EditRequest: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable { case title, page }
    public var rowID: UUID
    public var field: Field
    public var serial: Int
    public init(rowID: UUID, field: Field, serial: Int) {
        self.rowID = rowID
        self.field = field
        self.serial = serial
    }
}

/// How new rows (recognition result, imported outline) join the draft. With an empty draft
/// every mode replaces.
public enum MergeMode: String, Sendable, Hashable, CaseIterable { case replace, append, insertAfterFocused }

public struct ReviewSession: Sendable, Hashable {
    public var queue: [UUID]
    public var position: Int
    public var onlyDoubtful: Bool
    public var finished: Bool

    public init(queue: [UUID], position: Int = 0, onlyDoubtful: Bool, finished: Bool = false) {
        self.queue = queue
        self.position = position
        self.onlyDoubtful = onlyDoubtful
        self.finished = finished
    }

    public var current: UUID? {
        guard !finished, queue.indices.contains(position) else { return nil }
        return queue[position]
    }
}

public struct ImportReport: Sendable, Hashable {
    public var format: TOCFormat
    public var count: Int
    /// TOCInterop warnings, verbatim English.
    public var warnings: [String]
    public var mode: MergeMode

    public init(format: TOCFormat, count: Int, warnings: [String], mode: MergeMode) {
        self.format = format
        self.count = count
        self.warnings = warnings
        self.mode = mode
    }
}

/// The one-line notice above the editor; the view words it (GUI_SPEC §7.2).
public enum Banner: Sendable, Hashable {
    case loadedExisting(count: Int)
    case recognitionApplied(count: Int, doubtful: Int)
    case imported(ImportReport)
    case wrote(WriteReport)
}
