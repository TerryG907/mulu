import Foundation

/// A one-off message shown as an alert in a window.
struct WindowNotice: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var message: String
}
