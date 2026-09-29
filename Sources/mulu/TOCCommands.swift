import Foundation
import MuluCore
import MuluOCR

// TOC text subcommands:
//
//   mulu toc parse <raw.txt|-> [--offset N | --offset auto --pdf book.pdf] [--pdf book.pdf]
//                  [--roman-offset N] [--json] [--no-comments] [--strict] [--min-confidence X] [-o toc.txt]
//       Printed-TOC lines (from `mulu ocr-toc`, typed, or pasted from a bookstore page) →
//       Mulu TOC with PHYSICAL pages (printed + offset), levels inferred from the numbering.
//       Warnings (dropped lines, low-confidence entries, page-order violations) go to
//       stderr; low-confidence entries are also marked with a "# ?" comment line above
//       them. --strict exits 2 instead of printing when any entry is low-confidence or out
//       of order. --pdf checks pages against the document's page count.
//
//   mulu toc convert <in|-> [--from auto|mulu|pdfpatcher-xml|pdfdir|opml|json]
//                    --to mulu|pdfpatcher-xml|opml|json|pdfdir [--offset N] [-o out]
//
//   mulu export-outline <book.pdf> [--format mulu|opml|json|pdfpatcher-xml|pdfdir] [-o out]

let tocUsage = """
      mulu toc parse <raw.txt|-> [--offset N|auto] [--pdf book.pdf] [--roman-offset N] [--json] [--no-comments] [--strict] [-o toc.txt]
      mulu toc convert <in|-> [--from auto|mulu|pdfpatcher-xml|pdfdir|opml|json] --to mulu|pdfpatcher-xml|opml|json|pdfdir [--offset N] [-o out]
      mulu export-outline <book.pdf> [--format mulu|opml|json|pdfpatcher-xml|pdfdir] [-o out]
    """

private func warn(_ message: String) {
    let oneLine = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardError.write(Data("mulu: warning: \(oneLine)\n".utf8))
}

private func note(_ message: String) {
    FileHandle.standardError.write(Data("mulu: \(message)\n".utf8))
}

/// Splits arguments into positionals and options. `valued` options take a value
/// (`--x v` or `--x=v`); `flags` do not.
private func parseArgs(_ args: [String], valued: Set<String>, flags: Set<String>, usage: String) -> ([String], [String: String]) {
    var pos: [String] = []
    var opts: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" {
            pos += args[(i + 1)...]
            break
        }
        if a.hasPrefix("-") && a != "-" {
            var name = a, value: String? = nil
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") {
                name = String(a[..<eq])
                value = String(a[a.index(after: eq)...])
            }
            if valued.contains(name) {
                if value == nil {
                    i += 1
                    guard i < args.count else { fail("\(name) needs a value") }
                    value = args[i]
                }
                opts[name] = value!
            } else if flags.contains(name) && value == nil {
                opts[name] = ""
            } else {
                fail("unknown option \(a)\nusage:\n\(usage)")
            }
        } else {
            pos.append(a)
        }
        i += 1
    }
    return (pos, opts)
}

private func readInput(_ path: String) -> [UInt8] {
    path == "-" ? [UInt8](FileHandle.standardInput.readDataToEndOfFile()) : readFile(path)
}

private func intOption(_ opts: [String: String], _ name: String) -> Int? {
    guard let s = opts[name] else { return nil }
    guard let v = Int(s), abs(v) <= TOCParser.maxPage else { fail("\(name) must be an integer, got '\(s)'") }
    return v
}

/// Writes `text` to `outPath` (atomically, never over one of `inputs`) or to stdout.
private func emit(_ text: String, to outPath: String?, inputs: [String]) {
    guard let outPath else {
        FileHandle.standardOutput.write(Data(text.utf8))
        return
    }
    let outURL = URL(fileURLWithPath: outPath).standardizedFileURL.resolvingSymlinksInPath()
    for input in inputs where input != "-" {
        let inURL = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        if inURL.path == outURL.path { fail("output path is an input file; refusing to overwrite it") }
        if let a = fileIdentity(input), let b = fileIdentity(outPath), a == b { fail("output path is an input file; refusing to overwrite it") }
    }
    let dir = outURL.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(outURL.lastPathComponent).mulu-\(getpid())-\(UUID().uuidString).tmp")
    do {
        try Data(text.utf8).write(to: tmp, options: [.withoutOverwriting])
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(outPath): \(error.localizedDescription)")
    }
    if rename(tmp.path, outURL.path) != 0 {
        let err = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(outPath): \(err)")
    }
}

private func formatNamed(_ s: String) -> TOCFormat {
    guard let f = TOCFormat(rawValue: s.lowercased()) else {
        fail("unknown format '\(s)'; use one of \(TOCFormat.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return f
}

// MARK: - toc

func runTOC(_ args: [String]) -> Never {
    guard let sub = args.first else { fail("usage:\n\(tocUsage)") }
    let rest = Array(args.dropFirst())
    switch sub {
    case "parse": runTOCParse(rest)
    case "convert": runTOCConvert(rest)
    case "-h", "--help", "help":
        print("usage:\n\(tocUsage)")
        exit(0)
    default: fail("unknown toc command '\(sub)'\nusage:\n\(tocUsage)")
    }
}

func runTOCParse(_ args: [String]) -> Never {
    let (pos, opts) = parseArgs(args, valued: ["--offset", "--pdf", "--roman-offset", "--min-confidence", "-o", "--output"],
                                flags: ["--json", "--no-comments", "--strict", "--quiet"], usage: tocUsage)
    guard pos.count == 1 else { fail("usage: mulu toc parse <raw.txt|-> [--offset N|auto] [--pdf book.pdf] [-o toc.txt]") }
    let inPath = pos[0]
    var options = PrintedTOCOptions()
    if let s = opts["--min-confidence"] {
        guard let v = Double(s), v >= 0, v <= 1 else { fail("--min-confidence must be between 0 and 1") }
        options.lowConfidence = v
    }
    options.romanOffset = intOption(opts, "--roman-offset")
    if let pdf = opts["--pdf"] {
        let doc = loadPDF(pdf)
        do { options.pageCount = try doc.pageRefs().count } catch { fail("\(pdf): \(error)") }
    }
    if opts["--offset"]?.lowercased() == "auto" {
        guard let pdf = opts["--pdf"] else { fail("--offset auto needs --pdf <book.pdf>") }
        do {
            let report = try OffsetDetector(url: URL(fileURLWithPath: pdf)).detect()
            guard report.status == .ok, let off = report.offset else {
                fail("cannot determine the page offset confidently (\(report.reason)); pass --offset N")
            }
            options.offset = off
            note("detected page offset \(off >= 0 ? "+" : "")\(off) (confidence \(String(format: "%.2f", report.confidence)), \(report.agreeing)/\(report.samples) samples)")
        } catch {
            fail("\(pdf): \(error)")
        }
    } else {
        options.offset = intOption(opts, "--offset") ?? 0
    }

    let bytes = readInput(inPath)
    guard let text = TOCInterop.decodeText(bytes) else { fail("\(inPath): cannot decode the text (not UTF-8 or GB18030)") }
    let result = PrintedTOCParser.parse(text, options: options)
    let usable = result.tocEntries
    let low = result.lowConfidenceEntries
    let violations = result.orderViolations

    if opts["--quiet"] == nil {
        var reported = Set<String>()
        for w in result.warnings {
            warn(w.description)
            reported.insert(w.description)
        }
        for e in low {
            let notes = e.notes.filter { !reported.contains("line \(e.line): \($0)") }
            let why = notes.isEmpty ? "" : ": " + notes.joined(separator: "; ")
            warn("line \(e.line): low confidence \(String(format: "%.2f", e.confidence)) for '\(MuluTOCFormat.oneLine(e.title))'\(why)")
        }
        let unmapped = result.entries.count - usable.count
        var summary = "parsed \(result.entries.count) entr\(result.entries.count == 1 ? "y" : "ies")"
        var extras: [String] = []
        if !low.isEmpty { extras.append("\(low.count) low-confidence") }
        if !violations.isEmpty { extras.append("\(violations.count) out of page order") }
        if unmapped > 0 { extras.append("\(unmapped) without a physical page") }
        if !extras.isEmpty { summary += " (" + extras.joined(separator: ", ") + ")" }
        summary += "; physical = printed \(options.offset >= 0 ? "+" : "-") \(abs(options.offset))"
        note(summary)
    }
    guard !result.entries.isEmpty else { fail("\(inPath): no TOC entries found") }
    if opts["--strict"] != nil && (!low.isEmpty || !violations.isEmpty || usable.count < result.entries.count) {
        fail("refusing (--strict): \(low.count) low-confidence entr\(low.count == 1 ? "y" : "ies"), \(violations.count) out of page order, \(result.entries.count - usable.count) unmapped")
    }
    guard opts["--json"] != nil || !usable.isEmpty else { fail("\(inPath): no entry could be mapped to a physical page") }
    let out = opts["--json"] != nil
        ? result.json + "\n"
        : result.muluText(header: opts["--no-comments"] == nil, annotate: opts["--no-comments"] == nil)
    emit(out, to: opts["-o"] ?? opts["--output"], inputs: [inPath] + (opts["--pdf"].map { [$0] } ?? []))
    exit(0)
}

func runTOCConvert(_ args: [String]) -> Never {
    let (pos, opts) = parseArgs(args, valued: ["--from", "--to", "--offset", "--title", "-o", "--output"], flags: ["--quiet"], usage: tocUsage)
    guard pos.count == 1 else { fail("usage: mulu toc convert <in|-> [--from FORMAT] --to FORMAT [--offset N] [-o out]") }
    guard let toName = opts["--to"] else { fail("toc convert needs --to mulu|pdfpatcher-xml|opml|json|pdfdir") }
    let to = formatNamed(toName)
    let inPath = pos[0]
    let bytes = readInput(inPath)
    let from: TOCFormat
    if let f = opts["--from"], f.lowercased() != "auto" {
        from = formatNamed(f)
    } else {
        from = TOCInterop.detect(bytes, fileName: inPath == "-" ? nil : inPath)
        if opts["--quiet"] == nil { note("reading \(inPath) as \(from.rawValue)") }
    }
    var result: TOCInteropResult
    do {
        result = try TOCInterop.read(bytes, format: from)
        result.entries = try TOCInterop.shift(result.entries, by: intOption(opts, "--offset") ?? 0)
    } catch {
        fail("\(inPath): \(error)")
    }
    if opts["--quiet"] == nil { for w in result.warnings { warn(w) } }
    guard !result.entries.isEmpty else { fail("\(inPath): no outline entries found") }
    let title = opts["--title"] ?? (inPath == "-" ? nil : ((inPath as NSString).lastPathComponent as NSString).deletingPathExtension)
    emit(TOCInterop.write(result.entries, format: to, title: title), to: opts["-o"] ?? opts["--output"], inputs: [inPath])
    exit(0)
}

// MARK: - export-outline

func runExportOutline(_ args: [String]) -> Never {
    let (pos, opts) = parseArgs(args, valued: ["--format", "-f", "-o", "--output", "--title"], flags: ["--quiet"], usage: tocUsage)
    guard pos.count == 1 else { fail("usage: mulu export-outline <book.pdf> [--format mulu|opml|json|pdfpatcher-xml|pdfdir] [-o out]") }
    let format = formatNamed(opts["--format"] ?? opts["-f"] ?? "mulu")
    let path = pos[0]
    let doc = loadPDF(path)
    if doc.isEncrypted { fail("\(path): the PDF is encrypted; cannot read its outline") }
    let items: [OutlineItemInfo]
    do { items = try doc.readOutline() } catch { fail("\(path): \(error)") }
    let result = TOCInterop.entries(fromOutline: items)
    if opts["--quiet"] == nil {
        for w in result.warnings { warn(w) }
        if items.isEmpty { note("\(path) has no outline") }
    }
    let title = opts["--title"] ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    emit(TOCInterop.write(result.entries, format: format, title: title), to: opts["-o"] ?? opts["--output"], inputs: [path])
    exit(0)
}
