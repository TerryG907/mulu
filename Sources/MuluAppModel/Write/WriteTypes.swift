import Foundation

public enum WriteBlocker: Sendable, Hashable {
    case notReady, busy, noRows
    case row(id: UUID, index: Int, issue: RowIssue)
}

public struct WriteReadiness: Sendable, Hashable {
    public var blockers: [WriteBlocker]
    /// Rows not yet confirmed that carry a doubt (status .doubtful).
    public var unconfirmedDoubtful: Int
    /// Rows not yet confirmed whose page is smaller than the previous row's.
    public var orderWarnings: Int

    public init(blockers: [WriteBlocker], unconfirmedDoubtful: Int, orderWarnings: Int) {
        self.blockers = blockers
        self.unconfirmedDoubtful = unconfirmedDoubtful
        self.orderWarnings = orderWarnings
    }

    public var canWrite: Bool { blockers.isEmpty }
}

public struct WriteReport: Sendable, Hashable {
    public var output: URL
    public var inputSize: Int
    public var outputSize: Int
    public var appendedBytes: Int
    public var items: Int
    public var pageCount: Int
    /// Verified on the file re-read from disk.
    public var originalBytesUnchanged: Bool
    public var seconds: Double

    public init(output: URL, inputSize: Int, outputSize: Int, appendedBytes: Int, items: Int, pageCount: Int,
                originalBytesUnchanged: Bool, seconds: Double) {
        self.output = output
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.appendedBytes = appendedBytes
        self.items = items
        self.pageCount = pageCount
        self.originalBytesUnchanged = originalBytesUnchanged
        self.seconds = seconds
    }
}

public enum WriteError: Error, Sendable, Hashable, CustomStringConvertible {
    case blocked([WriteBlocker])
    case wouldOverwriteInput
    case notWritable(String)
    case inputChanged
    /// MuluError.description, verbatim.
    case refused(String)
    case io(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .blocked(let bs):
            let rows = bs.compactMap { b -> String? in
                guard case let .row(_, index, issue) = b else { return nil }
                return "entry \(index + 1): \(WriteError.describe(issue))"
            }
            let other = bs.compactMap { b -> String? in
                switch b {
                case .notReady: return "the document is not open"
                case .busy: return "a write is already running"
                case .noRows: return "the outline is empty"
                case .row: return nil
                }
            }
            let all = other + rows
            return "the outline cannot be written: " + all.prefix(5).joined(separator: "; ") + (all.count > 5 ? "; …" : "")
        case .wouldOverwriteInput:
            return "the output is the input file; Mulu never overwrites the original"
        case .notWritable(let s):
            return s
        case .inputChanged:
            return "the input file changed after it was opened; reopen it and write again"
        case .refused(let s):
            return s
        case .io(let s):
            return s
        case .verificationFailed(let s):
            return "the written file failed verification and was removed: \(s)"
        }
    }

    static func describe(_ issue: RowIssue) -> String {
        switch issue {
        case .emptyTitle: return "empty title"
        case .noPhysicalPage: return "no page"
        case let .pageOutOfRange(page, count): return "page \(page) is outside 1–\(count)"
        case .pageBeforePrevious(let prev): return "page is before the previous entry's page \(prev)"
        case .leadingHash: return "a leading '#' of a top-level title is written as '＃'"
        }
    }
}
