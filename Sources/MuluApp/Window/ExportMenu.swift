import MuluAppModel
import MuluCore
import SwiftUI

/// "Export Outline" with one item per interchange format (GUI_SPEC §5.9).
struct ExportMenu: View {
    let session: DocumentSession

    var body: some View {
        Menu("导出目录", systemImage: "square.and.arrow.up") {
            ForEach(TOCFormat.allCases, id: \.self) { format in
                Button(Wording.formatName(format)) {
                    session.beginExport(format)
                }
            }
        }
        .help("导出目录（⌘⇧E 用上次的格式）")
        .disabled(!session.canWrite)
    }
}
