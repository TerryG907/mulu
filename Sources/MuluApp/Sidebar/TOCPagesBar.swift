import MuluAppModel
import SwiftUI

/// Footer of the thumbnail column: the chosen TOC pages and the recognize button.
struct TOCPagesBar: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        VStack(alignment: .leading, spacing: 6) {
            if model.tocPages.isEmpty {
                Text("在预览上方勾选「这是目录页」，或按住 ⌘ 点选缩略图")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("目录页：\(model.tocPagesSpec)")
                    .font(.callout)
                    .lineLimit(2)
            }
            Button("识别目录页…", action: session.showRecognize)
                .help(Text(session.recognizeHelp))
                .disabled(!session.canRecognize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
