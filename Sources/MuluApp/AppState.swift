import AppKit
import MuluAppModel
import Observation

/// App-wide registry of document windows (GUI_SPEC §6.8): which window shows which file, how many
/// windows hold a document, and the smoke-mode configuration.
@MainActor @Observable
final class AppState {
    static let shared = AppState()

    /// Used by the cold-launch rule: spare empty windows close themselves within this window of time.
    let launchedAt = Date.now
    static let spareWindowGracePeriod: TimeInterval = 3

    var smoke: SmokeConfig?
    /// Set once a smoke run has started driving a document.
    private(set) var smokeStarted = false
    @ObservationIgnored private var smokeFileClaimed = false

    private var contexts: [UUID: WindowContext] = [:]
    /// Registration order, so external files go to the oldest spare window first.
    @ObservationIgnored private var registrationOrder: [UUID] = []
    /// Files from Finder that arrived before any window could take them.
    @ObservationIgnored private var pendingExternalURLs: [URL] = []

    var documentWindowCount: Int {
        contexts.values.count { $0.session != nil }
    }

    /// Open windows without a document (a closed window that SwiftUI keeps around does not count).
    var emptyWindowCount: Int {
        contexts.values.count { $0.session == nil && !$0.isClosed }
    }

    var dirtyDocumentCount: Int {
        contexts.values.count { $0.session?.model.isDirty == true }
    }

    var writingDocumentCount: Int {
        contexts.values.count { $0.session?.model.isWriting == true }
    }

    var isWithinLaunchGracePeriod: Bool {
        Date.now.timeIntervalSince(launchedAt) < Self.spareWindowGracePeriod
    }

    func register(_ context: WindowContext) {
        contexts[context.token] = context
        if !registrationOrder.contains(context.token) {
            registrationOrder.append(context.token)
        }
    }

    func unregister(_ context: WindowContext) {
        contexts[context.token] = nil
        registrationOrder.removeAll { $0 == context.token }
    }

    /// The window that already shows (or is about to show) `url`, compared after resolving symlinks.
    func context(showing url: URL) -> WindowContext? {
        let key = FileSniffer.identity(of: url)
        return contexts.values.first { context in
            guard let shown = context.session?.model.url ?? context.claimedURL else { return false }
            return FileSniffer.identity(of: shown) == key
        }
    }

    // MARK: External open events

    /// Files opened from Finder or the Dock. With `WindowGroup(for: URL.self)` AppKit hands them to
    /// the app delegate rather than to `.onOpenURL` (unlike a plain WindowGroup, spec F7), so the
    /// delegate forwards them here and a window routes them with the usual rules (GUI_SPEC §6.8).
    func receiveExternal(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let target = routingTarget() {
            target.routeExternal(files)
        } else {
            pendingExternalURLs.append(contentsOf: files)
        }
    }

    /// Hands queued external files to the first window that can route them.
    func takePendingExternalURLs() -> [URL] {
        defer { pendingExternalURLs.removeAll() }
        return pendingExternalURLs
    }

    /// An untouched empty window takes the file over; otherwise the key window opens a new one.
    /// With every window closed, a closed window's router still opens a new window for the file.
    private func routingTarget() -> WindowContext? {
        let routers = registrationOrder.compactMap { contexts[$0] }.filter { $0.router != nil }
        let open = routers.filter { !$0.isClosed }
        return open.first { $0.session == nil && $0.claimedURL == nil && !$0.userInteracted }
            ?? open.first { $0.window?.isKeyWindow == true }
            ?? open.first
            ?? routers.first
    }

    /// Smoke mode with `MULU_SMOKE=<path>`: the first window to appear takes this file.
    func claimSmokeFile() -> URL? {
        guard !smokeFileClaimed, case .file(let url)? = smoke?.target else { return nil }
        smokeFileClaimed = true
        return url
    }

    /// Whether the document just opened at `url` is the one the smoke run should drive.
    func shouldDriveSmoke(for url: URL) -> Bool {
        guard let smoke, !smokeStarted else { return false }
        switch smoke.target {
        case .file(let target):
            guard FileSniffer.identity(of: target) == FileSniffer.identity(of: url) else { return false }
        case .openEvent:
            break
        }
        smokeStarted = true
        return true
    }
}
