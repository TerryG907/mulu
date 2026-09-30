import MuluAppModel
import SwiftUI

/// Why the current review row is flagged: the Chinese reasons, the English notes under 详情.
struct ReviewReasons: View {
    let row: DisplayRow

    var body: some View {
        let lines = Wording.reasonLines(row)
        let details = Wording.reasonDetails(row)
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty {
                Text("这一条没有发现问题。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: row.status == .error ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .foregroundStyle(row.status == .error ? Color.red : Color.primary)
                }
            }
            if row.status == .error {
                Text("这一条有错：先改好再核对（⌘E 改标题，双击页码改页码）。")
                    .foregroundStyle(.red)
            }
            if !details.isEmpty {
                DisclosureGroup("详情") {
                    Text(verbatim: details.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}
