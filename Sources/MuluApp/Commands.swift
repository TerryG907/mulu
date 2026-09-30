import MuluAppModel
import MuluCore
import SwiftUI

/// Menu bar commands (GUI_SPEC §6.7). They act on the key window's document through
/// `@FocusedValue(\.windowContext)`; table-only keys (Tab, Return, brackets…) live in the table.
struct MuluCommands: Commands {
    @FocusedValue(\.windowContext) private var context
    @Environment(\.openWindow) private var openWindow

    private var session: DocumentSession? {
        guard let session = context?.session, session.model.phase == .ready else { return nil }
        return session
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新窗口", action: newWindow)
                .keyboardShortcut("n")
            Button("打开 PDF…", action: openPDF)
                .keyboardShortcut("o")
        }
        // After (not replacing) .saveItem: that group holds Close ⌘W.
        CommandGroup(after: .saveItem) {
            Divider()
            Button("写入目录…") { session?.beginWrite() }
                .keyboardShortcut("s")
                .disabled(session?.canWrite != true)
            Divider()
            Button("导入目录…") { session?.beginImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session?.canEdit != true)
            Menu("导出目录") {
                ForEach(TOCFormat.allCases, id: \.self) { format in
                    Button(Wording.formatName(format)) { session?.beginExport(format) }
                }
            }
            .disabled(session?.canWrite != true)
            Button("导出目录（上次的格式）…") {
                if let session { session.beginExport(session.lastExportFormat) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session?.canWrite != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("粘贴目录文字…") { session?.showPaste() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(session?.canEdit != true)
        }
        CommandMenu("目录") {
            OutlineMenuItems(context: context)
        }
        CommandGroup(replacing: .help) {
            Button("键盘快捷键") { ShortcutsPanel.show() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("预览上一页") {
                guard !TextInputGuard.interceptForText(#selector(NSResponder.moveWordLeft(_:))) else { return }
                session?.stepPreview(by: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(session == nil)
            Button("预览下一页") {
                guard !TextInputGuard.interceptForText(#selector(NSResponder.moveWordRight(_:))) else { return }
                session?.stepPreview(by: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(session == nil)
        }
    }

    private func newWindow() {
        openWindow(id: DocumentWindow.sceneID)
    }

    /// With a window focused, the chosen files are routed through it (an empty window takes the
    /// first one); with no window, each file opens its own.
    private func openPDF() {
        if let context {
            context.chooseAndOpen()
            return
        }
        Task {
            for url in await OpenPanels.choosePDFs() {
                openWindow(id: DocumentWindow.sceneID, value: url.standardizedFileURL)
            }
        }
    }
}
