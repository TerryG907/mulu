import MuluAppModel
import SwiftUI

/// Review bar between the table and the row buttons (GUI_SPEC §5.8): it never covers the row
/// being reviewed. Keys are handled by the table: ↓/↑ move, Return marks checked and advances,
/// Esc leaves review.
struct ReviewHUD: View {
    let review: ReviewSession
    let session: DocumentSession

    var body: some View {
        let model = session.model
        VStack(alignment: .leading, spacing: 8) {
            if review.finished {
                finished(model)
            } else {
                HStack(spacing: 10) {
                    Text("审阅 \(min(review.position + 1, review.queue.count))/\(review.queue.count)")
                        .bold()
                        .monospacedDigit()
                    ReviewScopeToggle(review: review, model: model)
                    Spacer()
                    Button("上一条", systemImage: "chevron.up", action: previous)
                        .labelStyle(.iconOnly)
                        .help("上一条（↑）")
                    Button("下一条", systemImage: "chevron.down", action: next)
                        .labelStyle(.iconOnly)
                        .help("下一条（↓）")
                    Button("确认并下一条", action: session.reviewConfirm)
                        .buttonStyle(.borderedProminent)
                        .help("标为已核对并前往下一条（↩）")
                        .disabled(currentIsError(model))
                    Button("退出审阅", action: model.endReview)
                        .help("退出审阅（Esc）")
                }
                if let id = review.current, let row = model.displayRows.first(where: { $0.id == id }) {
                    ReviewReasons(row: row)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// The end of a pass. After "only doubtful" the rows that were not flagged are not checked:
    /// OCR typos are not always flagged, so offer to look at them instead of declaring victory.
    @ViewBuilder
    private func finished(_ model: DocumentModel) -> some View {
        let unseen = model.reviewUnseenCount
        if review.onlyDoubtful && unseen > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("可疑的 \(review.queue.count) 条都看完了。还有 \(unseen) 条没看过（错字不一定被标成可疑）。")
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("接着看其余 \(unseen) 条", action: session.continueReviewWithUnseen)
                        .buttonStyle(.borderedProminent)
                    Button("写入目录…", action: session.beginWrite)
                        .disabled(!session.canWrite)
                    Spacer()
                    Button("退出审阅", action: model.endReview)
                }
            }
        } else {
            HStack {
                Text("全部看完了：已核对 \(model.counts.confirmed) 条")
                    .bold()
                Spacer()
                Button("写入目录…", action: session.beginWrite)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canWrite)
                Button("退出审阅", action: model.endReview)
            }
        }
    }

    private func currentIsError(_ model: DocumentModel) -> Bool {
        guard let id = review.current else { return false }
        return model.displayRows.first { $0.id == id }?.status == .error
    }

    private func previous() {
        session.reviewMove(-1)
    }

    private func next() {
        session.reviewMove(1)
    }
}
