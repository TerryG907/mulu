import SwiftUI

/// Row buttons under the table (GUI_SPEC §6.4); the same actions as the Outline menu.
struct EditorButtonBar: View {
    let session: DocumentSession

    var body: some View {
        let model = session.model
        let targets = session.targetIDs
        HStack(spacing: 12) {
            Button("添加同级条目", systemImage: "plus", action: session.addSibling)
                .help("添加同级条目（⌘↩）")
            Button("添加子条目", systemImage: "arrow.turn.down.right", action: session.addChild)
                .help("添加子条目（⌘⇧↩）")
                .disabled(session.focusID == nil)
            Button("删除", systemImage: "minus", action: deleteRows)
                .help("删除（⌫）")
                .disabled(targets.isEmpty)
            Divider()
                .frame(height: 16)
            Button("减少缩进", systemImage: "decrease.indent", action: session.outdent)
                .help("减少缩进（⇧Tab）")
                .disabled(!model.canOutdent(targets))
            Button("增加缩进", systemImage: "increase.indent", action: session.indent)
                .help("增加缩进（Tab）")
                .disabled(!model.canIndent(targets))
            Button("上移", systemImage: "arrow.up", action: session.moveUp)
                .help("上移（⌥⌘↑）")
                .disabled(!model.canMoveUp(targets))
            Button("下移", systemImage: "arrow.down", action: session.moveDown)
                .help("下移（⌥⌘↓）")
                .disabled(!model.canMoveDown(targets))
            Divider()
                .frame(height: 16)
            Button(action: pageDown) {
                Text(verbatim: "−1")
                    .monospacedDigit()
                    .accessibilityLabel("页码 −1")
            }
            .help("选中行页码 −1（[）")
            .disabled(targets.isEmpty)
            Button(action: pageUp) {
                Text(verbatim: "+1")
                    .monospacedDigit()
                    .accessibilityLabel("页码 +1")
            }
            .help("选中行页码 +1（]）")
            .disabled(targets.isEmpty)
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func deleteRows() {
        session.delete(keepChildren: false)
    }

    private func pageDown() {
        session.shiftPages(by: -1)
    }

    private func pageUp() {
        session.shiftPages(by: 1)
    }
}
