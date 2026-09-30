import MuluAppModel
import SwiftUI

/// Tells the user how the previous run ended (failed or cancelled) above the input form.
struct RecognitionOutcomeNote: View {
    let state: RecognitionState

    var body: some View {
        switch state {
        case .failed(let detail):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("识别失败")
                        .bold()
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .cancelled:
            Label("已取消识别，草稿没有改动。", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
