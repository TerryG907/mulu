import Foundation
import MuluCore

extension DocumentModel {
    // MARK: - Write (GUI_SPEC §5.11)

    public func writeReadiness() -> WriteReadiness {
        var blockers: [WriteBlocker] = []
        if isPreview || phase != .ready || summary == nil { blockers.append(.notReady) }
        if isWriting { blockers.append(.busy) }
        blockers += rowBlockers()
        var doubtful = 0
        var order = 0
        // Error rows are blockers already; these two counts are for the "write anyway?" question.
        for (i, r) in draft.rows.enumerated() where !r.confirmed && derived.statuses[i] == .doubtful {
            if r.doubts.contains(where: \.isDoubt) { doubtful += 1 }
            if derived.issues[i].contains(where: { if case .pageBeforePrevious = $0 { return true } else { return false } }) { order += 1 }
        }
        return WriteReadiness(blockers: blockers, unconfirmedDoubtful: doubtful, orderWarnings: order)
    }

    /// "<dir>/<name><suffix>.pdf"
    public func defaultOutputURL(suffix: String = "-目录") -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(name + suffix).appendingPathExtension("pdf")
    }

    /// WriteError.wouldOverwriteInput / .notWritable
    public func validateOutputURL(_ url: URL) throws {
        try OutlineWriter.validate(output: url, input: self.url)
    }

    /// Writes a new PDF = the original bytes + the outline (throws WriteError). The output is
    /// read back from disk and checked before this returns; on success the draft becomes the
    /// new baseline (not dirty) and `banner` reports the write.
    public func write(to output: URL) async throws -> WriteReport {
        let readiness = writeReadiness()
        guard readiness.canWrite, let summary, let entries = draft.outputEntries() else {
            throw WriteError.blocked(readiness.blockers.isEmpty ? [.notReady] : readiness.blockers)
        }
        try validateOutputURL(output)
        isWriting = true
        defer { isWriting = false }
        let input = url
        let fingerprint = summary.fingerprint
        let written = draft
        let report = try await Task.detached(priority: .userInitiated) {
            try OutlineWriter.write(input: input, fingerprint: fingerprint, entries: entries, output: output)
        }.value
        lastWrite = report
        baseline = written.projection()
        isDirty = draft.projection() != baseline
        banner = .wrote(report)
        return report
    }
}
