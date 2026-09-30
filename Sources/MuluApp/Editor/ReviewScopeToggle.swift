import MuluAppModel
import SwiftUI

/// "Only doubtful" switch of the review card; changing it restarts the review queue.
struct ReviewScopeToggle: View {
    let review: ReviewSession
    let model: DocumentModel
    @State private var onlyDoubtful = true

    var body: some View {
        Toggle("只看可疑", isOn: $onlyDoubtful)
            .toggleStyle(.checkbox)
            .onChange(of: review.onlyDoubtful, initial: true) { _, value in
                onlyDoubtful = value
            }
            .onChange(of: onlyDoubtful) { _, value in
                guard value != review.onlyDoubtful else { return }
                model.startReview(onlyDoubtful: value)
            }
    }
}
