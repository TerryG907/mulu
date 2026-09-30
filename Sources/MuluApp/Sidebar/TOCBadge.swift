import SwiftUI

/// Marks a thumbnail as a table-of-contents page.
struct TOCBadge: View {
    var body: some View {
        Text("目录")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: .capsule)
            .padding(4)
            .accessibilityHidden(true)
    }
}
