import MuluAppModel
import SwiftUI

/// Picks what a window shows: the drop zone, a loading state, the failure view or the editor.
struct WindowContent: View {
    let context: WindowContext

    var body: some View {
        if let session = context.session {
            switch session.model.phase {
            case .loading:
                LoadingView(fileName: session.model.url.lastPathComponent)
            case .ready:
                DocumentWorkspace(session: session, context: context)
            case .failed(let failure):
                FailedView(failure: failure, fileName: session.model.url.lastPathComponent, context: context)
            }
        } else {
            EmptyStateView(context: context)
        }
    }
}
