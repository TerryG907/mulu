import Foundation
import MuluCore

// mulu — add a PDF outline (bookmarks) by appending an incremental update.
//
//   mulu apply <in.pdf> <toc.txt> -o <out.pdf> [--offset N]
//   mulu info <in.pdf>
//   mulu dump-outline <in.pdf>
//
// Exit status: 0 success, 2 refusal/error (one line on stderr, no output file).

let usage = """
    usage:
      mulu apply <in.pdf> <toc.txt> -o <out.pdf> [--offset N]
      mulu info <in.pdf>
      mulu dump-outline <in.pdf>
    \(autoUsage)
    \(ocrUsage)
    \(tocUsage)
    """

func fail(_ message: String) -> Never {
    let oneLine = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardError.write(Data("mulu: \(oneLine)\n".utf8))
    exit(2)
}

func readFile(_ path: String) -> [UInt8] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { fail("\(path): no such file") }
    guard !isDir.boolValue else { fail("\(path): is a directory") }
    do {
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("\(path): cannot read (\(error.localizedDescription))")
    }
}

/// (device, inode) of the file a path resolves to, following symlinks.
func fileIdentity(_ path: String) -> (UInt64, UInt64)? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
}

func loadPDF(_ path: String) -> PDFFile {
    do {
        return try PDFFile(bytes: readFile(path))
    } catch {
        fail("\(path): \(error)")
    }
}

func runApply(_ args: [String]) -> Never {
    var positional: [String] = []
    var outPath: String? = nil
    var offset = 0
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(a) needs a value") }
            return args[i]
        }
        func parseOffset(_ s: String) -> Int {
            guard let v = Int(s), abs(v) <= TOCParser.maxPage else { fail("--offset must be an integer, got '\(s)'") }
            return v
        }
        if a == "-o" || a == "--output" {
            outPath = value()
        } else if a.hasPrefix("--output=") {
            outPath = String(a.dropFirst("--output=".count))
        } else if a == "--offset" {
            offset = parseOffset(value())
        } else if a.hasPrefix("--offset=") {
            offset = parseOffset(String(a.dropFirst("--offset=".count)))
        } else if a == "--" {
            positional += args[(i + 1)...]
            break
        } else if a.hasPrefix("-") && a != "-" {
            fail("unknown option \(a)\n\(usage)")
        } else {
            positional.append(a)
        }
        i += 1
    }
    guard positional.count == 2 else { fail("apply needs <in.pdf> and <toc.txt>") }
    guard let outPath, !outPath.isEmpty else { fail("apply needs -o <out.pdf>") }
    let inPath = positional[0]
    let tocPath = positional[1]

    // Never write over the input: compare normalised paths and, if the output
    // already exists, the underlying file identity (catches symlinks, hard links
    // and case-insensitive aliases).
    let inURL = URL(fileURLWithPath: inPath).standardizedFileURL.resolvingSymlinksInPath()
    let outURL = URL(fileURLWithPath: outPath).standardizedFileURL.resolvingSymlinksInPath()
    if inURL.path == outURL.path { fail("output path is the input file; refusing to modify the input") }
    if let a = fileIdentity(inPath), let b = fileIdentity(outPath), a == b {
        fail("output path is the input file; refusing to modify the input")
    }
    if tocPath != "-", let a = fileIdentity(tocPath), let b = fileIdentity(outPath), a == b {
        fail("output path is the TOC file")
    }

    let input = readFile(inPath)
    let tocBytes: [UInt8]
    if tocPath == "-" {
        tocBytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
    } else {
        tocBytes = readFile(tocPath)
    }
    guard let tocText = String(bytes: tocBytes, encoding: .utf8) else {
        fail("\(tocPath): TOC is not valid UTF-8")
    }

    let result: ApplyResult
    do {
        result = try Mulu.apply(pdf: input, tocText: tocText, offset: offset)
    } catch {
        fail("\(error)")
    }

    // Write to a temporary file in the destination directory, then rename, so a
    // failure can never leave a partial out.pdf behind.
    let dir = outURL.deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
        fail("\(dir.path): output directory does not exist")
    }
    let tmp = dir.appendingPathComponent(".\(outURL.lastPathComponent).mulu-\(getpid())-\(UUID().uuidString).tmp")
    do {
        try Data(result.output).write(to: tmp, options: [.withoutOverwriting])
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(outPath): \(error.localizedDescription)")
    }
    if rename(tmp.path, outURL.path) != 0 {
        let err = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: tmp)
        fail("cannot write \(outPath): \(err)")
    }
    print("{\"output\":\(JSONText.quote(outPath)),\"input_size\":\(input.count),\"output_size\":\(result.output.count),"
        + "\"appended\":\(result.appendedByteCount),\"items\":\(result.itemCount),\"pages\":\(result.pageCount)}")
    exit(0)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { fail("missing command\n\(usage)") }
let rest = Array(argv.dropFirst())

switch command {
case "apply":
    runApply(rest)
case "info":
    guard rest.count == 1 else { fail("usage: mulu info <in.pdf>") }
    let doc = loadPDF(rest[0])
    // An encrypted file is described as far as possible (its strings and streams can't
    // be read). Otherwise a catalog or page tree that apply would refuse is an error
    // here too, rather than "pages": 0.
    if !doc.isEncrypted {
        do { _ = try doc.pageRefs() } catch { fail("\(rest[0]): \(error)") }
    }
    print(doc.info().json)
case "dump-outline":
    guard rest.count == 1 else { fail("usage: mulu dump-outline <in.pdf>") }
    let doc = loadPDF(rest[0])
    if doc.isEncrypted { fail("\(rest[0]): the PDF is encrypted; cannot read its outline") }
    do {
        print(JSONText.outline(try doc.readOutline()))
    } catch {
        fail("\(rest[0]): \(error)")
    }
case "auto":
    runAuto(rest)
case "ocr-toc":
    runOCRToc(rest)
case "detect-offset":
    runDetectOffset(rest)
case "toc":
    runTOC(rest)
case "export-outline":
    runExportOutline(rest)
case "-h", "--help", "help":
    print(usage)
default:
    fail("unknown command '\(command)'\n\(usage)")
}
