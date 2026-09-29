import Foundation

/// Every failure MuluCore can report. All of them are "refusals" from the CLI's
/// point of view: the tool exits 2 and never writes an output file.
public enum MuluError: Error, Equatable, CustomStringConvertible, Sendable {
    case notPDF
    case encrypted
    case unparseableXRef(String)
    case noRoot
    case zeroPages
    case pageOutOfRange(line: Int, page: Int, physical: Int, pageCount: Int)
    case tocSyntax(line: Int, message: String)
    case ambiguous(String)
    case malformed(String)
    case unsupported(String)
    case io(String)
    case usage(String)
    case selfCheckFailed(String)

    public var description: String {
        switch self {
        case .notPDF:
            return "not a PDF file (no %PDF- header in the first 1024 bytes)"
        case .encrypted:
            return "the PDF is encrypted; refusing to modify it"
        case .unparseableXRef(let why):
            return "cannot parse the cross-reference data: \(why)"
        case .noRoot:
            return "the trailer has no usable /Root (document catalog)"
        case .zeroPages:
            return "the document has no pages"
        case let .pageOutOfRange(line, page, physical, count):
            return "TOC line \(line): page \(page) maps to physical page \(physical), but the document has \(count) page(s)"
        case let .tocSyntax(line, message):
            return "TOC line \(line): \(message)"
        case .ambiguous(let why):
            return "ambiguous file structure: \(why)"
        case .malformed(let why):
            return "malformed PDF: \(why)"
        case .unsupported(let why):
            return "unsupported PDF feature: \(why)"
        case .io(let why):
            return why
        case .usage(let why):
            return why
        case .selfCheckFailed(let why):
            return "internal self-check failed, no output written: \(why)"
        }
    }
}
