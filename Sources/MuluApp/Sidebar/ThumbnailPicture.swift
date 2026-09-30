import MuluAppModel
import SwiftUI

/// The rendered page, or a grey placeholder with the page's proportions until it is ready.
struct ThumbnailPicture: View {
    let image: ThumbnailImage?
    let aspect: Double

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .background(.white)
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
        .frame(maxWidth: 120)
        .accessibilityHidden(true)
    }
}
