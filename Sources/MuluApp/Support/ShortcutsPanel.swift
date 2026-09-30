import AppKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts: the table of GUI_SPEC §6.7 in a small utility panel. An AppKit
/// panel, not a SwiftUI scene, so it never takes part in window routing or state restoration.
@MainActor
enum ShortcutsPanel {
    private static var panel: NSPanel?

    static func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = String(localized: "键盘快捷键")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ShortcutsView())
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutsView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let action: LocalizedStringKey
        let keys: String
    }

    private struct ShortcutGroup: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let note: LocalizedStringKey?
        let items: [Item]
    }

    private let sections: [ShortcutGroup] = [
        ShortcutGroup(title: "目录表格（表格有焦点、没在改文字时）", note: "⌃Tab / ⌃⇧Tab 把焦点移出表格。", items: [
            Item(action: "编辑标题", keys: "↩  ⌘E"),
            Item(action: "编辑标题时跳到页码 / 回到标题", keys: "Tab  ⇧Tab"),
            Item(action: "增加缩进 / 减少缩进", keys: "Tab  ⇧Tab  ⌘]  ⌘["),
            Item(action: "选中行页码 +1 / −1", keys: "]  [  ⌃⌘]  ⌃⌘["),
            Item(action: "选中行页码 +10 / −10", keys: "}  {"),
            Item(action: "标为已核对（切换）", keys: "Space  ⌘K"),
            Item(action: "删除（连同子项）", keys: "⌫  ⌘⌫"),
            Item(action: "删除但保留子项", keys: "⌥⌘⌫"),
            Item(action: "展开 / 折叠", keys: "→  ←"),
            Item(action: "上移 / 下移", keys: "⌥⌘↑  ⌥⌘↓"),
            Item(action: "添加同级条目 / 添加子条目", keys: "⌘↩  ⌘⇧↩"),
            Item(action: "下一条可疑", keys: "⌘'"),
        ]),
        ShortcutGroup(title: "预览与页码", note: nil, items: [
            Item(action: "预览上一页 / 下一页", keys: "⌥←  ⌥→"),
            Item(action: "设为当前预览页", keys: "⌘L"),
            Item(action: "按当前预览页校准偏移", keys: "⌘⇧L"),
            Item(action: "从这一行起按当前预览页校准", keys: "⌥⌘L"),
            Item(action: "标为目录页（当前预览页）", keys: "⌘⇧T"),
        ]),
        ShortcutGroup(title: "审阅", note: nil, items: [
            Item(action: "审阅模式 开/关", keys: "⌘⇧R"),
            Item(action: "下一条 / 上一条", keys: "↓  ↑"),
            Item(action: "确认并下一条", keys: "↩"),
            Item(action: "退出审阅", keys: "Esc"),
        ]),
        ShortcutGroup(title: "文件", note: nil, items: [
            Item(action: "打开 PDF…", keys: "⌘O"),
            Item(action: "识别目录页…", keys: "⌘R"),
            Item(action: "粘贴目录文字…", keys: "⌘⇧V"),
            Item(action: "导入目录…", keys: "⌘⇧I"),
            Item(action: "导出目录（上次的格式）…", keys: "⌘⇧E"),
            Item(action: "写入目录…", keys: "⌘S"),
            Item(action: "撤销 / 重做", keys: "⌘Z  ⌘⇧Z"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(section.items) { item in
                                GridRow {
                                    Text(item.action)
                                    Text(verbatim: item.keys)
                                        .monospaced()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let note = section.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}
