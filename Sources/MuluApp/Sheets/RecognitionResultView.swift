import MuluAppModel
import SwiftUI

/// Summary of a finished recognition and the merge choices (GUI_SPEC §5.3 steps 7–8).
///
/// Return never throws away a draft for (almost) nothing: with no rows the accept buttons are
/// disabled and Return goes back to the form; with fewer than three rows and an existing draft,
/// Return appends instead of replacing.
struct RecognitionResultView: View {
    let result: RecognitionResult
    let session: DocumentSession
    let kind: SessionSheet

    private static let fewRows = 3

    var body: some View {
        let model = session.model
        let empty = result.rows.isEmpty
        let few = result.rows.count < Self.fewRows
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("识别出 \(result.rows.count) 条，其中 \(result.doubtfulCount) 条可疑")
                    .font(.headline)
                Text(Wording.resultOffsetLine(result))
                    .foregroundStyle(.secondary)
                if empty {
                    Label(emptyMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if result.autoWouldAccept {
                    Label("把握较高：可以直接写入（仍建议抽查几条）", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    Label("把握不够：请先核对可疑条目再写入（⌘⇧R 审阅）", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !result.advisories.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.advisories) { advisory in
                            AdvisoryRow(advisory: advisory)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("放弃", role: .cancel, action: discard)
                    .keyboardShortcut(.cancelAction)
                if empty {
                    Spacer()
                    Button(retryTitle, action: retry)
                        .keyboardShortcut(.defaultAction)
                } else if model.draft.rows.isEmpty {
                    Spacer()
                    Button("使用结果", action: replace)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(retryTitle, action: retry)
                    Spacer()
                    Button(Wording.mergeMode(.insertAfterFocused), action: insert)
                        .disabled(model.focusedRowID == nil)
                    if few {
                        Button(Wording.mergeMode(.append), action: append)
                            .keyboardShortcut(.defaultAction)
                        Button(Wording.mergeMode(.replace), action: replace)
                    } else {
                        Button(Wording.mergeMode(.append), action: append)
                        Button(Wording.mergeMode(.replace), action: replace)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private var emptyMessage: LocalizedStringKey {
        kind == .recognize ? "没有读出目录条目。请检查目录页页码，再试一次。" : "没有读出目录条目。请检查粘贴的文字，再试一次。"
    }

    private var retryTitle: LocalizedStringKey {
        kind == .recognize ? "改页码再试" : "返回修改"
    }

    private func accept(_ mode: MergeMode) {
        session.model.acceptRecognition(mode)
        session.sheet = nil
        session.focusTable()
    }

    private func replace() { accept(.replace) }
    private func append() { accept(.append) }
    private func insert() { accept(.insertAfterFocused) }

    /// Back to the input form, the sheet stays open.
    private func retry() {
        session.model.discardRecognition()
    }

    private func discard() {
        session.model.discardRecognition()
        session.sheet = nil
    }
}
