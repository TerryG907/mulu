import Foundation
import MuluCore

/// The write path (GUI_SPEC §5.11 step 4): the same `Mulu.apply` as `mulu apply` (with its
/// self-check), plus an input-changed check, a temporary file that is read back and verified
/// before it is renamed into place, so a failed check never touches the chosen output (not even
/// a file the save panel agreed to replace). Synchronous; run it off the main actor.
///
/// Memory: the input is held once (N) and the output once (N + outline) while writing; the
/// output buffer is released before the temporary file is read back, so the peak is about 2N.
enum OutlineWriter {
    /// Refuses the input file itself (also through a symbolic or hard link), a folder, and a
    /// folder that does not exist or cannot be written to.
    static func validate(output: URL, input: URL) throws {
        let out = output.standardizedFileURL
        if FileIdentity.same(out, input) { throw WriteError.wouldOverwriteInput }
        try checkDestination(out)
    }

    static func checkDestination(_ out: URL) throws {
        if FileIdentity.isDirectory(out) {
            throw WriteError.notWritable("cannot write \(out.path): it is a folder")
        }
        let dir = out.deletingLastPathComponent()
        guard FileIdentity.isDirectory(dir) else {
            throw WriteError.notWritable("cannot write \(out.path): the folder \(dir.path) does not exist")
        }
        guard access(dir.path, W_OK) == 0 else {
            throw WriteError.notWritable("cannot write \(out.path): no permission to create files in \(dir.path)")
        }
    }

    /// What `Mulu.apply` produced, without the output bytes (they are on disk by then).
    private struct Applied {
        var outputSize: Int
        var appendedBytes: Int
        var items: Int
        var pageCount: Int
    }

    /// `verify` is the read-back check (a parameter so tests can make it fail).
    static func write(input: URL, fingerprint: FileFingerprint, entries: [TOCEntry], output: URL,
                      verify: (URL, [UInt8], [TOCEntry]) throws -> Void = verifyWritten) throws -> WriteReport {
        let clock = ContinuousClock()
        let t0 = clock.now
        let out = output.standardizedFileURL
        try validate(output: out, input: input)

        // 1. The input must still be the file that was opened.
        guard let now = try? FileFingerprint.of(input), now == fingerprint else { throw WriteError.inputChanged }
        let original: [UInt8]
        do {
            original = try FileIdentity.readBytes(input)
        } catch {
            throw WriteError.io("cannot read \(input.path): \(error.localizedDescription)")
        }
        guard original.count == fingerprint.size else { throw WriteError.inputChanged }

        // 2–3. Apply (with its self-check) and write a temporary file next to the output.
        let tmp = FileIdentity.temporaryURL(next: out)
        let applied: Applied
        do {
            applied = try applyAndWrite(original: original, entries: entries, to: tmp)
            // 4. Read the temporary file back from disk: the original bytes and the outline as
            //    the draft shows it. Only a verified file is renamed over the output.
            try verify(tmp, original, entries)
            try FileIdentity.moveIntoPlace(tmp, to: out)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let d = clock.now - t0
        return WriteReport(
            output: out, inputSize: original.count, outputSize: applied.outputSize, appendedBytes: applied.appendedBytes,
            items: applied.items, pageCount: applied.pageCount, originalBytesUnchanged: true,
            seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    /// `Mulu.apply` plus the byte-prefix check of `mulu auto`, then the output goes to `tmp`.
    /// The output buffer lives only inside this function.
    private static func applyAndWrite(original: [UInt8], entries: [TOCEntry], to tmp: URL) throws -> Applied {
        let result: ApplyResult
        do {
            result = try Mulu.apply(pdf: original, tocText: MuluTOCFormat.write(entries), offset: 0)
        } catch let e as MuluError {
            throw WriteError.refused(e.description)
        } catch {
            throw WriteError.refused("\(error)")
        }
        guard result.output.count > original.count, FileIdentity.hasPrefix(result.output, original) else {
            throw WriteError.verificationFailed("the output does not start with the original bytes")
        }
        try result.output.withUnsafeBytes { try FileIdentity.writeNewFile($0, to: tmp) }
        return Applied(outputSize: result.output.count, appendedBytes: result.appendedByteCount,
                       items: result.itemCount, pageCount: result.pageCount)
    }

    /// The title as it ends up in the PDF: the Mulu text format turns a leading '#' of a
    /// top-level title into '＃' (a '#' at column 0 starts a comment), see `RowIssue.leadingHash`.
    static func writtenTitle(_ entry: TOCEntry) -> String {
        var t = MuluTOCFormat.oneLine(entry.title)
        if t.isEmpty { t = "(untitled)" }
        if entry.level == 0 && t.hasPrefix("#") { t = "＃" + t.dropFirst() }
        return t
    }

    /// Reads `file` back and compares it with what the draft asked for (`entries`), not with a
    /// re-parse of the generated text, so a change made on the way would be caught.
    static func verifyWritten(_ file: URL, original: [UInt8], entries: [TOCEntry]) throws {
        let written: [UInt8]
        do {
            written = try FileIdentity.readBytes(file)
        } catch {
            throw WriteError.verificationFailed("cannot read the output back: \(error.localizedDescription)")
        }
        guard written.count > original.count, FileIdentity.hasPrefix(written, original) else {
            throw WriteError.verificationFailed("the file on disk does not start with the original bytes")
        }
        let items: [OutlineItemInfo]
        do {
            items = try PDFFile(bytes: written).readOutline()
        } catch {
            throw WriteError.verificationFailed("the output does not read back: \(error)")
        }
        let want = entries.map { "\($0.level)|\($0.page - 1)|\(writtenTitle($0))" }
        let got = items.map { "\($0.level)|\($0.pageIndex ?? -1)|\($0.title)" }
        guard want == got else {
            throw WriteError.verificationFailed("the outline read back from disk differs from the draft")
        }
    }
}
