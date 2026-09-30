import AppKit
import MuluAppModel
import MuluCore
import Observation
import PDFKit

/// View-layer companion of one `DocumentModel`: the PDFKit document for the preview, the
/// thumbnail renderer, sheet state, and the actions shared by menus, toolbar, buttons and the table.
///
/// PDFKit objects are not Sendable and never enter the model (GUI_SPEC §6.10).
@MainActor @Observable
final class DocumentSession {
    /// Whether the preview (PDFKit) and the page images (CoreGraphics, also used by the OCR)
    /// could be opened. Mulu's own parser may read a damaged file that neither of them can.
    enum ViewState: Equatable {
        case idle, loading, ready
        /// `previewFailed`: PDFKit cannot open the file; `pagesFailed`: CoreGraphics cannot.
        case opened(previewFailed: Bool, pagesFailed: Bool)
    }

    let model: DocumentModel
    private(set) var pdfDocument: PDFDocument?
    private(set) var thumbnails: ThumbnailRenderer?
    private(set) var viewState: ViewState = .idle
    var sheet: SessionSheet?
    var lastExportFormat: TOCFormat = .mulu

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var tableView: NSTableView?
    @ObservationIgnored private var pageAspects: [Int: Double] = [:]

    init(url: URL, undoManager: UndoManager?) {
        model = DocumentModel(url: url, undoManager: undoManager)
    }

    var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    /// The two views' own documents, opened off the main actor (a damaged file can take PDFKit
    /// a long time to scan). The results cross back in an unchecked box: PDFKit documents are
    /// created on one thread and only used on the main thread afterwards.
    private struct OpenedViews: @unchecked Sendable {
        var document: PDFDocument?
        var thumbnails: ThumbnailRenderer?
    }

    /// Opens the PDFKit document and the thumbnail renderer once the model has parsed the file.
    func prepareViews() async {
        guard model.phase == .ready, viewState == .idle else { return }
        viewState = .loading
        let url = model.url
        let opened = await Task.detached(priority: .userInitiated) {
            OpenedViews(document: PDFDocument(url: url), thumbnails: try? ThumbnailRenderer(url: url))
        }.value
        pdfDocument = opened.document
        thumbnails = opened.thumbnails
        if opened.document != nil, opened.thumbnails != nil {
            viewState = .ready
        } else {
            viewState = .opened(previewFailed: opened.document == nil, pagesFailed: opened.thumbnails == nil)
        }
    }

    var previewFailed: Bool {
        if case .opened(true, _) = viewState { return true }
        return false
    }

    /// CoreGraphics cannot read the pages: no thumbnails and no OCR (it renders with CoreGraphics).
    var pagesFailed: Bool {
        if case .opened(_, true) = viewState { return true }
        return false
    }

    /// Width / height of a page's crop box as displayed (rotation applied); 0.75 until known.
    func pageAspect(_ page: Int) -> Double {
        if let cached = pageAspects[page] { return cached }
        guard let pdfPage = pdfDocument?.page(at: page - 1) else { return 0.75 }
        let box = pdfPage.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return 0.75 }
        let quarterTurns = (pdfPage.rotation / 90) % 2 != 0
        let aspect = quarterTurns ? box.height / box.width : box.width / box.height
        pageAspects[page] = aspect
        return aspect
    }

    // MARK: - Targets

    /// Rows a command acts on: the selection, or the focused row when nothing is selected.
    var targetIDs: Set<UUID> {
        if !model.selection.isEmpty { return model.selection }
        return model.focusedRowID.map { [$0] } ?? []
    }

    /// The single row a command acts on.
    var focusID: UUID? {
        model.focusedRowID ?? model.selection.first
    }

    var isRecognizing: Bool {
        if case .running = model.recognition { return true }
        return false
    }

    var canEdit: Bool {
        model.phase == .ready && !model.isWriting
    }

    var canWrite: Bool {
        canEdit && !model.draft.rows.isEmpty
    }

    /// OCR needs CoreGraphics to render the TOC pages.
    var canRecognize: Bool {
        canEdit && !pagesFailed
    }

    var recognizeHelp: LocalizedStringResource {
        pagesFailed
            ? "macOS 无法读取这个 PDF 的页面，不能识别目录页；可以粘贴或导入目录再写入"
            : "识别目录页…（⌘R）"
    }

    // MARK: - Row actions
    //
    // Each action first ends a title/page edit in the table (buttons under the table and the
    // disclosure triangles do not take the keyboard focus), so the typed text is committed to
    // its own row before rows move. Menu commands never get here while a field is being edited
    // (`TextInputGuard`).

    func addSibling() {
        commitEditing()
        guard canEdit else { return }
        model.addSibling(after: focusID)
    }

    func addChild() {
        commitEditing()
        guard canEdit else { return }
        guard let id = focusID else { return addSibling() }
        model.addChild(of: id)
    }

    func delete(keepChildren: Bool) {
        commitEditing()
        let ids = targetIDs
        guard canEdit, !ids.isEmpty else { return }
        model.delete(ids, keepChildren: keepChildren)
    }

    func indent() {
        commitEditing()
        guard canEdit else { return }
        model.indent(targetIDs)
    }

    func outdent() {
        commitEditing()
        guard canEdit else { return }
        model.outdent(targetIDs)
    }

    func moveUp() {
        commitEditing()
        guard canEdit else { return }
        model.moveUp(targetIDs)
    }

    func moveDown() {
        commitEditing()
        guard canEdit else { return }
        model.moveDown(targetIDs)
    }

    func shiftPages(by delta: Int) {
        commitEditing()
        guard canEdit else { return }
        model.shiftPages(targetIDs, by: delta)
    }

    func pinToPreviewPage() {
        commitEditing()
        guard canEdit, let id = focusID else { return }
        model.pinToPreviewPage(id)
    }

    var canCalibrate: Bool {
        guard let id = focusID else { return false }
        return model.canCalibrate(using: id)
    }

    func calibrateOffset() {
        commitEditing()
        guard canEdit, let id = focusID, model.canCalibrate(using: id) else { return }
        model.calibrateOffset(using: id, physicalPage: model.previewPage)
    }

    var canCalibrateFromHere: Bool {
        guard let id = focusID else { return false }
        return model.canCalibrateFrom(id)
    }

    /// The offset changes from this row on: this row and every later one move to match the
    /// preview page (GUI_SPEC §5.6).
    func calibrateFromHere() {
        commitEditing()
        guard canEdit, let id = focusID else { return }
        if !model.calibrateFrom(id, physicalPage: model.previewPage) { NSSound.beep() }
    }

    func selectToEnd() {
        commitEditing()
        model.selectToEnd()
        focusTable()
    }

    func clearOverride() {
        commitEditing()
        guard canEdit else { return }
        model.clearOverride(targetIDs)
    }

    /// Marks the targets as checked, or unchecks them when all of them already are.
    func toggleConfirmed() {
        commitEditing()
        let ids = targetIDs
        guard canEdit, !ids.isEmpty else { return }
        let allConfirmed = ids.allSatisfy { model.row($0)?.confirmed == true }
        model.setConfirmed(ids, !allConfirmed)
    }

    var targetsAllConfirmed: Bool {
        let ids = targetIDs
        return !ids.isEmpty && ids.allSatisfy { model.row($0)?.confirmed == true }
    }

    func editTitle() {
        commitEditing()
        guard canEdit, let id = focusID else { return }
        model.requestEdit(id, field: .title)
    }

    /// Selects the next row with one of these statuses (status bar, "Next Doubtful Entry").
    func selectNext(_ statuses: Set<RowStatus>) {
        commitEditing()
        if model.selectNextRow(withStatus: statuses) {
            focusTable()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Review, preview, TOC pages

    func toggleReview() {
        commitEditing()
        if model.review == nil {
            model.startReview(onlyDoubtful: model.counts.doubtful + model.counts.errors > 0)
            focusTable()
        } else {
            model.endReview()
        }
    }

    /// "Confirm and next" of the review; an error row cannot be confirmed (beep).
    func reviewConfirm() {
        commitEditing()
        guard canEdit else { return }
        if !model.reviewConfirmAndAdvance() { NSSound.beep() }
        focusTable()
    }

    func reviewMove(_ delta: Int) {
        commitEditing()
        model.reviewMove(delta)
        focusTable()
    }

    func continueReviewWithUnseen() {
        commitEditing()
        model.continueReviewWithUnseen()
        focusTable()
    }

    func stepPreview(by delta: Int) {
        let target = min(max(1, model.previewPage + delta), max(1, model.pageCount))
        model.requestPreview(page: target)
    }

    var previewPageIsTOC: Bool {
        model.tocPages.contains(model.previewPage)
    }

    func togglePreviewPageAsTOC() {
        model.toggleTOCPage(model.previewPage)
    }

    // MARK: - Sheets and flows

    func showRecognize() {
        commitEditing()
        guard canRecognize else {
            NSSound.beep()
            return
        }
        sheet = .recognize
    }

    func showPaste() {
        commitEditing()
        sheet = .paste
    }

    func beginWrite() {
        Task { await WriteFlow.run(self) }
    }

    func beginImport() {
        Task { await ImportExportFlow.chooseAndImport(self) }
    }

    func importFile(_ url: URL) {
        Task { await ImportExportFlow.importFile(url, format: nil, session: self) }
    }

    func beginExport(_ format: TOCFormat) {
        Task { await ImportExportFlow.export(format, session: self) }
    }

    /// Ends an in-progress title/page edit in the table so its text is committed first.
    func commitEditing() {
        guard let window, window.firstResponder is NSText else { return }
        if let tableView, tableView.window === window {
            window.makeFirstResponder(tableView)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    func focusTable() {
        guard let tableView, let window = tableView.window else { return }
        window.makeFirstResponder(tableView)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
