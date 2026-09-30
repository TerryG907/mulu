import SwiftUI

/// Mulu's macOS app: one window per PDF (GUI_SPEC §6).
///
/// Every window is a `WindowGroup(for: URL.self)` instance so `openWindow(value:)` can open a file
/// in a new window and bring an already-open one to the front.
///
/// Finder/Dock opens (verified on macOS 26 with this scene type, see GUI_SPEC §12): the URLs reach
/// `AppDelegate.application(_:open:)`, not `.onOpenURL`, and a scene that claims external events
/// (`matching: ["*"]`) gets an extra window that SwiftUI tears down again once another window
/// takes the file. So the scene claims none (`matching: []`) and `AppState.receiveExternal(_:)`
/// routes the files: cold launch → exactly one window; running → a new window, or the existing
/// window for a file that is already open. `.onOpenURL` stays as a harmless second path.
@main
struct MuluMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup(id: DocumentWindow.sceneID, for: URL.self) { $url in
            DocumentWindow(url: $url)
                .environment(appState)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1400, height: 880)
        .commands {
            SidebarCommands()
            MuluCommands()
        }
    }
}
