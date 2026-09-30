import MuluAppModel
import SwiftUI

/// The bar above the preview (GUI_SPEC §5.5): which page is shown and whether it is a TOC page,
/// where the focused row points, and the corrections that use the page on screen.
struct PreviewBar: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("PDF 第 \(model.previewPage) 页 / 共 \(model.pageCount) 页")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Toggle("这是目录页", isOn: tocPageBinding)
                    .toggleStyle(.checkbox)
                    .help("把正在预览的这一页标为目录页（⌘⇧T）；识别目录页时会读这些页")
                    .disabled(model.pageCount == 0)
            }
            if let id = session.focusID, let row = model.row(id) {
                let page = model.physicalPage(of: id)
                FocusedRowSummary(row: row, page: page, mapping: model.draft.mapping)
                CorrectionButtons(session: session, rowPage: page)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tocPageBinding: Binding<Bool> {
        Binding(
            get: { session.previewPageIsTOC },
            set: { _ in session.togglePreviewPageAsTOC() })
    }
}

/// "Use this page", "Calibrate the offset", "Calibrate from this row on". Disabled while the
/// preview already shows the row's page. Wraps under each other when the column is narrow.
struct CorrectionButtons: View {
    let session: DocumentSession
    let rowPage: Int?

    var body: some View {
        let differs = rowPage != session.model.previewPage
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(differs) }
            VStack(alignment: .leading, spacing: 4) { buttons(differs) }
        }
        .controlSize(.small)
        .disabled(!session.canEdit)
    }

    @ViewBuilder
    private func buttons(_ differs: Bool) -> some View {
        Button("设为本行页码", action: session.pinToPreviewPage)
            .help("把本行固定到正在预览的这一页（⌘L）")
            .disabled(!differs)
        Button("按这一页校准偏移", action: session.calibrateOffset)
            .help("改全书的页码偏移，让本行落在这一页（⌘⇧L）")
            .disabled(!differs || !session.canCalibrate)
        Button("从这一行起按这一页校准", action: session.calibrateFromHere)
            .help("只移动本行和它后面的条目，前面的不动；适合书中间偏移变了的情况（⌥⌘L）")
            .disabled(!differs || !session.canCalibrateFromHere)
    }
}
