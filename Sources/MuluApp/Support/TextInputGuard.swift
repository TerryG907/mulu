import AppKit

/// Menu shortcuts fire before a text field sees the key, so ⌘⌫ or ⌥← would edit rows while the
/// user is typing a title. Commands check this first and, when a field editor is active, forward
/// the key's usual text action instead (or do nothing).
@MainActor
enum TextInputGuard {
    static var isEditingText: Bool {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder is NSText
    }

    /// Returns true when a text field is being edited; performs `textAction` on it if given.
    static func interceptForText(_ textAction: Selector? = nil) -> Bool {
        guard isEditingText else { return false }
        if let textAction {
            NSApp.sendAction(textAction, to: nil, from: nil)
        }
        return true
    }
}
