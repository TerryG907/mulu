import SwiftUI

/// The document is open but the draft is empty (GUI_SPEC §6.5). For a scanned book the way in is
/// two steps: find and mark the TOC pages in the preview, then recognize them. Step ② becomes
/// the prominent button only once pages are marked.
struct EmptyOutlineView: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        let hasTOCPages = !model.tocPages.isEmpty
        ContentUnavailableView {
            Label("这个 PDF 还没有目录", systemImage: "list.bullet.indent")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                if hasTOCPages {
                    Label("已选目录页：\(model.tocPagesSpec)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("① 在预览里翻到印着目录的那几页，逐页勾选上方的「这是目录页」（或按住 ⌘ 点左边的缩略图）。")
                }
                Text("② 点「识别目录页…」，把目录读成可以修改的草稿。")
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 360)
        } actions: {
            VStack(spacing: 10) {
                if hasTOCPages {
                    Button("识别目录页…", action: session.showRecognize)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help(Text(session.recognizeHelp))
                        .disabled(!session.canRecognize)
                } else {
                    Button("识别目录页…", action: session.showRecognize)
                        .controlSize(.large)
                        .help(Text(session.recognizeHelp))
                        .disabled(!session.canRecognize)
                }
                HStack {
                    Button("粘贴目录文字…", action: session.showPaste)
                    Button("导入目录文件…", action: session.beginImport)
                }
                .fixedSize()
                Button("手动添加第一条", action: session.addSibling)
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
