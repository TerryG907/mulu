import AppKit
import MuluAppModel

/// Save-panel delegate that refuses the input PDF (or an unwritable place) inside the panel,
/// before anything is written (GUI_SPEC §5.11 step 3).
@MainActor
final class OutputPanelValidator: NSObject, NSOpenSavePanelDelegate {
    private let model: DocumentModel
    private let checkWritable: Bool

    init(model: DocumentModel, checkWritable: Bool = true) {
        self.model = model
        self.checkWritable = checkWritable
    }

    func panel(_ sender: Any, validate url: URL) throws {
        do {
            if checkWritable {
                try model.validateOutputURL(url)
            } else if FileSniffer.identity(of: url) == FileSniffer.identity(of: model.url) {
                throw WriteError.wouldOverwriteInput
            }
        } catch let error as WriteError {
            var message = Wording.writeError(error)
            if case .notWritable(let detail) = error, !detail.isEmpty {
                message += "\n" + detail
            }
            throw NSError(domain: "io.github.terryg907.mulu", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
