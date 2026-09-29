import Foundation

/// One line of a TOC file.
public struct TOCEntry: Sendable, Equatable {
    public var title: String
    public var level: Int  // 0-based
    public var page: Int   // as written in the file (1-based, before --offset)
    public var line: Int   // 1-based line number, for error messages

    public init(title: String, level: Int, page: Int, line: Int) {
        self.title = title
        self.level = level
        self.page = page
        self.line = line
    }
}

/// Parser for the TOC text format:
///
///     <indent><title><whitespace><page>
///
/// - Level = number of leading TABs, or number of leading spaces / 2 (a mix counts
///   each tab as one level and each pair of spaces as one level). A full-width space
///   (U+3000) counts as one level; any other leading whitespace is refused.
/// - The page is the LAST whitespace-separated token and must be a positive integer.
/// - Lines whose first character is '#' are comments; blank lines are ignored.
/// - A line's level may exceed the previous line's by at most 1 (so the first
///   entry must be at level 0).
public enum TOCParser {
    public static let maxPage = 100_000_000

    public static func parse(_ text: String) throws -> [TOCEntry] {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }  // UTF-8 BOM
        // Split on LF, CR and CRLF only (Swift treats CRLF as one Character).
        let lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }

        var out: [TOCEntry] = []
        var previousLevel = -1
        for (i, line) in lines.enumerated() {
            let lineNo = i + 1
            if line.first == "#" { continue }
            if line.allSatisfy(\.isWhitespace) { continue }

            var tabs = 0, spaces = 0, fullWidth = 0
            var idx = line.startIndex
            while idx < line.endIndex {
                let c = line[idx]
                if c == "\t" {
                    tabs += 1
                } else if c == " " {
                    spaces += 1
                } else if c == "\u{3000}" {
                    fullWidth += 1
                } else {
                    break
                }
                idx = line.index(after: idx)
            }
            // A full-width (ideographic) space is as wide as two ASCII spaces, and is
            // how Word/WPS users indent Chinese TOCs: it counts as one level.
            let level = tabs + fullWidth + spaces / 2
            // Any other leading whitespace (NBSP, en/em spaces...) has no agreed level;
            // refuse instead of silently flattening the hierarchy.
            if let c = line[idx...].first, c.isWhitespace {
                let scalar = c.unicodeScalars.first!
                let hex = String(scalar.value, radix: 16, uppercase: true)
                let name = scalar.properties.name.map { " \($0)" } ?? ""
                throw MuluError.tocSyntax(
                    line: lineNo,
                    message: "indentation uses U+\(String(repeating: "0", count: max(0, 4 - hex.count)) + hex)\(name); indent with TABs, spaces or full-width spaces (U+3000)")
            }

            var rest = line[idx...]
            while let last = rest.last, last.isWhitespace { rest = rest.dropLast() }
            guard let sep = rest.lastIndex(where: \.isWhitespace) else {
                throw MuluError.tocSyntax(line: lineNo, message: "expected '<title> <page>', got '\(rest)'")
            }
            let pageToken = rest[rest.index(after: sep)...]
            var title = rest[..<sep]
            while let last = title.last, last.isWhitespace { title = title.dropLast() }
            while let first = title.first, first.isWhitespace { title = title.dropFirst() }

            guard !title.isEmpty else {
                throw MuluError.tocSyntax(line: lineNo, message: "missing title")
            }
            guard !pageToken.isEmpty, pageToken.allSatisfy({ $0.isASCII && $0.isNumber }),
                  pageToken.count <= 12, let page = Int(pageToken), page > 0, page <= maxPage
            else {
                throw MuluError.tocSyntax(line: lineNo, message: "page must be a positive integer, got '\(pageToken)'")
            }
            guard level <= previousLevel + 1 else {
                throw MuluError.tocSyntax(
                    line: lineNo,
                    message: previousLevel < 0
                        ? "the first entry must not be indented (level \(level))"
                        : "level jumps from \(previousLevel) to \(level); it may increase by at most 1")
            }
            out.append(TOCEntry(title: String(title), level: level, page: page, line: lineNo))
            previousLevel = level
        }
        return out
    }
}
