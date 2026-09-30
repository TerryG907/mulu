import MuluAppModel
import SwiftUI

/// Phase text, determinate progress bar and Cancel (Esc / ⌘.) while recognition runs.
struct RecognitionProgressView: View {
    let progress: RecognitionProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: min(max(progress.fraction, 0), 1)) {
                Text(Wording.progress(progress))
            }
            Text("每页识别大约需要 1–3 秒。取消会在当前这一页读完后生效。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onExitCommand(perform: onCancel)
    }
}
