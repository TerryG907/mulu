import MuluAppModel
import MuluCore
import SwiftUI

/// Toolbar of a document window (GUI_SPEC §6.1). Offsets live in the editor's offset bar, where
/// there is room for the line explaining where the offset came from.
struct WorkspaceToolbar: ToolbarContent {
    let session: DocumentSession

    private var reviewTitle: LocalizedStringKey {
        session.model.review == nil ? "审阅" : "结束审阅"
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("识别目录页…", systemImage: "text.viewfinder", action: session.showRecognize)
                .labelStyle(.titleAndIcon)
                .help(Text(session.recognizeHelp))
                .disabled(!session.canRecognize)
            Button("粘贴目录文字…", systemImage: "doc.on.clipboard", action: session.showPaste)
                .help("粘贴目录文字…（⌘⇧V）")
                .disabled(!session.canEdit)
            Button(reviewTitle, systemImage: "checklist", action: session.toggleReview)
                .help("审阅模式（⌘⇧R）")
                .disabled(session.model.draft.rows.isEmpty)
            Button("导入目录…", systemImage: "square.and.arrow.down", action: session.beginImport)
                .help("导入目录…（⌘⇧I）")
                .disabled(!session.canEdit)
            ExportMenu(session: session)
            Button("写入目录…", systemImage: "arrow.down.doc", action: session.beginWrite)
                .labelStyle(.titleAndIcon)
                .help("写入目录…（⌘S）")
                .disabled(!session.canWrite)
        }
    }
}
