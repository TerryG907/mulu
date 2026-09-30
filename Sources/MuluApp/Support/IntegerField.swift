import AppKit
import MuluAppModel
import SwiftUI

/// A text field for a whole number that also accepts what a Chinese input method types
/// (full-width digits and signs). The value is committed on Return and when the field loses the
/// focus; input that is not a number beeps and is put back.
struct IntegerField: View {
    let title: LocalizedStringKey
    @Binding var value: Int?
    var prompt: Text?
    /// Whether an empty field is allowed (value nil).
    var allowsEmpty = true
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: value, initial: true) { _, newValue in
                if !focused { text = Self.format(newValue) }
            }
    }

    private func commit() {
        let trimmed = PageNumberInput.normalize(text)
        if trimmed.isEmpty {
            if allowsEmpty {
                value = nil
            } else {
                NSSound.beep()
            }
        } else if let n = PageNumberInput.integer(trimmed) {
            value = n
        } else {
            NSSound.beep()
        }
        text = Self.format(value)
    }

    private static func format(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}
