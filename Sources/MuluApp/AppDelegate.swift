import AppKit
import MuluAppModel

/// App-level hooks SwiftUI does not cover (GUI_SPEC §6.9). With `WindowGroup(for: URL.self)`,
/// Finder/Dock file-open events arrive here, not at `.onOpenURL` (F11, GUI_SPEC §12.1), and are
/// routed by `AppState.receiveExternal(_:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Run straight from .build, the process starts with the .prohibited policy: no Dock icon,
        // no menu bar, cannot become active (F2). A bundled launch is already .regular.
        if !isBundled {
            NSApp.setActivationPolicy(.regular)
        }
        // One PDF per window. Automatic tabbing would add View ▸ Show Tab Bar (⇧⌘T, which comes
        // before the Outline menu and would take its "Mark as TOC Page" shortcut) and
        // Window ▸ Merge All Windows.
        NSWindow.allowsAutomaticWindowTabbing = false
        AppState.shared.smoke = SmokeConfig(environment: ProcessInfo.processInfo.environment)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let config = AppState.shared.smoke {
            // Smoke runs stay in the background: no activation, no stolen focus.
            SmokeWatchdog.start(config, appState: AppState.shared)
        } else if !isBundled {
            NSApp.activate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let appState = AppState.shared
        guard appState.smoke == nil else { return .terminateNow }

        // A write in progress would leave a hidden temporary file (or nothing) behind.
        if appState.writingDocumentCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "正在写入目录，请等写完再退出。")
            alert.informativeText = String(localized: "写入通常只要几秒钟。")
            alert.addButton(withTitle: String(localized: "好"))
            alert.runModal()
            return .terminateCancel
        }

        let dirty = appState.dirtyDocumentCount
        guard dirty > 0 else { return .terminateNow }
        // Return keeps the work (取消 is the default); quitting takes a click.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "有 \(dirty) 个窗口的目录修改还没有写入 PDF。仍然退出？")
        alert.informativeText = String(localized: "Mulu 只把目录写进新的 PDF；没有写入的修改会丢失。")
        alert.addButton(withTitle: String(localized: "取消"))
        let quit = alert.addButton(withTitle: String(localized: "仍然退出"))
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Finder/Dock opens. See `AppState.receiveExternal(_:)` for why they arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.receiveExternal(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
