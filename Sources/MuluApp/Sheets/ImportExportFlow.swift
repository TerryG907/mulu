import AppKit
import MuluAppModel
import MuluCore
import UniformTypeIdentifiers

/// Import and export of outline files in the five `TOCFormat`s (GUI_SPEC §5.9).
@MainActor
enum ImportExportFlow {
    static let opmlType = UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml

    static func contentType(for format: TOCFormat) -> UTType {
        switch format {
        case .mulu, .pdfdir: .plainText
        case .pdfpatcherXML: .xml
        case .opml: opmlType
        case .json: .json
        }
    }

    // MARK: Import

    static func chooseAndImport(_ session: DocumentSession) async {
        session.commitEditing()
        let panel = NSOpenPanel()
        panel.title = String(localized: "导入目录")
        panel.prompt = String(localized: "导入")
        panel.allowedContentTypes = [.plainText, .xml, .json, opmlType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = session.model.url.deletingLastPathComponent()
        let picker = FormatPicker()
        panel.accessoryView = picker.view
        panel.isAccessoryViewDisclosed = true
        let response: NSApplication.ModalResponse
        if let window = session.window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        await importFile(url, format: picker.selectedFormat, session: session)
    }

    /// Imports one file; asks whether to replace or append when the draft already has rows.
    static func importFile(_ url: URL, format: TOCFormat?, session: DocumentSession) async {
        let model = session.model
        session.commitEditing()
        guard model.phase == .ready, !model.isWriting else { return }
        var mode = MergeMode.replace
        if !model.draft.rows.isEmpty {
            let alert = Alerts.make(
                String(localized: "导入“\(url.lastPathComponent)”"),
                detail: String(localized: "当前目录已有 \(model.draft.rows.count) 条。"),
                style: .informational,
                buttons: [
                    Wording.mergeMode(.replace),
                    Wording.mergeMode(.append),
                    String(localized: "取消"),
                ])
            switch await Alerts.run(alert, in: session.window) {
            case .alertFirstButtonReturn: mode = .replace
            case .alertSecondButtonReturn: mode = .append
            default: return
            }
        }
        do {
            // Read off the main actor, with a size limit: a dropped log file must not freeze the window.
            let bytes = try await DocumentModel.readOutlineFile(at: url)
            guard model.phase == .ready, !model.isWriting else { return }
            try model.importOutline(bytes: bytes, fileName: url.lastPathComponent, format: format, mode: mode)
            session.focusTable()
        } catch ImportError.tooLarge(let size, _) {
            let shown = Int64(size).formatted(.byteCount(style: .file))
            let limit = Int64(DocumentModel.maxImportBytes).formatted(.byteCount(style: .file))
            await Alerts.showError(
                String(localized: "导入失败"),
                explanation: String(localized: "“\(url.lastPathComponent)”有 \(shown)，不像目录文件（目录文件最多 \(limit)）。当前目录没有改动。"),
                detail: "",
                in: session.window)
        } catch {
            await Alerts.showError(
                String(localized: "导入失败"),
                explanation: String(localized: "“\(url.lastPathComponent)”没有被导入，当前目录没有改动。"),
                detail: String(describing: error),
                in: session.window)
        }
    }

    // MARK: Export

    static func export(_ format: TOCFormat, session: DocumentSession) async {
        let model = session.model
        session.commitEditing()
        do {
            _ = try model.exportText(format: format)
        } catch let WriteError.blocked(blockers) {
            await WriteFlow.presentBlockers(blockers, session: session)
            return
        } catch {
            await Alerts.showError(
                String(localized: "导出失败"),
                explanation: String(localized: "没有生成文件。"),
                detail: String(describing: error),
                in: session.window)
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "导出目录")
        panel.prompt = String(localized: "导出")
        panel.message = String(localized: "格式：\(Wording.formatName(format))。页码一律是 PDF 的物理页。")
        let suggested = model.defaultExportURL(format: format, suffix: String(localized: "-目录"))
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [contentType(for: format)]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let validator = OutputPanelValidator(model: model, checkWritable: false)
        panel.delegate = validator
        let response: NSApplication.ModalResponse
        if let window = session.window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        withExtendedLifetime(validator) {}
        guard response == .OK, let url = panel.url else { return }
        do {
            try model.export(to: url, format: format)
            session.lastExportFormat = format
        } catch {
            let explanation = (error as? WriteError).map(Wording.writeError) ?? String(localized: "没有生成文件。")
            await Alerts.showError(
                String(localized: "导出失败"),
                explanation: explanation,
                detail: String(describing: error),
                in: session.window)
        }
    }
}
