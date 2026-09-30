import AppKit

/// Presents `NSAlert`s as window sheets (or app-modal without a window) and awaits the answer.
@MainActor
enum Alerts {
    static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    static func make(_ message: String, detail: String, style: NSAlert.Style = .warning, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        return alert
    }

    /// Error alert with a Chinese explanation followed by the engine's English text.
    static func showError(_ message: String, explanation: String, detail: String, in window: NSWindow?) async {
        let body = detail.isEmpty || detail == explanation ? explanation : explanation + "\n\n" + detail
        let alert = make(message, detail: body, buttons: [String(localized: "好")])
        _ = await run(alert, in: window)
    }
}
