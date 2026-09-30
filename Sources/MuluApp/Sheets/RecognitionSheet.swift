import MuluAppModel
import SwiftUI

/// Sheet for "Recognize TOC Pages…" and "Paste TOC Text…" (GUI_SPEC §5.3, §5.4). Its content
/// follows the model's recognition state: input form → progress → result.
struct RecognitionSheet: View {
    let session: DocumentSession
    let kind: SessionSheet

    private var title: LocalizedStringKey {
        kind == .recognize ? "识别目录页" : "粘贴目录文字"
    }

    var body: some View {
        let model = session.model
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .bold()
            switch model.recognition {
            case .running(let progress):
                RecognitionProgressView(progress: progress, onCancel: model.cancelRecognition)
            case .finished(let result):
                RecognitionResultView(result: result, session: session, kind: kind)
            case .idle, .failed, .cancelled:
                RecognitionOutcomeNote(state: model.recognition)
                if kind == .recognize {
                    RecognizeForm(session: session)
                } else {
                    PasteTOCForm(session: session)
                }
            }
        }
        .padding(20)
        .frame(width: kind == .recognize ? 480 : 600)
        .interactiveDismissDisabled(session.isRecognizing)
    }
}
