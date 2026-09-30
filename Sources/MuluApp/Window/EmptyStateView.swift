import SwiftUI

/// The window before a PDF is chosen: a whole-window drop zone (GUI_SPEC §6.5).
struct EmptyStateView: View {
    let context: WindowContext

    var body: some View {
        ContentUnavailableView {
            Label("把 PDF 拖到这里", systemImage: "doc.badge.plus")
        } description: {
            Text("或按 ⌘O 打开。Mulu 只在文件末尾追加目录，原来的字节一个都不改。")
        } actions: {
            Button("打开 PDF…", action: context.chooseAndOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: context.isDropTargeted ? 3 : 1.5, dash: [8, 6]))
                .foregroundStyle(context.isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .padding(24)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Mulu")
    }
}
