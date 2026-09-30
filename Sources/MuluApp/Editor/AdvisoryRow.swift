import MuluAppModel
import SwiftUI

/// One advisory: Chinese headline, what to do about it, the expandable English detail, and an
/// optional dismiss button.
struct AdvisoryRow: View {
    let advisory: Advisory
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: advisory.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(advisory.severity == .warning ? Color.orange : Color.secondary)
                .accessibilityLabel(advisory.severity == .warning ? Text("警告") : Text("提示"))
            VStack(alignment: .leading, spacing: 2) {
                Text(Wording.advisoryTitle(advisory))
                if let hint = Wording.advisoryHint(advisory.kind) {
                    Text(hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let detail = Wording.advisoryDetail(advisory)
                if !detail.isEmpty {
                    DisclosureGroup("详情") {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button("关闭提示", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
    }
}
