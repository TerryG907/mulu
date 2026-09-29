import Foundation
import MuluOCR

// OCR subcommands (macOS Vision):
//
//   mulu ocr-toc <book.pdf> --pages 5-7 [--json] [--verbose] [--debug-dir DIR]
//       Prints the printed table of contents found on those physical pages, one entry line
//       per output line in reading order (left column before right column):
//           <2 spaces per indentation step><title>[<TAB><printed page>]
//       Dot leaders are removed; the page token is normalized (ASCII digits, "12-15" ranges
//       kept, roman numerals in lower case). Lines without a page number (wrapped titles,
//       part headings) are printed without a TAB. Warnings (low confidence, repaired digits,
//       two-column pages) go to stderr; --json prints every line with its geometry,
//       confidence and notes instead.
//
//   mulu detect-offset <book.pdf> [--samples N] [--min-agree N] [--verbose]
//       Reads the page numbers printed in the header/footer bands of ~24 body pages and
//       prints {"offset", "confidence", "samples", "votes", ...} as JSON. physical = printed
//       + offset. Exit 0 when the offset is trusted (status "ok"); otherwise the JSON has
//       "offset": null, the reason goes to stderr and the exit status is 2.

let ocrUsage = """
      mulu ocr-toc <book.pdf> --pages 5-7 [--json] [--verbose] [--debug-dir DIR]
      mulu detect-offset <book.pdf> [--samples N] [--min-agree N] [--verbose]
    """

private func ocrFail(_ message: String) -> Never {
    let oneLine = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardError.write(Data("mulu: \(oneLine)\n".utf8))
    exit(2)
}

private func ocrNote(_ message: String) {
    FileHandle.standardError.write(Data("mulu: \(message)\n".utf8))
}

/// Parses `args` into positional arguments and `--name value` / `--name=value` options.
/// `flags` take no value.
private func ocrParseArgs(_ args: [String], valued: Set<String>, flags: Set<String>) -> ([String], [String: String]) {
    var positional: [String] = []
    var opts: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" {
            positional += args[(i + 1)...]
            break
        }
        if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
            let name = String(a[..<eq])
            guard valued.contains(name) else { ocrFail("unknown option \(name)") }
            opts[name] = String(a[a.index(after: eq)...])
        } else if valued.contains(a) {
            i += 1
            guard i < args.count else { ocrFail("\(a) needs a value") }
            opts[a] = args[i]
        } else if flags.contains(a) {
            opts[a] = ""
        } else if a.hasPrefix("-") && a != "-" {
            ocrFail("unknown option \(a)")
        } else {
            positional.append(a)
        }
        i += 1
    }
    return (positional, opts)
}

private func ocrInputURL(_ path: String) -> URL {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { ocrFail("\(path): no such file") }
    guard !isDir.boolValue else { ocrFail("\(path): is a directory") }
    return URL(fileURLWithPath: path)
}

private func secs(_ d: Double) -> String { String(format: "%.2f s", d) }

func runOCRToc(_ args: [String]) -> Never {
    let (pos, opts) = ocrParseArgs(args, valued: ["--pages", "--debug-dir", "--dpi"], flags: ["--json", "--verbose"])
    guard pos.count == 1 else { ocrFail("usage: mulu ocr-toc <book.pdf> --pages 5-7 [--json] [--verbose]") }
    guard let spec = opts["--pages"] else { ocrFail("ocr-toc needs --pages (physical pages of the printed TOC, e.g. 5-7)") }
    let url = ocrInputURL(pos[0])
    var options = TOCReadOptions()
    if let d = opts["--dpi"] {
        guard let v = Double(d), v >= 72, v <= 1200 else { ocrFail("--dpi must be a number between 72 and 1200") }
        options.dpi = v
    }
    if let dir = opts["--debug-dir"] { options.debugDirectory = URL(fileURLWithPath: dir) }
    let result: TOCReadResult
    do {
        let reader = try TOCPageReader(url: url)
        let pages = try parsePageList(spec, pageCount: reader.rasterizer.pageCount)
        guard pages.count <= maxTOCPageCount else {
            ocrFail("--pages \(spec) names \(pages.count) pages; a printed TOC is rarely longer than \(maxTOCPageCount) pages"
                + " (each takes about 2.5 s of OCR). Run the TOC in parts of at most \(maxTOCPageCount) pages")
        }
        result = try reader.read(pages: pages, options: options)
    } catch {
        ocrFail("\(pos[0]): \(error)")
    }
    let verbose = opts["--verbose"] != nil
    if opts["--json"] != nil {
        print(ocrTocJSON(result))
    } else {
        for line in result.lines { print(line.text) }
        for w in result.warnings { ocrNote("warning: \(w)") }
    }
    if verbose {
        for p in result.pages {
            ocrNote("page \(p.page): \(p.pixelSize.width)x\(p.pixelSize.height) px, render \(secs(p.renderSeconds)), OCR \(secs(p.ocrSeconds)), "
                + "column re-OCR \(secs(p.reocrSeconds)), \(p.observations) observations -> \(p.lines) lines, "
                + "\(p.columns) column\(p.columns == 1 ? "" : "s"), skew \(String(format: "%.2f", p.skewDegrees))°")
        }
    }
    guard !result.lines.isEmpty else { ocrFail("\(pos[0]): no text recognized on pages \(spec)") }
    exit(0)
}

private func ocrTocJSON(_ r: TOCReadResult) -> String {
    func q(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
    func f(_ d: Double) -> String { String(format: "%.4f", d) }
    let lines = r.lines.map { l -> String in
        let page = l.page.map { "{\"text\":\(q($0.text)),\"value\":\($0.value),\"kind\":\(q($0.kind.rawValue)),\"noisy\":\($0.noisy)}" } ?? "null"
        return "{\"source_page\":\(l.sourcePage),\"column\":\(l.column),\"indent\":\(l.indentLevel),"
            + "\"x\":\(f(l.x)),\"y\":\(f(l.y)),\"w\":\(f(l.width)),\"h\":\(f(l.height)),"
            + "\"title\":\(q(l.title)),\"page\":\(page),\"page_source\":\(l.pageSource.map { q($0.rawValue) } ?? "null"),"
            + "\"confidence\":\(String(format: "%.3f", l.confidence)),\"notes\":[\(l.notes.map(q).joined(separator: ","))],"
            + "\"text\":\(q(l.text))}"
    }
    let pages = r.pages.map { p in
        "{\"page\":\(p.page),\"width_px\":\(p.pixelSize.width),\"height_px\":\(p.pixelSize.height),"
            + "\"render_s\":\(f(p.renderSeconds)),\"ocr_s\":\(f(p.ocrSeconds)),\"reocr_s\":\(f(p.reocrSeconds)),"
            + "\"observations\":\(p.observations),\"lines\":\(p.lines),\"columns\":\(p.columns),\"skew_deg\":\(f(p.skewDegrees))}"
    }
    return "{\"lines\":[\n" + lines.joined(separator: ",\n") + "\n],\"pages\":[" + pages.joined(separator: ",")
        + "],\"warnings\":[" + r.warnings.map(q).joined(separator: ",") + "]}"
}

func runDetectOffset(_ args: [String]) -> Never {
    let (pos, opts) = ocrParseArgs(args, valued: ["--samples", "--min-agree", "--band"], flags: ["--verbose"])
    guard pos.count == 1 else { ocrFail("usage: mulu detect-offset <book.pdf> [--samples N] [--min-agree N]") }
    let url = ocrInputURL(pos[0])
    var options = OffsetDetector.Options()
    if let s = opts["--samples"] {
        guard let v = Int(s), v >= 1, v <= 500 else { ocrFail("--samples must be an integer between 1 and 500") }
        options.samples = v
    }
    if let s = opts["--min-agree"] {
        guard let v = Int(s), v >= 1, v <= 500 else { ocrFail("--min-agree must be an integer between 1 and 500") }
        options.minAgreeing = v
    }
    if let s = opts["--band"] {
        guard let v = Double(s), v > 0.02, v <= 0.5 else { ocrFail("--band must be a fraction between 0.02 and 0.5") }
        options.band = v
    }
    let verbose = opts["--verbose"] != nil
    let report: OffsetReport
    do {
        let detector = try OffsetDetector(url: url)
        report = try detector.detect(options: options) { s in
            if verbose {
                let texts = s.texts.map { "«\($0)»" }.joined(separator: " ")
                ocrNote("page \(s.page): \(secs(s.seconds)), printed \(s.printed) \(texts)")
            }
        }
    } catch {
        ocrFail("\(pos[0]): \(error)")
    }
    print(report.json)
    if report.status != .ok { ocrFail("cannot determine the page offset confidently: \(report.reason)") }
    exit(0)
}
