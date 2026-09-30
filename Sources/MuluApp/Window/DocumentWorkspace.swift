import MuluAppModel
import SwiftUI

/// The three-column editor (GUI_SPEC §6.1): thumbnails | PDF preview | outline editor.
struct DocumentWorkspace: View {
    @Bindable var session: DocumentSession
    let context: WindowContext

    var body: some View {
        NavigationSplitView {
            ThumbnailSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 140, ideal: 170, max: 240)
        } content: {
            PreviewPane(session: session)
                .navigationSplitViewColumnWidth(min: 360, ideal: 640)
        } detail: {
            OutlineEditor(session: session)
                .frame(minWidth: 380, idealWidth: 480)
        }
        .frame(minWidth: 1100, minHeight: 680)
        .toolbar {
            WorkspaceToolbar(session: session)
        }
        .navigationTitle(session.model.url.lastPathComponent)
        .navigationSubtitle(Text("共 \(session.model.pageCount) 页"))
        .navigationDocument(session.model.url)
        .sheet(item: $session.sheet) { kind in
            RecognitionSheet(session: session, kind: kind)
        }
        .task {
            session.window = context.window
            await session.prepareViews()
        }
        .onChange(of: session.model.isDirty, initial: true) { _, dirty in
            context.window?.isDocumentEdited = dirty
        }
    }
}
