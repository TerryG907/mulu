import Foundation
import MuluCore

extension TOCFormat {
    /// File extension of an exported outline.
    public var fileExtension: String {
        switch self {
        case .mulu, .pdfdir: return "txt"
        case .pdfpatcherXML: return "xml"
        case .opml: return "opml"
        case .json: return "json"
        }
    }
}

/// An outline file that is not worth reading (GUI_SPEC §5.9).
public enum ImportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Larger than any outline file: a dropped log or data dump would freeze the window.
    case tooLarge(size: Int, limit: Int)

    public var description: String {
        switch self {
        case let .tooLarge(size, limit):
            return "the file is \(size) bytes; an outline file is at most \(limit) bytes"
        }
    }
}

extension DocumentModel {
    // MARK: - Import (GUI_SPEC §5.9)

    /// 20 MB: a 5,000-entry outline in the most verbose format is well under 2 MB.
    public nonisolated static let maxImportBytes = 20 * 1024 * 1024

    /// Reads an outline file off the main actor; throws ImportError.tooLarge above `limit`
    /// (checked before reading) and the file system's error otherwise.
    public nonisolated static func readOutlineFile(at url: URL, limit: Int = maxImportBytes) async throws -> [UInt8] {
        try await Task.detached(priority: .userInitiated) {
            try readOutlineFileNow(at: url, limit: limit)
        }.value
    }

    nonisolated static func readOutlineFileNow(at url: URL, limit: Int) throws -> [UInt8] {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else { throw ImportError.tooLarge(size: size, limit: limit) }
        let bytes = try FileIdentity.readBytes(url)
        guard bytes.count <= limit else { throw ImportError.tooLarge(size: bytes.count, limit: limit) }
        return bytes
    }

    /// Synchronous import of a file (tests, small files); the app reads with `readOutlineFile`.
    @discardableResult
    public func importOutline(from url: URL, format: TOCFormat? = nil, mode: MergeMode = .replace) throws -> ImportReport {
        let bytes = try DocumentModel.readOutlineFileNow(at: url, limit: DocumentModel.maxImportBytes)
        return try importOutline(bytes: bytes, fileName: url.lastPathComponent, format: format, mode: mode)
    }

    /// Reads an outline file (format detected when nil) and merges it into the draft (one undo
    /// step). pdfdir pages are printed pages (they follow the offset); every other format
    /// gives fixed physical pages. Throws MuluError from TOCInterop.
    @discardableResult
    public func importOutline(bytes: [UInt8], fileName: String?, format: TOCFormat?, mode: MergeMode) throws -> ImportReport {
        let fmt = format ?? TOCInterop.detect(bytes, fileName: fileName)
        let result = try TOCInterop.read(bytes, format: fmt)
        // A warning names its source line ("line 12: …", "item 3: …"); it is attached to the
        // row read from that line when exactly one row was.
        var byLine: [Int: [String]] = [:]
        for w in result.warnings {
            if let n = DocumentModel.warningLine(w) { byLine[n, default: []].append(w) }
        }
        var lineCounts: [Int: Int] = [:]
        for e in result.entries { lineCounts[e.line, default: 0] += 1 }
        let rows = result.entries.map { e -> OutlineRow in
            var row = OutlineRow(title: e.title, level: e.level)
            if fmt == .pdfdir {
                row.printedPage = PrintedPageRef(style: .arabic, value: e.page)
            } else {
                row.manualPage = e.page
            }
            if lineCounts[e.line] == 1, let ws = byLine[e.line] {
                row.doubts = ws.map { DoubtReason(kind: .importWarning, detail: $0) }
            }
            return row
        }
        let focus = focusedRowID.flatMap { index(of: $0) }
        let merged = DocumentModel.merge(rows, mapping: PageMapping(), into: draft, mode: mode, after: focus)
        let replaced = mode == .replace || draft.rows.isEmpty
        let firstNew = rows.first.map(\.id)
        commit(merged, action: ActionName.importOutline, selection: firstNew.map { [$0] } ?? [], focus: .some(firstNew),
               offsetInfo: replaced ? .some(nil) : .none, annotated: true)
        let report = ImportReport(format: fmt, count: rows.count, warnings: result.warnings, mode: mode)
        banner = .imported(report)
        if replaced { advisories = [] }
        return report
    }

    /// "line 12: …" / "item 3: …" / "outline item 4: …" → 12 / 3 / 4.
    static func warningLine(_ w: String) -> Int? {
        guard let colon = w.firstIndex(of: ":") else { return nil }
        let head = w[..<colon]
        guard let space = head.lastIndex(of: " ") else { return nil }
        let prefix = head[..<space]
        guard ["line", "item", "outline item"].contains(String(prefix)) else { return nil }
        return Int(head[head.index(after: space)...])
    }

    // MARK: - Export

    /// The outline in `format` with physical pages (as `mulu export-outline`; pdfdir too).
    /// Throws WriteError.blocked when a row has no page, an empty title or a page out of range.
    public func exportText(format: TOCFormat) throws -> String {
        let blockers = rowBlockers()
        guard blockers.isEmpty, let entries = draft.outputEntries() else {
            throw WriteError.blocked(blockers.isEmpty ? [.noRows] : blockers)
        }
        return TOCInterop.write(entries, format: format, title: url.deletingPathExtension().lastPathComponent)
    }

    /// Writes the exported outline atomically; never onto the open PDF.
    public func export(to url: URL, format: TOCFormat) throws {
        let dest = url.standardizedFileURL
        if !isPreview, FileIdentity.same(dest, self.url) { throw WriteError.wouldOverwriteInput }
        let text = try exportText(format: format)
        try OutlineWriter.checkDestination(dest)
        try FileIdentity.writeAtomically(Array(text.utf8), to: dest)
    }

    /// "<dir>/<name><suffix>.<ext>"
    public func defaultExportURL(format: TOCFormat, suffix: String = "-目录") -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(name + suffix).appendingPathExtension(format.fileExtension)
    }

    /// Row problems that stop writing and exporting (plus .noRows for an empty outline).
    func rowBlockers() -> [WriteBlocker] {
        if draft.rows.isEmpty { return [.noRows] }
        var out: [WriteBlocker] = []
        for (i, list) in derived.issues.enumerated() {
            for issue in list where issue.blocksWrite {
                out.append(.row(id: draft.rows[i].id, index: i, issue: issue))
            }
        }
        return out
    }
}
