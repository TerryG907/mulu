import AppKit
import PDFKit

/// Owns the page-changed observation, the jump-to-page logic of `PDFPreview`, and (in review
/// mode) gives the keyboard focus back to the table after a click in the preview: PDFKit's inner
/// views take the focus themselves, so declining it in `MuluPDFView` alone is not enough.
@MainActor
final class PDFPreviewCoordinator: NSObject {
    var onPageShown: (@MainActor (Int) -> Void)?
    var returnFocus: (@MainActor () -> Void)?
    var lastSerial: Int?
    private weak var view: MuluPDFView?
    private var clickMonitor: Any?

    func attach(to view: MuluPDFView) {
        self.view = view
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            // After AppKit has handled the click (and moved the focus).
            Task { @MainActor [weak self] in self?.returnFocusIfInPreview() }
            return event
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// In review mode: if the preview (or a view inside it) has the keyboard focus, hand it back.
    func returnFocusIfInPreview() {
        guard let view, view.refusesKeyboardFocus, let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view) else { return }
        returnFocus?()
    }

    /// Jumps to a 1-based page. Deferred one turn so a freshly created view has a frame first.
    func show(page: Int) {
        Task { @MainActor [weak self] in
            guard let view = self?.view, let document = view.document,
                  page >= 1, page <= document.pageCount,
                  let target = document.page(at: page - 1) else { return }
            if view.currentPage !== target {
                view.go(to: target)
            }
        }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard let view, let page = view.currentPage, let document = view.document else { return }
        onPageShown?(document.index(for: page) + 1)
    }
}
