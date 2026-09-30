import AppKit
import MuluAppModel

/// Row background by status: errors red, doubtful orange, the review row in the accent colour.
final class OutlineRowView: NSTableRowView {
    private var status: RowStatus = .ok
    private var isReviewCurrent = false

    func apply(status: RowStatus, isReviewCurrent: Bool) {
        guard status != self.status || isReviewCurrent != self.isReviewCurrent else { return }
        self.status = status
        self.isReviewCurrent = isReviewCurrent
        needsDisplay = true
    }

    /// The status colour: a 3 pt bar at the leading edge plus a tint strong enough to see in
    /// dark mode too.
    private var statusColor: NSColor? {
        switch status {
        case .error: return .systemRed
        case .doubtful: return .systemOrange
        case .ok, .confirmed: return nil
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isReviewCurrent {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        } else if let color = statusColor {
            color.withAlphaComponent(0.22).setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        }
        if let color = statusColor {
            color.setFill()
            var bar = bounds
            bar.size.width = 3
            if userInterfaceLayoutDirection == .rightToLeft { bar.origin.x = bounds.maxX - 3 }
            bar.intersection(dirtyRect).fill()
        }
    }
}
