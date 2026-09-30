import AppKit
import MuluAppModel
import PDFKit

/// Smoke check for the lifetime of a document window (`MULU_SMOKE_CLOSE=1`): closes the window
/// the way the close button does and waits for the session, the model, the PDFKit document and
/// the thumbnail renderer to be freed. A window that keeps its document alive after closing
/// leaks the PDF and up to 30 MB of thumbnails per book.
///
/// Prints one line to stderr and exits: 0 = freed, 4 = still alive four seconds after closing.
@MainActor
final class SmokeCloseProbe {
    private weak var session: DocumentSession?
    private weak var model: DocumentModel?
    private weak var document: PDFDocument?
    private weak var thumbnails: ThumbnailRenderer?
    private weak var window: NSWindow?

    private init(_ session: DocumentSession) {
        self.session = session
        model = session.model
        window = session.window
    }

    /// Returns at once; the check runs in its own task, which holds only weak references, so the
    /// caller's references are gone by the time the window closes.
    static func start(_ session: DocumentSession) {
        let probe = SmokeCloseProbe(session)
        Task { @MainActor in
            await probe.run()
        }
    }

    private var alive: [String] {
        var out: [String] = []
        if session != nil { out.append("session") }
        if model != nil { out.append("model") }
        if document != nil { out.append("PDF document") }
        if thumbnails != nil { out.append("thumbnails") }
        return out
    }

    private func run() async {
        // Let the preview and the thumbnails open first (at most two seconds), so they are checked too.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let viewState = session?.viewState, viewState != .idle, viewState != .loading { break }
        }
        document = session?.pdfDocument
        thumbnails = session?.thumbnails
        let opened = document != nil && thumbnails != nil
        window?.performClose(nil)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if alive.isEmpty { break }
        }
        let left = alive
        let views = opened ? "" : " (the preview or the thumbnails never opened)"
        let text = left.isEmpty
            ? "mulu smoke: document released after close: true\(views)\n"
            : "mulu smoke: document released after close: false (alive: \(left.joined(separator: ", ")))\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(left.isEmpty && opened ? 0 : 4)
    }
}
