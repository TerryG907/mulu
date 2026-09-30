import MuluAppModel
import SwiftUI

/// Items of the "Outline" menu (GUI_SPEC §6.7). Row commands do nothing while a text field is
/// being edited, so their shortcuts cannot change rows behind the user's typing.
struct OutlineMenuItems: View {
    /// The key window's context, not its session: menu items live as long as the menu bar, and
    /// must not keep a closed window's document alive.
    let context: WindowContext?

    private var session: DocumentSession? {
        guard let session = context?.session, session.model.phase == .ready else { return nil }
        return session
    }

    private var model: DocumentModel? { session?.model }
    private var targets: Set<UUID> { session?.targetIDs ?? [] }
    private var hasRows: Bool { model?.draft.rows.isEmpty == false }
    private var canEdit: Bool { session?.canEdit == true }

    private var tocPageTitle: LocalizedStringKey {
        session?.previewPageIsTOC == true ? "取消目录页（当前预览页）" : "标为目录页（当前预览页）"
    }

    private var reviewTitle: LocalizedStringKey {
        model?.review == nil ? "审阅模式" : "退出审阅模式"
    }

    private var confirmTitle: LocalizedStringKey {
        session?.targetsAllConfirmed == true ? "取消核对" : "标为已核对"
    }

    var body: some View {
        Button("识别目录页…") { session?.showRecognize() }
            .keyboardShortcut("r")
            .disabled(session?.canRecognize != true)
        Button(tocPageTitle) { session?.togglePreviewPageAsTOC() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(session == nil)
        Button(reviewTitle) { perform { $0.toggleReview() } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasRows)
        Button("下一条可疑") { perform { $0.selectNext([.doubtful, .error]) } }
            .keyboardShortcut("'")
            .disabled(!hasRows || (model?.counts.doubtful ?? 0) + (model?.counts.errors ?? 0) == 0)

        Divider()

        Button("增加缩进") { perform { $0.indent() } }
            .keyboardShortcut("]")
            .disabled(!canEdit || model?.canIndent(targets) != true)
        Button("减少缩进") { perform { $0.outdent() } }
            .keyboardShortcut("[")
            .disabled(!canEdit || model?.canOutdent(targets) != true)
        Button("上移") { perform { $0.moveUp() } }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!canEdit || model?.canMoveUp(targets) != true)
        Button("下移") { perform { $0.moveDown() } }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!canEdit || model?.canMoveDown(targets) != true)

        Divider()

        Button("编辑标题") { perform { $0.editTitle() } }
            .keyboardShortcut("e")
            .disabled(!canEdit || session?.focusID == nil)
        Button("添加同级条目") { perform { $0.addSibling() } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canEdit)
        Button("添加子条目") { perform { $0.addChild() } }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!canEdit || session?.focusID == nil)
        Button("删除") { perform(textAction: #selector(NSResponder.deleteToBeginningOfLine(_:))) { $0.delete(keepChildren: false) } }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!canEdit || targets.isEmpty)
        Button("删除但保留子项") { perform { $0.delete(keepChildren: true) } }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(!canEdit || targets.isEmpty)

        Divider()

        Button("页码 +1") { perform { $0.shiftPages(by: 1) } }
            .keyboardShortcut("]", modifiers: [.command, .control])
            .disabled(!canEdit || targets.isEmpty)
        Button("页码 −1") { perform { $0.shiftPages(by: -1) } }
            .keyboardShortcut("[", modifiers: [.command, .control])
            .disabled(!canEdit || targets.isEmpty)
        Button("设为当前预览页") { perform { $0.pinToPreviewPage() } }
            .keyboardShortcut("l")
            .disabled(!canEdit || session?.focusID == nil)
        Button("按当前预览页校准偏移") { perform { $0.calibrateOffset() } }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!canEdit || session?.canCalibrate != true)
        Button("从这一行起按当前预览页校准") { perform { $0.calibrateFromHere() } }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!canEdit || session?.canCalibrateFromHere != true)
        Button("选中本行到末尾") { perform { $0.selectToEnd() } }
            .disabled(!hasRows || session?.focusID == nil)
        Button("清除手动页码") { perform { $0.clearOverride() } }
            .disabled(!canEdit || targets.isEmpty)
        Button(confirmTitle) { perform { $0.toggleConfirmed() } }
            .keyboardShortcut("k")
            .disabled(!canEdit || targets.isEmpty)

        Divider()

        Button("全部展开") { model?.expandAll() }
            .disabled(!hasRows)
        Button("全部折叠") { model?.collapseAll() }
            .disabled(!hasRows)
    }

    /// Runs a row command unless a text field is being edited (then the key goes to the text).
    private func perform(textAction: Selector? = nil, _ action: (DocumentSession) -> Void) {
        guard let session, !TextInputGuard.interceptForText(textAction) else { return }
        action(session)
    }
}
