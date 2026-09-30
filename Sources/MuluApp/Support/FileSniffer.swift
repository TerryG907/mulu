import Foundation

/// Cheap checks on dropped or opened files, done before a window commits to them.
enum FileSniffer {
    /// Extensions that `TOCInterop` can import (GUI_SPEC §5.9).
    static let outlineExtensions: Set<String> = ["txt", "xml", "opml", "json"]

    /// A PDF by extension, or by a `%PDF-` header in the first 1024 bytes (the same rule as MuluCore).
    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.pathExtension.lowercased() == "pdf" { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024) else { return false }
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    static func isOutlineFile(_ url: URL) -> Bool {
        url.isFileURL && outlineExtensions.contains(url.pathExtension.lowercased())
    }

    /// A comparison key for "is this the same file": standardized path with symlinks resolved.
    static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
