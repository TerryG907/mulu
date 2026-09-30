import AppKit

/// Asks before closing a window whose outline changes were never written (GUI_SPEC §6.9, P1),
/// and frees the window's document when it closes.
///
/// SwiftUI owns the window's delegate, so this object sits in front of it: it answers
/// `windowShouldClose(_:)` itself and forwards every other delegate message to SwiftUI's original
/// delegate. If SwiftUI later replaces the delegate, the guard silently drops out and only the
/// edited dot and the quit confirmation remain.
///
/// Why closing is done in two steps: SwiftUI keeps the scene of a closed window alive (hidden,
/// with its `@State`), does not call `onDisappear`, and does not update the views of a window
/// that is off screen (measured on macOS 26 with `scripts/smoke_app.sh` stage E). Dropping the
/// document only after the window has closed would leave the editor views, the PDFView and
/// through them the whole document in memory. So the document is dropped while the window is
/// still on screen (made transparent first, so the empty state never flashes), SwiftUI dismantles
/// the editor, and then the window closes.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private weak var context: WindowContext?
    private var isReleasing = false

    init(context: WindowContext) {
        self.context = context
    }

    func install(on window: NSWindow) {
        guard !(window.delegate is WindowCloseGuard) else { return }
        original = window.delegate
        window.delegate = self
        // Notifications, not delegate methods: those must keep reaching SwiftUI's delegate.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowShown(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowShown(_:)), name: NSWindow.didBecomeMainNotification, object: window)
    }

    /// Also reached when the window is closed without asking (`close()`): the document is
    /// dropped at the latest here.
    @objc private func windowClosed(_ notification: Notification) {
        context?.windowDidClose()
    }

    @objc private func windowShown(_ notification: Notification) {
        guard !isReleasing else { return }
        context?.windowDidShow()
    }

    // MARK: Forwarding

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let originalAnswer = original?.windowShouldClose?(sender) ?? true
        guard originalAnswer else { return false }
        if isReleasing { return false }
        guard let context, let session = context.session else { return true }
        // No questions in smoke mode.
        guard AppState.shared.smoke == nil else {
            releaseThenClose(sender)
            return false
        }
        // A write takes a moment; its result banner (or error) belongs to this window.
        if session.model.isWriting {
            NSSound.beep()
            return false
        }
        guard session.model.isDirty else {
            releaseThenClose(sender)
            return false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(session.model.url.lastPathComponent)”的目录修改还没有写入 PDF。仍然关闭？")
        alert.informativeText = String(localized: "Mulu 只把目录写进新的 PDF；没有写入的修改会丢失。")
        // Return keeps the window (取消 is the default); closing takes a click.
        alert.addButton(withTitle: String(localized: "取消"))
        let close = alert.addButton(withTitle: String(localized: "仍然关闭"))
        close.hasDestructiveAction = true
        close.keyEquivalent = ""
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            MainActor.assumeIsolated {
                guard response == .alertSecondButtonReturn, let self, let sender else { return }
                self.releaseThenClose(sender)
            }
        }
        return false
    }

    /// Drops the document while the window is still on screen, waits (at most half a second)
    /// until SwiftUI has dismantled the editor and the session is gone, then closes the window.
    private func releaseThenClose(_ window: NSWindow) {
        guard !isReleasing else { return }
        isReleasing = true
        let session = context?.session
        let alpha = window.alphaValue
        window.alphaValue = 0
        context?.windowDidClose()
        Task { @MainActor [weak self, weak window, weak session] in
            for _ in 0..<25 where session != nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            self?.isReleasing = false
            guard let window else { return }
            window.close()
            window.alphaValue = alpha
        }
    }
}
