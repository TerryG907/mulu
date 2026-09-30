import AppKit
import MuluAppModel
import UniformTypeIdentifiers

/// "Write Outline…" (GUI_SPEC §5.11): readiness checks → save panel → `DocumentModel.write(to:)`,
/// which goes through `Mulu.apply` and re-reads the output from disk. Success shows the model's
/// banner; failure shows the Chinese explanation plus the writer's own text.
@MainActor
enum WriteFlow {
    static func run(_ session: DocumentSession) async {
        let model = session.model
        session.commitEditing()
        guard !model.isWriting, session.sheet == nil else { return }

        let readiness = model.writeReadiness()
        if !readiness.blockers.isEmpty {
            await presentBlockers(readiness.blockers, session: session)
            return
        }
        if readiness.unconfirmedDoubtful > 0 || readiness.orderWarnings > 0 {
            switch await confirmDoubtful(readiness, window: session.window) {
            case .write:
                break
            case .review:
                model.startReview(onlyDoubtful: true)
                session.focusTable()
                return
            case .cancel:
                return
            }
        }
        guard let output = await chooseOutput(session) else { return }
        do {
            _ = try await model.write(to: output)
        } catch let error as WriteError {
            await Alerts.showError(
                String(localized: "写入失败，没有生成文件"),
                explanation: Wording.writeError(error),
                detail: error.description,
                in: session.window)
        } catch {
            await Alerts.showError(
                String(localized: "写入失败，没有生成文件"),
                explanation: String(localized: "写文件时出错。"),
                detail: String(describing: error),
                in: session.window)
        }
    }

    // MARK: Blockers

    /// Lists up to five blocking rows; offers to jump to the first one and, when every blocker is
    /// a missing page, to delete those rows while keeping their children.
    static func presentBlockers(_ blockers: [WriteBlocker], session: DocumentSession) async {
        let model = session.model
        var rowIDs: [UUID] = []
        var allMissingPage = true
        for blocker in blockers {
            guard case let .row(id, _, issue) = blocker else {
                allMissingPage = false
                continue
            }
            rowIDs.append(id)
            if issue != .noPhysicalPage { allMissingPage = false }
        }
        let uniqueRows = Array(Set(rowIDs))
        var lines = blockers.prefix(5).map { blocker -> String in
            if case let .row(id, _, _) = blocker {
                return Wording.blocker(blocker, title: model.row(id)?.title)
            }
            return Wording.blocker(blocker, title: nil)
        }
        if blockers.count > 5 {
            lines.append(String(localized: "…还有 \(blockers.count - 5) 处"))
        }

        let message = allMissingPage && !uniqueRows.isEmpty
            ? String(localized: "\(uniqueRows.count) 条没有页码")
            : String(localized: "还不能写入：有 \(blockers.count) 处需要先处理")
        var buttons: [String] = []
        if !uniqueRows.isEmpty { buttons.append(String(localized: "定位到第一条")) }
        if allMissingPage && !uniqueRows.isEmpty { buttons.append(String(localized: "删除这些行（保留子项）")) }
        buttons.append(String(localized: "取消"))

        let alert = Alerts.make(message, detail: lines.joined(separator: "\n"), buttons: buttons)
        let response = await Alerts.run(alert, in: session.window)
        guard !uniqueRows.isEmpty else { return }
        switch response {
        case .alertFirstButtonReturn:
            if let first = rowIDs.first {
                model.select([first], focus: first)
                session.focusTable()
            }
        case .alertSecondButtonReturn where allMissingPage:
            model.delete(Set(uniqueRows), keepChildren: true)
        default:
            break
        }
    }

    // MARK: Doubtful rows

    private enum DoubtChoice { case write, review, cancel }

    /// The safe choice is the default: Return starts the review, Esc cancels, and writing the
    /// unchecked draft takes a deliberate click.
    private static func confirmDoubtful(_ readiness: WriteReadiness, window: NSWindow?) async -> DoubtChoice {
        let doubtful = readiness.unconfirmedDoubtful
        let order = readiness.orderWarnings
        let message = doubtful > 0
            ? String(localized: "还有 \(doubtful) 条可疑没有核对。仍然写入？")
            : String(localized: "\(order) 条页码比上一条小。仍然写入？")
        let detail = doubtful > 0 && order > 0
            ? String(localized: "另有 \(order) 条页码比上一条小。")
            : String(localized: "可以先用审阅模式逐条看一遍（⌘⇧R）。")
        let alert = Alerts.make(message, detail: detail, buttons: [
            String(localized: "先审阅"),
            String(localized: "仍然写入"),
            String(localized: "取消"),
        ])
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch await Alerts.run(alert, in: window) {
        case .alertFirstButtonReturn: return .review
        case .alertSecondButtonReturn: return .write
        default: return .cancel
        }
    }

    // MARK: Save panel

    private static func chooseOutput(_ session: DocumentSession) async -> URL? {
        let model = session.model
        let panel = NSSavePanel()
        panel.title = String(localized: "写入带目录的新 PDF")
        panel.prompt = String(localized: "写入")
        panel.message = String(localized: "原文件不会被改动：新文件 = 原文件的全部字节 + 末尾追加的目录。")
        panel.directoryURL = model.url.deletingLastPathComponent()
        panel.nameFieldStringValue = model.defaultOutputURL(suffix: String(localized: "-目录")).lastPathComponent
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let validator = OutputPanelValidator(model: model)
        panel.delegate = validator
        let response: NSApplication.ModalResponse
        if let window = session.window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        withExtendedLifetime(validator) {}
        guard response == .OK else { return nil }
        return panel.url
    }
}
