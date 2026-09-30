import MuluAppModel
import MuluOCR
import SwiftUI

/// Input for OCR recognition: TOC page range and, optionally, which PDF page the book's printed
/// page 1 is (= `auto --offset`, offset = that page − 1).
struct RecognizeForm: View {
    let session: DocumentSession
    @State private var pagesSpec = ""
    @State private var firstPage: Int?
    @State private var errorText: String?

    var body: some View {
        Form {
            TextField("目录页", text: $pagesSpec, prompt: Text("例如 5-7 或 3,5,8-9"))
            Text("PDF 的物理页，也就是缩略图下面的数字。最多 \(maxTOCPageCount) 页。中文标点（，、～ 至）也可以。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            IntegerField(title: "印刷第 1 页在 PDF 第几页", value: $firstPage, prompt: Text("可空：自动检测"))
            Text("书上印着「1」的那一页，是 PDF 的第几页？不知道就留空。PDF 页 = 印刷页 + 偏移。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(verbatim: errorText)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.columns)
        .onAppear(perform: prefill)

        HStack {
            Spacer()
            Button("取消", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("开始识别", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(PageNumberInput.normalizeRange(pagesSpec).isEmpty)
        }
    }

    private func prefill() {
        pagesSpec = session.model.tocPagesSpec
    }

    private func start() {
        let model = session.model
        // Pinyin input gives "3，5，8－9" or "5～7": normalize, and show what was understood.
        let spec = PageNumberInput.normalizeRange(pagesSpec)
        pagesSpec = spec
        if let firstPage, firstPage < 1 {
            errorText = String(localized: "印刷第 1 页所在的 PDF 页至少是 1。")
            return
        }
        do {
            try model.setTOCPages(spec: spec)
            try model.startRecognition(pages: nil, knownOffset: firstPage.map { $0 - 1 })
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
