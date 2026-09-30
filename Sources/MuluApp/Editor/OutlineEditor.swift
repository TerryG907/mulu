import MuluAppModel
import SwiftUI

/// Right column (GUI_SPEC §6.4): offset bar, banner, advisories, the outline table with the
/// review bar and the row buttons under it, and the status bar. Before there is a draft only the
/// empty state is shown (an offset means nothing yet).
struct OutlineEditor: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        let hasRows = !model.draft.rows.isEmpty
        VStack(spacing: 0) {
            if hasRows {
                OffsetBar(session: session)
                Divider()
            }
            if let banner = model.banner {
                BannerView(banner: banner, session: session)
                Divider()
            }
            if !model.advisories.isEmpty {
                AdvisoryList(advisories: model.advisories, onDismiss: model.dismissAdvisory)
                Divider()
            }
            if hasRows {
                OutlineTable(
                    session: session,
                    revision: model.revision,
                    selection: model.selection,
                    focusedRowID: model.focusedRowID,
                    editRequest: model.editRequest,
                    reviewCurrent: model.review?.current,
                    isEnabled: !model.isWriting)
                if let review = model.review {
                    Divider()
                    ReviewHUD(review: review, session: session)
                }
                Divider()
                EditorButtonBar(session: session)
                Divider()
                StatusBar(session: session)
            } else {
                EmptyOutlineView(session: session)
            }
        }
        .disabled(model.isWriting)
    }
}
