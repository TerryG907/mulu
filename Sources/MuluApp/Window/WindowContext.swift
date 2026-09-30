import AppKit
import Observation

/// Per-window state that exists whether or not the window holds a document: its identity in
/// `AppState`, the hosting `NSWindow`, the document session and the routing entry point.
@MainActor @Observable
final class WindowContext {
    let token = UUID()
    @ObservationIgnored weak var window: NSWindow?
    var session: DocumentSession?
    /// The file this window has taken but whose session may not exist yet (de-duplicates opens).
    @ObservationIgnored var claimedURL: URL?
    /// The user clicked, dropped or used a menu in this window; spare-window auto-close stops.
    var userInteracted = false
    var isDropTargeted = false
    private(set) var notice: WindowNotice?
    var showsNotice = false
    /// Installed by `DocumentWindow`; routes URLs into this window or new ones (GUI_SPEC §6.8).
    @ObservationIgnored var router: (([URL]) -> Void)?
    /// Installed by `DocumentWindow`: sets the window's file URL (the scene's value) to nil.
    @ObservationIgnored var forgetURL: (() -> Void)?
    @ObservationIgnored var closeGuard: WindowCloseGuard?
    /// The window has been closed and not shown again. SwiftUI keeps the scene of a closed window
    /// (at least the last one) alive and hidden, with this context in its `@State`, and does not
    /// call `onDisappear` (measured on macOS 26, `scripts/smoke_app.sh` stage E). So closing
    /// drops the document here, and a closed window takes no part in routing until it is shown again.
    private(set) var isClosed = false

    /// The window is closing: free the document (model, PDFKit document, thumbnails) and forget
    /// the file, so a later reopening of the same file starts from the file, not from a hidden
    /// window's old draft.
    func windowDidClose() {
        if let session {
            session.model.cancelRecognition()
            session.model.undoManager.removeAllActions(withTarget: session.model)
        }
        session = nil
        claimedURL = nil
        userInteracted = false
        isDropTargeted = false
        isClosed = true
        window?.isDocumentEdited = false
        forgetURL?()
    }

    /// The window is on screen (again).
    func windowDidShow() {
        if isClosed { isClosed = false }
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        userInteracted = true
        router?(urls)
    }

    /// Routes files that came from outside (Finder, Dock); not a user action in this window.
    func routeExternal(_ urls: [URL]) {
        router?(urls)
    }

    /// Asks for PDFs with an open panel and routes them like a drop.
    func chooseAndOpen() {
        userInteracted = true
        Task {
            let urls = await OpenPanels.choosePDFs()
            open(urls)
        }
    }

    func present(_ notice: WindowNotice) {
        self.notice = notice
        showsNotice = true
    }

    func closeWindow() {
        window?.performClose(nil)
    }
}

