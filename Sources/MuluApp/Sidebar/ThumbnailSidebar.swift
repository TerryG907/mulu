import MuluAppModel
import SwiftUI

/// One thumbnail per page (GUI_SPEC §6.2). Click previews a page; ⌘-click marks it as a TOC page.
struct ThumbnailSidebar: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<model.pageCount, id: \.self) { index in
                            ThumbnailCell(
                                session: session,
                                page: index + 1,
                                isCurrent: model.previewPage == index + 1,
                                isTOC: model.tocPages.contains(index + 1))
                            .id(index + 1)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 10)
                }
                .onChange(of: model.previewPage) { _, page in
                    proxy.scrollTo(page)
                }
            }
            Divider()
            TOCPagesBar(session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面缩略图")
    }
}
