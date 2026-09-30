import AppKit
import UniformTypeIdentifiers

/// Open panels for PDFs.
@MainActor
enum OpenPanels {
    static func choosePDFs() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "打开 PDF")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let response = await panel.begin()
        return response == .OK ? panel.urls : []
    }
}
