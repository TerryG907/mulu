import MuluAppModel
import SwiftUI

/// Middle column (GUI_SPEC §6.3): a bar with the page, the focused row and the correction
/// buttons, then the PDF. The bar sits above the page, not over it: the running head and the
/// chapter title the student is checking are at the top of the page.
struct PreviewPane: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        VStack(spacing: 0) {
            PreviewBar(session: session)
                .background(.bar)
            Divider()
            Group {
                if let document = session.pdfDocument {
                    PDFPreview(
                        document: document,
                        request: model.previewRequest,
                        keepsFocusOutOfPreview: model.review != nil,
                        returnFocus: session.focusTable
                    ) { page in
                        model.previewDidShow(page: page)
                    }
                    .accessibilityLabel("PDF 预览")
                } else if session.previewFailed {
                    PreviewUnavailableView(pagesFailed: session.pagesFailed)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// PDFKit could not open a file that Mulu's own parser reads (for example a damaged
/// cross-reference table): say so instead of spinning forever.
struct PreviewUnavailableView: View {
    let pagesFailed: Bool

    var body: some View {
        ContentUnavailableView {
            Label("预览不可用", systemImage: "eye.slash")
        } description: {
            VStack(spacing: 6) {
                Text("macOS 无法显示这个 PDF（可能已损坏）。仍然可以粘贴或导入目录，然后写入。")
                if pagesFailed {
                    Text("也不能识别目录页：识别要靠 macOS 读出页面图像。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
