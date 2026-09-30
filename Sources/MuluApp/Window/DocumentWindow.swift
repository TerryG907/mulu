import MuluAppModel
import SwiftUI

/// Root of every window. Owns the routing rules of GUI_SPEC §6.8:
/// - a URL for a file that another window already shows brings that window forward;
/// - an empty (or failed) window takes the URL over; otherwise a new window opens for it;
/// - on cold launch, spare empty windows that nobody touched close themselves (F8).
struct DocumentWindow: View {
    static let sceneID = "document"

    @Binding var url: URL?
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var context = WindowContext()

    var body: some View {
        WindowContent(context: context)
            .background {
                WindowAccessor(onWindow: attach)
            }
            .dropDestination(for: URL.self, action: handleDrop) { targeted in
                context.isDropTargeted = targeted
            }
            .onOpenURL { incoming in
                route([incoming])
            }
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .onChange(of: url, initial: true) { _, newURL in
                openDocument(at: newURL)
            }
            .onChange(of: appState.documentWindowCount, initial: true) {
                closeIfSpare()
            }
            .focusedSceneValue(\.windowContext, context)
            .alert(context.notice?.title ?? "", isPresented: $context.showsNotice, presenting: context.notice) { _ in
            } message: { notice in
                Text(notice.message)
            }
    }

    private func appear() {
        appState.register(context)
        context.windowDidShow()
        context.router = Self.makeRouter(url: $url, context: context, appState: appState, openWindow: openWindow)
        let binding = $url
        context.forgetURL = { binding.wrappedValue = nil }
        if url == nil, let smokeFile = appState.claimSmokeFile() {
            context.claimedURL = smokeFile.standardizedFileURL
            url = smokeFile.standardizedFileURL
        }
        let pending = appState.takePendingExternalURLs()
        if !pending.isEmpty {
            route(pending)
        }
    }

    /// The view is going away (SwiftUI tears down the scene of a closed window that is not the
    /// last one). `appear()` registers the context and installs the router again should SwiftUI
    /// show the view once more. The document itself is freed when the window closes
    /// (`WindowContext.windowDidClose()`), whether or not this is ever called.
    private func disappear() {
        appState.unregister(context)
        context.router = nil
        context.forgetURL = nil
    }

    private func attach(_ window: NSWindow) {
        context.window = window
        context.session?.window = window
        if context.closeGuard == nil {
            let guardian = WindowCloseGuard(context: context)
            guardian.install(on: window)
            context.closeGuard = guardian
        }
        closeIfSpare()
    }

    private func handleDrop(_ urls: [URL], at location: CGPoint) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        context.open(files)
        return true
    }

    /// Creates the session for `url` and loads it (the smoke runner loads it itself). Loading runs
    /// in its own task: a view task would be cancelled when SwiftUI re-evaluates this window.
    private func openDocument(at url: URL?) {
        guard let url else {
            if let previous = context.session {
                previous.model.cancelRecognition()
                undoManager?.removeAllActions(withTarget: previous.model)
            }
            context.session = nil
            context.claimedURL = nil
            return
        }
        let target = url.standardizedFileURL
        context.claimedURL = target
        appState.register(context)
        context.windowDidShow()
        if let current = context.session, current.model.url == target { return }
        if let previous = context.session {
            previous.model.cancelRecognition()
            undoManager?.removeAllActions(withTarget: previous.model)
        }
        // Every undo step stores a copy of the draft rows: keep the history bounded.
        undoManager?.levelsOfUndo = 200

        let session = DocumentSession(url: target, undoManager: undoManager)
        session.window = context.window
        context.session = session

        if appState.shouldDriveSmoke(for: target), let config = appState.smoke {
            Task { await SmokeDriver.run(config, session: session, appState: appState) }
        } else {
            Task { await session.model.load() }
        }
    }

    private func route(_ urls: [URL]) {
        Self.route(urls, url: $url, context: context, appState: appState, openWindow: openWindow)
    }

    /// The router stored in the context. It must not capture this view (`self`): the view holds
    /// the context in `@State`, and the context holds the router, so capturing `self` would keep
    /// every closed window's document, PDF and thumbnails alive.
    private static func makeRouter(url: Binding<URL?>, context: WindowContext, appState: AppState,
                                   openWindow: OpenWindowAction) -> ([URL]) -> Void {
        { [weak context] urls in
            guard let context else { return }
            route(urls, url: url, context: context, appState: appState, openWindow: openWindow)
        }
    }

    /// Routes incoming file URLs (Finder, drop, ⌘O).
    private static func route(_ urls: [URL], url: Binding<URL?>, context: WindowContext, appState: AppState,
                              openWindow: OpenWindowAction) {
        var tookOver = false
        for incoming in urls {
            let target = incoming.standardizedFileURL
            guard FileSniffer.isPDF(target) else {
                if let session = context.session, session.model.phase == .ready, FileSniffer.isOutlineFile(target) {
                    session.importFile(target)
                } else {
                    context.present(WindowNotice(
                        title: String(localized: "这不是 PDF 文件"),
                        message: String(localized: "Mulu 只能打开 PDF。“\(target.lastPathComponent)”不是 PDF。")))
                }
                continue
            }
            if let other = appState.context(showing: target) {
                other.window?.makeKeyAndOrderFront(nil)
                continue
            }
            // A closed (hidden) window never takes a file over: a new window is opened for it.
            let canTakeOver = !tookOver && !context.isClosed
                && (url.wrappedValue == nil || context.session?.isFailed == true)
            if canTakeOver {
                tookOver = true
                context.claimedURL = target
                url.wrappedValue = target
            } else {
                openWindow(id: sceneID, value: target)
            }
        }
    }

    /// Cold launch with a file creates an extra empty window (F8); it closes itself once another
    /// window holds a document, unless the user has already used it.
    private func closeIfSpare() {
        guard url == nil, context.session == nil, !context.userInteracted,
              appState.isWithinLaunchGracePeriod,
              appState.documentWindowCount > 0,
              let window = context.window else { return }
        window.close()
    }
}
