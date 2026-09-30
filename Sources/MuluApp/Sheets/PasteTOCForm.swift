import AppKit
import MuluAppModel
import SwiftUI

/// Input for "Paste TOC Text…" (= `mulu toc parse`): text copied from a bookshop page or an
/// e-book becomes a draft through the same pipeline as OCR, minus the OCR step.
///
/// The clipboard is not read when the sheet opens (macOS may ask the user to allow programmatic
/// pasteboard access): the text box has the focus, so ⌘V pastes.
struct PasteTOCForm: View {
    let session: DocumentSession
    @State private var text = ""
    @State private var firstPage: Int?
    @State private var detectOffset = true
    @State private var errorText: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按 ⌘V 粘贴。每行一条，末尾是印刷页码。缩进和「第X章」这类编号会用来推断层级。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 260)
                .focused($editorFocused)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.quaternary)
                }
                .accessibilityLabel("目录文字")
        }
        Form {
            IntegerField(title: "印刷第 1 页在 PDF 第几页", value: $firstPage, prompt: Text("可空"))
            Toggle("自动找偏移", isOn: $detectOffset)
                .disabled(firstPage != nil)
            if let errorText {
                Text(verbatim: errorText)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.columns)
        .onAppear { editorFocused = true }

        HStack {
            Spacer()
            Button("取消", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("解析", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func start() {
        if let firstPage, firstPage < 1 {
            errorText = String(localized: "印刷第 1 页所在的 PDF 页至少是 1。")
            return
        }
        let knownOffset = firstPage.map { $0 - 1 }
        let request = RecognitionRequest(
            input: .text(text),
            knownOffset: knownOffset,
            detectOffset: knownOffset == nil && detectOffset)
        do {
            try session.model.startRecognition(request)
            errorText = nil
        } catch {
            errorText = Wording.recognitionError(error)
        }
    }

    private func close() {
        session.model.discardRecognition()
        session.sheet = nil
    }
}
