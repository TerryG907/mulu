import MuluAppModel
import SwiftUI

/// "「Title」→ page 20 (printed 12 + offset 8)" for the preview overlay.
struct FocusedRowSummary: View {
    let row: OutlineRow
    let page: Int?
    let mapping: PageMapping

    var body: some View {
        let shown = Wording.shortTitle(row.title)
        Group {
            if let page {
                if row.pageOverride {
                    Text("「\(shown)」→ 第 \(page) 页（手动固定）")
                } else if let printed = row.printedPage, let offset = totalOffset(for: printed) {
                    Text("「\(shown)」→ 第 \(page) 页（印刷页 \(printed.display) + 偏移 \(Wording.signed(offset))）")
                } else {
                    Text("「\(shown)」→ 第 \(page) 页")
                }
            } else {
                Text("「\(shown)」→ 没有页码")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func totalOffset(for printed: PrintedPageRef) -> Int? {
        let base = printed.style == .arabic ? mapping.offset : mapping.romanOffset
        return base.map { $0 + row.sectionShift }
    }
}
