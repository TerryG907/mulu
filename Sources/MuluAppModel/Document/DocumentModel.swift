import Foundation
import MuluCore
import MuluOCR

/// One open PDF and its outline draft (one per window). All state lives on the main actor;
/// heavy work (parsing, recognition, writing) runs in detached tasks that only see Sendable
/// values (GUI_SPEC §4, §6.10).
@MainActor @Observable
public final class DocumentModel: Identifiable {
    public nonisolated let id: UUID
    public nonisolated let url: URL
    /// A model built with `init(previewRows:pageCount:mapping:)`: no file behind it.
    let isPreview: Bool
    let previewPageCount: Int

    // MARK: loading

    public internal(set) var phase: DocumentPhase
    public internal(set) var summary: PDFSummary?
    public var pageCount: Int { summary?.pageCount ?? previewPageCount }

    // MARK: draft and derived state

    public internal(set) var draft: OutlineDraft
    public internal(set) var displayRows: [DisplayRow] = []
    public internal(set) var counts = DraftCounts()
    public internal(set) var revision = 0
    public internal(set) var isDirty = false
    public internal(set) var offsetInfo: OffsetInfo?
    public internal(set) var advisories: [Advisory] = []
    public internal(set) var banner: Banner?
    @ObservationIgnored public var undoManager: UndoManager

    // MARK: selection, preview, editing requests

    public internal(set) var selection: Set<UUID> = []
    public internal(set) var focusedRowID: UUID?
    public internal(set) var previewRequest: PreviewRequest?
    /// 1-based.
    public internal(set) var previewPage: Int = 1
    public internal(set) var editRequest: EditRequest?
    /// Rows whose children are hidden (view state: not undoable, not a modification).
    var collapsed: Set<UUID> = []

    // MARK: TOC pages, recognition, review, write

    /// sorted, unique
    public internal(set) var tocPages: [Int] = []
    public internal(set) var recognition: RecognitionState = .idle
    public internal(set) var review: ReviewSession?
    public internal(set) var isWriting = false
    public internal(set) var lastWrite: WriteReport?

    // MARK: internals

    @ObservationIgnored var derived = DerivedState()
    /// Output projection of the last loaded or written draft (GUI_SPEC §4.8).
    @ObservationIgnored var baseline: [OutlineDraft.ProjectionItem] = []
    @ObservationIgnored var serial = 0
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    @ObservationIgnored var recognitionCancel: (@Sendable () -> Void)?
    @ObservationIgnored var recognitionSerial = 0
    /// Every progress value the model received during the current recognition (tests, debugging).
    @ObservationIgnored var recognitionProgressLog: [RecognitionProgress] = []
    /// Background work to cancel when the window (and so the model) goes away.
    let workers = WorkerBag()

    public init(url: URL, undoManager: UndoManager? = nil) {
        id = UUID()
        self.url = url.standardizedFileURL
        isPreview = false
        previewPageCount = 0
        phase = .loading
        draft = OutlineDraft()
        self.undoManager = undoManager ?? DocumentModel.makeUndoManager()
        refresh()
    }

    /// UI development without a file: phase .ready, writing blocked with .notReady.
    public init(previewRows: [OutlineRow], pageCount: Int, mapping: PageMapping = PageMapping()) {
        id = UUID()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview.pdf")
        isPreview = true
        previewPageCount = max(0, pageCount)
        phase = .ready
        draft = OutlineDraft(rows: OutlineDraft.clampedLevels(previewRows), mapping: mapping)
        undoManager = DocumentModel.makeUndoManager()
        refresh()
        baseline = draft.projection()
        isDirty = false
    }

    deinit {
        workers.cancelAll()
    }

    static func makeUndoManager() -> UndoManager {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }

    func nextSerial() -> Int {
        serial += 1
        return serial
    }

    // MARK: - Loading

    /// Reads and parses the file off the main actor, then shows its existing outline (if any)
    /// as the draft. Not undoable. Concurrent callers all wait for the one load.
    public func load() async {
        if isPreview { return }
        if let t = loadTask {
            await t.value
            return
        }
        let t = Task { await self.performLoad() }
        loadTask = t
        await t.value
    }

    private func performLoad() async {
        phase = .loading
        let url = self.url
        let outcome = await Task.detached(priority: .userInitiated) { DocumentLoader.load(url) }.value
        switch outcome {
        case .failure(let f):
            phase = .failed(f)
        case .success(let s):
            summary = s
            if !s.existingOutline.isEmpty {
                draft = OutlineDraft(rows: DocumentLoader.rows(fromOutline: s.existingOutline))
                offsetInfo = OffsetInfo(source: .existingOutline)
                banner = .loadedExisting(count: s.existingOutline.count)
            }
            phase = .ready
            refresh()
            baseline = draft.projection()
            isDirty = false
        }
    }

    // MARK: - Derived state

    public func row(_ id: UUID) -> OutlineRow? {
        derived.indexByID[id].map { draft.rows[$0] }
    }

    /// `derived` is not observed; reading `revision` makes a view that calls only this accessor
    /// update when the draft changes.
    public func physicalPage(of id: UUID) -> Int? {
        _ = revision
        return derived.indexByID[id].flatMap { derived.physical[$0] }
    }

    func index(of id: UUID) -> Int? {
        _ = revision
        return derived.indexByID[id]
    }

    public func dismissAdvisory(_ id: UUID) {
        advisories.removeAll { $0.id == id }
    }

    public func dismissBanner() {
        banner = nil
    }

    /// Recomputes everything derived from the draft. With `focusPageBefore`, a focused row
    /// whose physical page changed sends the preview there (GUI_SPEC §5.5).
    func refresh(focusPageBefore: Int?? = .none) {
        derived = DerivedState(draft: draft, pageCount: pageCount, collapsed: collapsed)
        displayRows = derived.displayRows
        counts = derived.counts
        isDirty = draft.projection() != baseline
        let known = derived.indexByID
        if selection.contains(where: { known[$0] == nil }) { selection = selection.filter { known[$0] != nil } }
        if let f = focusedRowID, known[f] == nil { focusedRowID = nil }
        if !collapsed.isEmpty, collapsed.contains(where: { known[$0] == nil }) { collapsed = collapsed.filter { known[$0] != nil } }
        normalizeReview()
        revision += 1
        if case .some(let before) = focusPageBefore, let f = focusedRowID, let now = physicalPage(of: f), now != before {
            issuePreview(now)
        }
    }

    // MARK: - Undo

    /// The advisories and banner that describe the rows a recognition or an import brought in.
    /// Only those steps carry them, so undoing such a step takes its notes away (and redo brings
    /// them back) while ordinary edits leave whatever the user kept or dismissed alone.
    struct Annotations: Sendable {
        var advisories: [Advisory]
        var banner: Banner?
    }

    struct Snapshot: Sendable {
        var draft: OutlineDraft
        var selection: Set<UUID>
        var focus: UUID?
        var offsetInfo: OffsetInfo?
        var annotations: Annotations?
    }

    func snapshot(withAnnotations: Bool = false) -> Snapshot {
        Snapshot(draft: draft, selection: selection, focus: focusedRowID, offsetInfo: offsetInfo,
                 annotations: withAnnotations ? Annotations(advisories: advisories, banner: banner) : nil)
    }

    /// Stores a changed draft as exactly one undo step. Returns false (and registers nothing)
    /// when neither the draft nor the offset info changed. `annotated`: the step also replaces
    /// the advisories and banner (set by the caller right after), which undo restores.
    @discardableResult
    func commit(_ newDraft: OutlineDraft, action: String, selection newSelection: Set<UUID>? = nil,
                focus newFocus: UUID?? = .none, offsetInfo newInfo: OffsetInfo?? = .none, annotated: Bool = false) -> Bool {
        let infoChanged: Bool
        if case .some(let info) = newInfo { infoChanged = info != offsetInfo } else { infoChanged = false }
        guard newDraft != draft || infoChanged else { return false }
        assert(OutlineDraft.levelsAreValid(newDraft.rows), "outline level invariant broken")
        let before = snapshot(withAnnotations: annotated)
        let focusPage = focusedRowID.flatMap { physicalPage(of: $0) }
        draft = newDraft
        if let newSelection { selection = newSelection }
        if case .some(let f) = newFocus { focusedRowID = f }
        if case .some(let info) = newInfo { offsetInfo = info }
        registerUndo(restoring: before, actionName: action)
        refresh(focusPageBefore: .some(focusPage))
        return true
    }

    /// Applies `change` to a copy of the draft and commits it when it reports a change.
    @discardableResult
    func edit(_ action: String, _ change: (inout OutlineDraft) -> Bool) -> Bool {
        var d = draft
        guard change(&d) else { return false }
        return commit(d, action: action)
    }

    private func registerUndo(restoring old: Snapshot, actionName: String) {
        let um = undoManager
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(old, actionName: actionName) }
        }
        um.setActionName(actionName)
        um.endUndoGrouping()
    }

    /// Undo/redo: puts a snapshot back and registers the opposite step.
    private func restore(_ s: Snapshot, actionName: String) {
        let current = snapshot(withAnnotations: s.annotations != nil)
        let focusPage = focusedRowID.flatMap { physicalPage(of: $0) }
        draft = s.draft
        selection = s.selection
        focusedRowID = s.focus
        offsetInfo = s.offsetInfo
        if let a = s.annotations {
            advisories = a.advisories
            banner = a.banner
        }
        registerUndo(restoring: current, actionName: actionName)
        refresh(focusPageBefore: .some(focusPage))
    }

    // MARK: - Selection, preview, editing requests

    public func select(_ ids: Set<UUID>, focus: UUID?) {
        let known = derived.indexByID
        selection = ids.filter { known[$0] != nil }
        focusedRowID = focus.flatMap { known[$0] != nil ? $0 : nil }
        if let f = focusedRowID, let p = physicalPage(of: f) { issuePreview(p) }
    }

    public func requestPreview(page: Int) {
        issuePreview(page)
    }

    public func previewDidShow(page: Int) {
        guard page >= 1 else { return }
        previewPage = page
    }

    public func requestEdit(_ id: UUID, field: EditRequest.Field) {
        guard index(of: id) != nil else { return }
        editRequest = EditRequest(rowID: id, field: field, serial: nextSerial())
    }

    func issuePreview(_ page: Int) {
        var p = max(1, page)
        if pageCount > 0 { p = min(p, pageCount) }
        previewPage = p
        previewRequest = PreviewRequest(page: p, serial: nextSerial())
    }

    // MARK: - Expansion (not undoable)

    public func isExpanded(_ id: UUID) -> Bool { !collapsed.contains(id) }

    public func toggleExpanded(_ id: UUID) {
        setExpanded(id, !isExpanded(id))
    }

    public func setExpanded(_ id: UUID, _ expanded: Bool) {
        guard index(of: id) != nil, isExpanded(id) != expanded else { return }
        if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
        refresh()
    }

    public func expandAll() {
        guard !collapsed.isEmpty else { return }
        collapsed = []
        refresh()
    }

    public func collapseAll() {
        let rows = draft.rows
        let parents = Set(rows.indices.filter { $0 + 1 < rows.count && rows[$0 + 1].level > rows[$0].level }.map { rows[$0].id })
        guard parents != collapsed else { return }
        collapsed = parents
        refresh()
    }

    /// Expands every ancestor of the row so it is visible.
    func reveal(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let hidden = DraftOps.ancestorIndices(draft.rows, i).map { draft.rows[$0].id }.filter { collapsed.contains($0) }
        guard !hidden.isEmpty else { return }
        collapsed.subtract(hidden)
        refresh()
    }
}

/// Cancel handles of background work, reachable from the (nonisolated) deinit.
final class WorkerBag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancels: [UUID: @Sendable () -> Void] = [:]

    func add(_ id: UUID, _ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        cancels[id] = cancel
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        cancels[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(cancels.values)
        cancels = [:]
        lock.unlock()
        for c in all { c() }
    }
}

/// Opening a PDF off the main actor (GUI_SPEC §4.1): the bytes are read, parsed and dropped.
enum DocumentLoader {
    static func load(_ url: URL) -> Result<PDFSummary, OpenFailure> {
        let fingerprint: FileFingerprint
        let bytes: [UInt8]
        do {
            fingerprint = try FileFingerprint.of(url)
            bytes = try FileIdentity.readBytes(url)
        } catch {
            return .failure(.unreadable("\(url.path): \(error.localizedDescription)"))
        }
        do {
            let doc = try PDFFile(bytes: bytes)
            if doc.isEncrypted { return .failure(.encrypted) }
            let pages = try doc.pageRefs().count
            guard pages > 0 else { return .failure(.noPages) }
            let outline = (try? doc.readOutline()) ?? []
            var fp = fingerprint
            if fp.size != bytes.count { fp.size = bytes.count }  // changed while reading: writing will refuse
            return .success(PDFSummary(pageCount: pages, fileSize: bytes.count, info: doc.info(), existingOutline: outline, fingerprint: fp))
        } catch let e as MuluError {
            switch e {
            case .notPDF: return .failure(.notPDF(e.description))
            case .encrypted: return .failure(.encrypted)
            case .zeroPages: return .failure(.noPages)
            default: return .failure(.unreadable(e.description))
            }
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    /// The PDF's own outline as fixed-page rows (GUI_SPEC §5.2): an item whose destination
    /// cannot be resolved borrows the previous item's page (the first one gets none).
    static func rows(fromOutline items: [OutlineItemInfo]) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        rows.reserveCapacity(items.count)
        var lastPage: Int? = nil
        for it in items {
            var row = OutlineRow(title: MuluTOCFormat.oneLine(it.title), level: it.level)
            if let pi = it.pageIndex {
                row.manualPage = pi + 1
                lastPage = pi + 1
            } else {
                row.manualPage = lastPage
                let detail = lastPage.map { "the destination cannot be resolved to a page; using the previous item's page \($0)" }
                    ?? "the destination cannot be resolved to a page"
                row.doubts = [DoubtReason(kind: .unresolvedDestination, detail: detail)]
            }
            rows.append(row)
        }
        return OutlineDraft.clampedLevels(rows)
    }
}
