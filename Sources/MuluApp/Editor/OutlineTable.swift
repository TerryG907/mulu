import AppKit
import MuluAppModel
import SwiftUI

/// The outline editor table: an AppKit view-based `NSTableView` over the model's flat
/// `displayRows` (GUI_SPEC §6.4). AppKit gives full control over Tab/Return/bracket keys and
/// inline editing, which neither SwiftUI `Table` nor `NSOutlineView` offer in this shape.
///
/// The observed values are passed in explicitly so SwiftUI calls `updateNSView` exactly when one
/// of them changes; the coordinator reloads only when `revision` moves.
struct OutlineTable: NSViewRepresentable {
    let session: DocumentSession
    let revision: Int
    let selection: Set<UUID>
    let focusedRowID: UUID?
    let editRequest: EditRequest?
    let reviewCurrent: UUID?
    /// `.disabled` does not reach an AppKit view: while a write runs the table is disabled here.
    let isEnabled: Bool

    func makeCoordinator() -> OutlineTableCoordinator {
        OutlineTableCoordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = OutlineTableView.make(handler: context.coordinator)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.attach(table)
        session.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView, table.isEnabled != isEnabled {
            table.isEnabled = isEnabled
        }
        context.coordinator.update(
            revision: revision,
            selection: selection,
            focus: focusedRowID,
            editRequest: editRequest,
            reviewCurrent: reviewCurrent)
    }
}
