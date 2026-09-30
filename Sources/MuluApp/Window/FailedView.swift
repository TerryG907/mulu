import MuluAppModel
import SwiftUI

/// The file could not be opened (GUI_SPEC §6.6): a Chinese headline plus the English detail.
struct FailedView: View {
    let failure: OpenFailure
    let fileName: String
    let context: WindowContext

    var body: some View {
        ContentUnavailableView {
            Label(Wording.openFailureTitle(failure), systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(Wording.openFailureAdvice(failure))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: failure.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 440)
        } actions: {
            HStack {
                Button("关闭窗口", action: context.closeWindow)
                Button("打开其他文件…", action: context.chooseAndOpen)
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle(fileName)
    }
}
