import Foundation

public struct ApplyResult: Sendable {
    public let output: [UInt8]
    public let appendedByteCount: Int
    public let itemCount: Int
    public let pageCount: Int
}

/// High-level operations used by the CLI.
public enum Mulu {
    /// in.pdf bytes + TOC text -> in.pdf bytes + appended incremental update.
    /// The result is re-parsed with MuluCore's own reader and compared with what was
    /// intended before it is returned, so a writer bug fails loudly instead of
    /// producing a file.
    public static func apply(pdf: [UInt8], tocText: String, offset: Int) throws -> ApplyResult {
        let doc = try PDFFile(bytes: pdf)
        if doc.isEncrypted { throw MuluError.encrypted }
        guard try doc.catalog() != nil else { throw MuluError.noRoot }
        let pages = try doc.pageRefs()
        guard !pages.isEmpty else { throw MuluError.zeroPages }
        let toc = try TOCParser.parse(tocText)
        let specs = try outlineSpecs(toc, offset: offset, pages: pages)
        let appended = try IncrementalWriter.makeUpdate(for: doc, outline: specs)
        let output = pdf + appended
        try selfCheck(output: output, original: doc, expected: specs, pageCount: pages.count)
        return ApplyResult(output: output, appendedByteCount: appended.count, itemCount: specs.count, pageCount: pages.count)
    }

    /// Maps printed page numbers to 0-based physical page indices: physical page =
    /// page + offset (1-based).
    public static func outlineSpecs(_ toc: [TOCEntry], offset: Int, pages: [ObjRef]) throws -> [OutlineSpec] {
        try toc.map { e in
            let (physical, overflow) = e.page.addingReportingOverflow(offset)
            guard !overflow, physical >= 1, physical <= pages.count else {
                throw MuluError.pageOutOfRange(line: e.line, page: e.page, physical: overflow ? Int.max : physical, pageCount: pages.count)
            }
            return OutlineSpec(title: e.title, level: e.level, pageIndex: physical - 1)
        }
    }

    static func selfCheck(output: [UInt8], original doc: PDFFile, expected: [OutlineSpec], pageCount: Int) throws {
        let original = doc.bytes
        let isPrefix = output.count > original.count && output.withUnsafeBufferPointer { o in
            original.withUnsafeBufferPointer { i in
                i.isEmpty || memcmp(o.baseAddress!, i.baseAddress!, i.count) == 0
            }
        }
        guard isPrefix else {
            throw MuluError.selfCheckFailed("output is not a byte-prefix extension of the input")
        }
        let check: PDFFile
        do {
            check = try PDFFile(bytes: output)
        } catch {
            throw MuluError.selfCheckFailed("output does not parse: \(error)")
        }
        guard !check.isReconstructed else { throw MuluError.selfCheckFailed("output xref chain does not parse") }
        // The update must use the original's offset frame, and its startxref must land
        // exactly on the new section: Mulu's own lexer skips whitespace, so without this
        // an offset that is a few bytes off would still read back fine here.
        guard check.offsetBase == doc.offsetBase else {
            throw MuluError.selfCheckFailed("output offsets are read in a different frame (\(check.offsetBase)) than the input's (\(doc.offsetBase))")
        }
        guard check.startXRefIsExact else {
            throw MuluError.selfCheckFailed("the new startxref does not land exactly on the new cross-reference section")
        }
        let items = try check.readOutline()
        let got = items.map { "\($0.level)|\($0.pageIndex ?? -1)|\($0.title)" }
        let want = expected.map { "\($0.level)|\($0.pageIndex)|\($0.title)" }
        guard got == want else {
            throw MuluError.selfCheckFailed("outline read back differs from what was written")
        }
        guard try check.pageRefs().count == pageCount else {
            throw MuluError.selfCheckFailed("page count changed")
        }
        // Everything read back must resolve through the xref as written, with no
        // repair by scanning (the update republishes what the input needed repaired).
        guard check.repairedEntries.isEmpty else {
            throw MuluError.selfCheckFailed("objects \(check.repairedEntries.keys.sorted().prefix(5)) of the output resolve only by scanning")
        }
    }
}

/// What `mulu info` reports.
public struct DocumentInfo: Sendable, Equatable {
    public var xref: String
    public var revisions: Int
    public var objects: Int
    public var pages: Int
    public var encrypted: Bool
    public var hasOutline: Bool
    public var linearized: Bool
    public var size: Int

    public var json: String {
        "{\"xref\":\(JSONText.quote(xref)),\"revisions\":\(revisions),\"objects\":\(objects),\"pages\":\(pages),"
            + "\"encrypted\":\(encrypted),\"hasOutline\":\(hasOutline),\"linearized\":\(linearized),\"size\":\(size)}"
    }
}

extension PDFFile {
    public func info() -> DocumentInfo {
        DocumentInfo(
            xref: xrefKind.rawValue,
            revisions: revisionCount,
            objects: objectCount,
            pages: (try? pageRefs().count) ?? 0,
            encrypted: isEncrypted,
            hasOutline: hasOutlineItems(),
            linearized: isLinearized,
            size: bytes.count)
    }
}

public enum JSONText {
    public static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    r += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r + "\""
    }

    public static func outline(_ items: [OutlineItemInfo]) -> String {
        if items.isEmpty { return "[]" }
        let rows = items.map { item in
            "  {\"title\": \(quote(item.title)), \"level\": \(item.level), \"page_index\": \(item.pageIndex.map(String.init) ?? "null")}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
