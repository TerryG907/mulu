import PDFKit
import SwiftUI
import MuluAppModel

/// PDFKit's `PDFView`, driven by the model's preview requests and reporting the page it shows.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let request: PreviewRequest?
    /// In review mode ↓ ↑ ↩ Esc belong to the table: the preview can still be scrolled, zoomed
    /// and clicked, but the keyboard focus goes back to the table right after.
    let keepsFocusOutOfPreview: Bool
    let returnFocus: @MainActor () -> Void
    let onPageShown: @MainActor (Int) -> Void

    func makeCoordinator() -> PDFPreviewCoordinator {
        PDFPreviewCoordinator()
    }

    func makeNSView(context: Context) -> MuluPDFView {
        let view = MuluPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        view.refusesKeyboardFocus = keepsFocusOutOfPreview
        context.coordinator.returnFocus = returnFocus
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MuluPDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageShown = onPageShown
        coordinator.returnFocus = returnFocus
        view.refusesKeyboardFocus = keepsFocusOutOfPreview
        if keepsFocusOutOfPreview {
            coordinator.returnFocusIfInPreview()
        }
        if view.document !== document {
            view.document = document
        }
        if let request, request.serial != coordinator.lastSerial {
            coordinator.lastSerial = request.serial
            coordinator.show(page: request.page)
        }
    }

    static func dismantleNSView(_ view: MuluPDFView, coordinator: PDFPreviewCoordinator) {
        coordinator.detach()
    }
}

/// `PDFView` that can decline the keyboard focus (review mode).
final class MuluPDFView: PDFView {
    var refusesKeyboardFocus = false

    override var acceptsFirstResponder: Bool {
        refusesKeyboardFocus ? false : super.acceptsFirstResponder
    }
}
