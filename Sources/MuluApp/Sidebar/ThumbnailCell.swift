import AppKit
import MuluAppModel
import SwiftUI

/// A page thumbnail, rendered in the background by `ThumbnailRenderer`.
struct ThumbnailCell: View {
    let session: DocumentSession
    let page: Int
    let isCurrent: Bool
    let isTOC: Bool
    @State private var image: ThumbnailImage?

    private var tocActionTitle: LocalizedStringKey {
        isTOC ? "取消目录页" : "标为目录页"
    }

    var body: some View {
        Button(action: activate) {
            VStack(spacing: 4) {
                ThumbnailPicture(image: image, aspect: session.pageAspect(page))
                    .overlay(alignment: .topTrailing) {
                        if isTOC {
                            TOCBadge()
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
                    }
                Text(verbatim: String(page))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tocActionTitle, action: toggleTOC)
            Button("只识别这一页…", action: recognizeThisPage)
                .disabled(!session.canRecognize)
        }
        .help("点击预览这一页；按住 ⌘ 点击标为目录页（或取消）")
        .accessibilityLabel(Text("第 \(page) 页"))
        .accessibilityValue(isTOC ? Text("目录页") : Text(verbatim: ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: Text(tocActionTitle), toggleTOC)
        .task(id: session.thumbnails != nil) {
            // Re-runs once the renderer exists: cells can appear before `prepareViews()`. A cell
            // that scrolls away cancels its task, and the renderer skips cancelled requests.
            await loadThumbnail()
        }
        .onDisappear {
            // The renderer's cache keeps recent pages; the cell does not hold its own copy.
            image = nil
        }
    }

    private func activate() {
        if NSEvent.modifierFlags.contains(.command) {
            toggleTOC()
        } else {
            session.model.requestPreview(page: page)
        }
    }

    private func toggleTOC() {
        session.model.toggleTOCPage(page)
    }

    /// Recognizes exactly this page (the marked TOC pages become just this one).
    private func recognizeThisPage() {
        session.model.setTOCPages([page])
        session.showRecognize()
    }

    private func loadThumbnail() async {
        guard image == nil, let renderer = session.thumbnails else { return }
        guard let rendered = try? await renderer.thumbnail(page: page, maxPixelWidth: 240),
              !Task.isCancelled else { return }
        image = rendered
    }
}
