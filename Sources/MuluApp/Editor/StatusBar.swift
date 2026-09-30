import MuluAppModel
import SwiftUI

/// Counts under the table plus the review toggle (GUI_SPEC §6.4). The doubtful and error counts
/// are buttons: each click selects the next such row.
struct StatusBar: View {
    let session: DocumentSession

    private var reviewTitle: LocalizedStringKey {
        session.model.review == nil ? "审阅" : "结束审阅"
    }

    var body: some View {
        let model = session.model
        let counts = model.counts
        HStack(spacing: 6) {
            if model.isWriting {
                ProgressView()
                    .controlSize(.small)
                Text("正在写入…")
            } else {
                Text("\(counts.rows) 条")
                Text(verbatim: "·")
                Button {
                    session.selectNext([.doubtful])
                } label: {
                    Text("\(counts.doubtful) 条可疑")
                        .foregroundStyle(counts.doubtful > 0 ? Color.orange : Color.secondary)
                }
                .help("选中下一条可疑的条目（⌘'）")
                .disabled(counts.doubtful == 0)
                Text(verbatim: "·")
                Button {
                    session.selectNext([.error])
                } label: {
                    Text("\(counts.errors) 条有错")
                        .foregroundStyle(counts.errors > 0 ? Color.red : Color.secondary)
                }
                .help("选中下一条有错的条目")
                .disabled(counts.errors == 0)
                Text(verbatim: "·")
                Text("已核对 \(counts.confirmed)")
            }
            Spacer()
            Button(reviewTitle, action: session.toggleReview)
                .disabled(counts.rows == 0)
        }
        .buttonStyle(.borderless)
        .monospacedDigit()
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
