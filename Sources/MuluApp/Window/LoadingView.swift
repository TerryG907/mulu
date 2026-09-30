import SwiftUI

/// Shown while the model parses the file (usually well under a second).
struct LoadingView: View {
    let fileName: String

    var body: some View {
        ProgressView {
            Text("正在读取 \(fileName)…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(fileName)
    }
}
