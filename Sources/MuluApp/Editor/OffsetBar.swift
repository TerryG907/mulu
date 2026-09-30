import MuluAppModel
import MuluCore
import SwiftUI

/// Global page offset (and front-matter offset for roman pages) with a line saying where the
/// offset came from (GUI_SPEC §5.6). Each committed change is one undo step in the model. The
/// field is disabled when no row follows it (every page fixed, as in a PDF's own outline).
struct OffsetBar: View {
    let session: DocumentSession
    @State private var offset: Int? = 0
    @State private var romanOffset: Int?

    private static let limit = TOCParser.maxPage

    var body: some View {
        let model = session.model
        let followsOffset = model.draft.rows.contains { $0.printedPage != nil && $0.manualPage == nil }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                LabeledContent("页码偏移") {
                    HStack(spacing: 4) {
                        IntegerField(title: "页码偏移", value: $offset, allowsEmpty: false)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 64)
                        Stepper("页码偏移", value: stepperBinding, in: -Self.limit...Self.limit)
                            .labelsHidden()
                    }
                }
                .disabled(!followsOffset)
                if hasRomanPages {
                    LabeledContent("前言偏移") {
                        IntegerField(title: "前言偏移", value: $romanOffset, prompt: Text("未设置"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 64)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("PDF 页 = 印刷页 + 偏移")
                if needsOffsetHint(model, followsOffset: followsOffset) {
                    Text(verbatim: "·")
                    Text("偏移还没设：点一行，把预览翻到这一章真正的第一页，按 ⌘⇧L")
                        .foregroundStyle(.orange)
                } else if let caption = Wording.offsetCaption(model.offsetInfo) {
                    Text(verbatim: "·")
                    Text(caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .disabled(!session.canEdit)
        .onChange(of: model.draft.mapping.offset, initial: true) { _, value in
            offset = value
        }
        .onChange(of: model.draft.mapping.romanOffset, initial: true) { _, value in
            romanOffset = value
        }
        .onChange(of: offset) { _, value in
            commitOffset(value)
        }
        .onChange(of: romanOffset) { _, value in
            commitRomanOffset(value)
        }
    }

    private var stepperBinding: Binding<Int> {
        Binding(get: { offset ?? 0 }, set: { offset = $0 })
    }

    /// Rows with printed pages whose offset nobody has set or detected (a pdfdir import: its
    /// pages are printed pages, copied from a bookshop page).
    private func needsOffsetHint(_ model: DocumentModel, followsOffset: Bool) -> Bool {
        followsOffset && model.offsetInfo == nil && model.draft.mapping.offset == 0
    }

    private var hasRomanPages: Bool {
        session.model.draft.mapping.romanOffset != nil
            || session.model.draft.rows.contains { $0.printedPage?.style == .roman }
    }

    private func commitOffset(_ value: Int?) {
        let model = session.model
        guard let value else {
            offset = model.draft.mapping.offset
            return
        }
        guard value != model.draft.mapping.offset else { return }
        if abs(value) > Self.limit || !model.setOffset(value) {
            NSSound.beep()
            offset = model.draft.mapping.offset
        }
    }

    private func commitRomanOffset(_ value: Int?) {
        let model = session.model
        guard value != model.draft.mapping.romanOffset else { return }
        if let value, abs(value) > Self.limit {
            NSSound.beep()
            romanOffset = model.draft.mapping.romanOffset
            return
        }
        if !model.setRomanOffset(value) {
            romanOffset = model.draft.mapping.romanOffset
        }
    }
}
