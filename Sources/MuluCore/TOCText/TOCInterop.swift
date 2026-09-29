import Foundation

/// Outline interchange formats. Every format carries (title, level, page) where page
/// is the 1-based PHYSICAL page, except pdfdir text whose numbers are printed pages
/// (convert with an offset).
///
///  mulu            Mulu TOC: `<TABs><title> <page>` (see TOCParser)
///  pdfpatcher-xml  PDFPatcher / PDF补丁丁 info file: <PDF信息><文档书签><书签 文本="…" 动作="转到页面" 页码="N">,
///                  nested <书签> for children (English element/attribute names Bookmark/Title/Page
///                  are accepted on input). Any declared encoding (GB2312 in older files).
///  pdfdir          chroming/pdfdir text: one "title+page" per line, the page is the trailing
///                  number (or "(12)", "[12]", "【12】"…), a missing page means the previous
///                  entry's page; levels from leading whitespace (pdfdir's level-by-space: each
///                  distinct indent width is one level, narrowest first).
///  opml            OPML 2.0 <outline text="…" page="N"> nested in <body>.
///  json            [{"title": "…", "level": 0, "page": 1}, …]; on input also nested
///                  "children", "text"/"name" for the title and 0-based "page_index" (as
///                  printed by `mulu dump-outline`).
public enum TOCFormat: String, CaseIterable, Sendable {
    case mulu
    case pdfpatcherXML = "pdfpatcher-xml"
    case pdfdir
    case opml
    case json
}

public struct TOCInteropResult: Sendable, Equatable {
    public var entries: [TOCEntry]
    public var warnings: [String]
}

/// Writer for the Mulu TOC format; its output always parses back with TOCParser.
public enum MuluTOCFormat {
    /// Newlines, TABs and control characters become spaces; runs of whitespace collapse.
    public static func oneLine(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for c in s {
            if c.isWhitespace || c.isNewline || (c.unicodeScalars.first.map { $0.value < 0x20 || $0.value == 0x7F } ?? false) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(c)
        }
        return out
    }

    public static func line(title: String, level: Int, page: Int) -> String {
        var t = oneLine(title)
        if t.isEmpty { t = "(untitled)" }
        if level == 0 && t.hasPrefix("#") { t = "＃" + t.dropFirst() }  // '#' at column 0 starts a comment
        return String(repeating: "\t", count: max(0, level)) + t + " " + String(page)
    }

    public static func write(_ entries: [TOCEntry]) -> String {
        entries.map { line(title: $0.title, level: $0.level, page: $0.page) + "\n" }.joined()
    }
}

public enum TOCInterop {
    // MARK: reading

    public static func read(_ bytes: [UInt8], format: TOCFormat) throws -> TOCInteropResult {
        switch format {
        case .mulu:
            let text = try utf8Text(bytes)
            return TOCInteropResult(entries: try TOCParser.parse(text), warnings: [])
        case .pdfdir:
            guard let text = decodeText(bytes) else { throw MuluError.usage("cannot decode the text file (not UTF-8 or GB18030)") }
            return normalize(readPdfdir(text), source: "line")
        case .json:
            return normalize(try readJSON(bytes), source: "item")
        case .opml:
            let root = try xmlRoot(bytes)
            guard root.name.lowercased() == "opml" else { throw MuluError.usage("not an OPML file (root element <\(root.name)>)") }
            guard let body = root.children.first(where: { $0.name.lowercased() == "body" }) else {
                throw MuluError.usage("OPML file has no <body>")
            }
            var raw: [RawItem] = []
            walk(body, level: 0, into: &raw, isItem: { $0.name.lowercased() == "outline" }) { el in
                (el.attribute("text", "title", "_text") ?? "",
                 el.attribute("page", "_page", "pageNumber", "pagenum", "pageno").flatMap(parseInt))
            }
            return normalize(raw, source: "line")
        case .pdfpatcherXML:
            let root = try xmlRoot(bytes)
            let isBookmark: (MiniXMLElement) -> Bool = { $0.name == "书签" || $0.name.lowercased() == "bookmark" }
            let container = findFirst(root) { ["文档书签", "documentbookmark", "bookmarks", "outline"].contains($0.name.lowercased()) } ?? root
            var raw: [RawItem] = []
            var notLinks: [String] = []
            walk(container, level: 0, into: &raw, isItem: isBookmark) { el in
                let title = el.attribute("文本", "Title", "text") ?? ""
                let page = el.attribute("页码", "Page").flatMap(parseInt)
                if page == nil, let action = el.attribute("动作", "Action"), !["转到页面", "goto"].contains(action.lowercased()) {
                    notLinks.append("line \(el.line): '\(title)' is a '\(action)' bookmark, not a page link")
                }
                return (title, page)
            }
            var r = normalize(raw, source: "line")
            r.warnings = notLinks + r.warnings
            return r
        }
    }

    /// Guesses the format from the file name and content.
    public static func detect(_ bytes: [UInt8], fileName: String? = nil) -> TOCFormat {
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        if ext == "opml" { return .opml }
        if ext == "json" { return .json }
        let head = (MiniXML.decode(Array(bytes.prefix(4096))) ?? "").drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if head.hasPrefix("[") || head.hasPrefix("{") { return .json }
        if head.hasPrefix("<") || ext == "xml" { return head.lowercased().contains("<opml") ? .opml : .pdfpatcherXML }
        if let text = String(bytes: bytes, encoding: .utf8), (try? TOCParser.parse(text)) != nil { return .mulu }
        return .pdfdir
    }

    // MARK: writing

    public static func write(_ entries: [TOCEntry], format: TOCFormat, title: String? = nil) -> String {
        switch format {
        case .mulu:
            return MuluTOCFormat.write(entries)
        case .pdfdir:
            return entries.map { e in
                String(repeating: "  ", count: e.level) + MuluTOCFormat.oneLine(e.title) + " " + String(e.page) + "\n"
            }.joined()
        case .json:
            if entries.isEmpty { return "[]\n" }
            return "[\n" + entries.map { e in
                "  {\"title\": \(JSONText.quote(e.title)), \"level\": \(e.level), \"page\": \(e.page)}"
            }.joined(separator: ",\n") + "\n]\n"
        case .opml:
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n"
            out += "  <head>\n    <title>\(MiniXML.escape(title ?? "Outline"))</title>\n  </head>\n  <body>\n"
            out += tree(entries, baseIndent: "    ", indentUnit: "  ") { e in
                "outline text=\"\(MiniXML.escape(e.title))\" page=\"\(e.page)\""
            } close: { "outline" }
            return out + "  </body>\n</opml>\n"
        case .pdfpatcherXML:
            var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<PDF信息 程序名称=\"Mulu\" 程序版本=\"0.3.3\">\n\t<文档书签>\n"
            out += tree(entries, baseIndent: "\t\t", indentUnit: "\t") { e in
                "书签 文本=\"\(MiniXML.escape(e.title))\" 动作=\"转到页面\" 页码=\"\(e.page)\""
            } close: { "书签" }
            return out + "\t</文档书签>\n</PDF信息>\n"
        }
    }

    /// Outline items read from a PDF → entries (page = page index + 1). Items whose
    /// destination cannot be resolved take the previous item's page, with a warning.
    public static func entries(fromOutline items: [OutlineItemInfo]) -> TOCInteropResult {
        var raw: [RawItem] = []
        for (i, it) in items.enumerated() {
            raw.append(RawItem(title: it.title, level: it.level, page: it.pageIndex.map { $0 + 1 }, line: i + 1))
        }
        return normalize(raw, source: "outline item")
    }

    /// Adds `offset` to every page; pages that fall below 1 are an error.
    public static func shift(_ entries: [TOCEntry], by offset: Int) throws -> [TOCEntry] {
        guard offset != 0 else { return entries }
        return try entries.map { e in
            var e = e
            e.page += offset
            guard e.page >= 1 else {
                throw MuluError.pageOutOfRange(line: e.line, page: e.page - offset, physical: e.page, pageCount: 0)
            }
            return e
        }
    }

    /// Decodes a text file: UTF-8 (BOM optional), UTF-16 with BOM, else GB18030 (common
    /// for TOC text saved on Chinese Windows). nil if none fits.
    public static func decodeText(_ bytes: [UInt8]) -> String? {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(bytes: bytes, encoding: .utf16)
        }
        var b = bytes[...]
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { b = b.dropFirst(3) }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        if let enc = MiniXML.encoding(named: "gb18030"), let s = String(bytes: b, encoding: enc) { return s }
        return nil
    }

    // MARK: - internals

    struct RawItem {
        var title: String
        var level: Int
        var page: Int?
        var line: Int
    }

    static func utf8Text(_ bytes: [UInt8]) throws -> String {
        var b = bytes[...]
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { b = b.dropFirst(3) }
        guard let s = String(bytes: b, encoding: .utf8) else { throw MuluError.usage("input is not valid UTF-8") }
        return s
    }

    static func parseInt(_ s: String) -> Int? {
        let t = TOCChars.halfWidth(s).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 9 else { return nil }
        return Int(t)
    }

    static func xmlRoot(_ bytes: [UInt8]) throws -> MiniXMLElement {
        guard let text = MiniXML.decode(bytes) else { throw MuluError.usage("cannot decode the XML file (unknown encoding)") }
        do {
            return try MiniXML.parse(text)
        } catch let e as MiniXML.ParseError {
            throw MuluError.tocSyntax(line: e.line, message: "XML: \(e.message)")
        }
    }

    static func findFirst(_ el: MiniXMLElement, _ pred: (MiniXMLElement) -> Bool) -> MiniXMLElement? {
        var queue = [el]
        var k = 0
        while k < queue.count {
            let e = queue[k]
            if pred(e) { return e }
            queue += e.children
            k += 1
        }
        return nil
    }

    static func walk(_ parent: MiniXMLElement, level: Int, into out: inout [RawItem],
                     isItem: (MiniXMLElement) -> Bool, extract: (MiniXMLElement) -> (String, Int?)) {
        for c in parent.children where isItem(c) {
            let (t, p) = extract(c)
            out.append(RawItem(title: t, level: level, page: p, line: c.line))
            walk(c, level: level + 1, into: &out, isItem: isItem, extract: extract)
        }
    }

    static func tree(_ entries: [TOCEntry], baseIndent: String, indentUnit: String,
                     open: (TOCEntry) -> String, close: () -> String) -> String {
        var out = ""
        var levels: [Int] = []  // levels of currently open elements
        // Normalise so a child is at most one deeper than its parent.
        var prev = -1
        let norm = entries.map { e -> TOCEntry in
            var e = e
            e.level = max(0, min(e.level, prev + 1))
            prev = e.level
            return e
        }
        for (i, e) in norm.enumerated() {
            while let top = levels.last, top >= e.level {
                levels.removeLast()
                out += baseIndent + String(repeating: indentUnit, count: levels.count) + "</\(close())>\n"
            }
            let pad = baseIndent + String(repeating: indentUnit, count: e.level)
            let hasChild = i + 1 < norm.count && norm[i + 1].level > e.level
            if hasChild {
                out += pad + "<\(open(e))>\n"
                levels.append(e.level)
            } else {
                out += pad + "<\(open(e)) />\n"
            }
        }
        while !levels.isEmpty {
            levels.removeLast()
            out += baseIndent + String(repeating: indentUnit, count: levels.count) + "</\(close())>\n"
        }
        return out
    }

    /// Fills missing pages (previous page, else 1), clamps level jumps and empty titles.
    static func normalize(_ raw: [RawItem], source: String) -> TOCInteropResult {
        var out: [TOCEntry] = []
        var warnings: [String] = []
        var prevLevel = -1
        var lastPage: Int? = nil
        for r in raw {
            var page = r.page
            if let p = page, p < 1 {
                warnings.append("\(source) \(r.line): page \(p) is not a valid page")
                page = nil
            }
            if page == nil {
                let fallback = lastPage ?? 1
                warnings.append("\(source) \(r.line): '\(MuluTOCFormat.oneLine(r.title))' has no page; using page \(fallback)")
                page = fallback
            }
            var level = max(0, r.level)
            if level > prevLevel + 1 {
                warnings.append("\(source) \(r.line): level \(level) follows level \(max(prevLevel, 0)); lowered to \(prevLevel + 1)")
                level = prevLevel + 1
            }
            var title = MuluTOCFormat.oneLine(r.title)
            if title.isEmpty {
                warnings.append("\(source) \(r.line): empty title")
                title = "(untitled)"
            }
            out.append(TOCEntry(title: title, level: level, page: page!, line: r.line))
            prevLevel = level
            lastPage = page
        }
        return TOCInteropResult(entries: out, warnings: warnings)
    }

    // MARK: pdfdir

    static func readPdfdir(_ text: String) -> [RawItem] {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        let lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        var rows: [(indent: Int, title: String, page: Int?, line: Int)] = []
        for (i, l) in lines.enumerated() {
            var s = String(l)
            while let last = s.last, last.isWhitespace { s.removeLast() }
            guard !s.isEmpty else { continue }
            let indent = s.prefix(while: { $0.isWhitespace }).count
            let (title, page) = pdfdirSplit(s)
            var t = title
            while let last = t.last, last == " " || last == "." || last == "-" { t.removeLast() }
            rows.append((indent, t.trimmingCharacters(in: .whitespaces), page, i + 1))
        }
        // level-by-space: each distinct indent width is one level (at most 6 levels).
        let widths = Array(Set(rows.map(\.indent))).sorted()
        return rows.map { r in
            RawItem(title: r.title, level: min(widths.firstIndex(of: r.indent)!, 5), page: r.page, line: r.line)
        }
    }

    /// pdfdir's split_page_num: trailing (possibly negative) digits, or a bracketed number.
    static func pdfdirSplit(_ s: String) -> (String, Int?) {
        let cs = Array(s)
        var j = cs.count
        while j > 0 && cs[j - 1].isASCII && cs[j - 1].isNumber { j -= 1 }
        if j < cs.count {
            var start = j
            if j > 0 && cs[j - 1] == "-" && !(j > 1 && cs[j - 2] == "-") { start = j - 1 }
            let digits = String(cs[start...])
            if digits.count <= 10, let v = Int(digits) { return (String(cs[..<start]), v) }
        }
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"), ("（", "）"), ("【", "】"), ("「", "」"), ("《", "》")]
        for (o, c) in pairs where cs.last == c {
            if let k = cs.lastIndex(of: o) {
                let inner = String(cs[(k + 1)..<(cs.count - 1)])
                if !inner.isEmpty, inner.count <= 10, inner.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(inner) {
                    return (String(cs[..<k]), v)
                }
            }
        }
        return (s, nil)
    }

    // MARK: JSON

    static func readJSON(_ bytes: [UInt8]) throws -> [RawItem] {
        var b = bytes[...]
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { b = b.dropFirst(3) }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: Data(b), options: [.fragmentsAllowed])
        } catch {
            throw MuluError.usage("invalid JSON: \((error as NSError).localizedDescription)")
        }
        var list: [Any]
        if let a = obj as? [Any] {
            list = a
        } else if let d = obj as? [String: Any],
                  let a = (["items", "outline", "entries", "bookmarks", "toc", "children"].lazy.compactMap { d[$0] as? [Any] }.first) {
            list = a
        } else {
            throw MuluError.usage("JSON must be an array of {title, level, page} objects")
        }
        var out: [RawItem] = []
        var counter = 0
        func intValue(_ v: Any?) -> Int? {
            if let n = v as? NSNumber {
                let d = n.doubleValue
                guard d.rounded() == d, abs(d) < 1e9 else { return nil }
                return Int(d)
            }
            if let s = v as? String { return parseInt(s) }
            return nil
        }
        func visit(_ arr: [Any], depth: Int) throws {
            guard depth < 64 else { throw MuluError.usage("JSON outline nested too deeply") }
            for el in arr {
                counter += 1
                guard let d = el as? [String: Any] else {
                    throw MuluError.usage("JSON item \(counter) is not an object")
                }
                let title = (d["title"] ?? d["text"] ?? d["name"] ?? d["Title"]) as? String ?? ""
                let level = intValue(d["level"]) ?? depth
                var page = intValue(d["page"] ?? d["Page"])
                if page == nil, let idx = intValue(d["page_index"] ?? d["pageIndex"]) { page = idx + 1 }
                out.append(RawItem(title: title, level: level, page: page, line: counter))
                if let kids = (d["children"] ?? d["kids"] ?? d["items"]) as? [Any] {
                    try visit(kids, depth: level + 1)
                }
            }
        }
        list = list.isEmpty ? [] : list
        try visit(list, depth: 0)
        return out
    }
}
