import MuluAppModel
import SwiftUI

/// Recognition advisories above the table, each dismissible (GUI_SPEC §5.3 step 8).
struct AdvisoryList: View {
    let advisories: [Advisory]
    let onDismiss: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(advisories) { advisory in
                    AdvisoryRow(advisory: advisory) {
                        onDismiss(advisory.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
    }
}
