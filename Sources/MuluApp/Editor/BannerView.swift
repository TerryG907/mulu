import MuluAppModel
import SwiftUI

/// One-line result banner above the table (GUI_SPEC §5.2, §5.3, §5.9, §5.11).
struct BannerView: View {
    let banner: Banner
    let session: DocumentSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            BannerMessage(banner: banner, session: session)
            Spacer(minLength: 0)
            Button("关闭横幅", systemImage: "xmark", action: session.model.dismissBanner)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.1))
    }

    private var symbol: String {
        switch banner {
        case .loadedExisting: "list.bullet.indent"
        case .recognitionApplied: "text.viewfinder"
        case .imported: "square.and.arrow.down"
        case .wrote: "checkmark.seal.fill"
        }
    }
}
