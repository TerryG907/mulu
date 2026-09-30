import Foundation
import Testing
@testable import MuluAppModel

/// Helpers: a draft from (title, level) pairs, and its shape back.
@MainActor
enum Tree {
    /// A
    ///   A1
    ///   A2
    ///     A2a
    ///   A3
    /// B
    ///   B1
    /// C
    static let base: [(String, Int)] = [("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]

    static func rows(_ spec: [(String, Int)]) -> [OutlineRow] {
        spec.enumerated().map { i, s in OutlineRow(title: s.0, level: s.1, manualPage: i + 1) }
    }

    static func model(_ spec: [(String, Int)] = base) -> DocumentModel {
        DocumentModel(previewRows: rows(spec), pageCount: 100)
    }

    static func shape(_ m: DocumentModel) -> [String] {
        m.draft.rows.map { "\($0.title):\($0.level)" }
    }

    static func shape(_ spec: [(String, Int)]) -> [String] {
        spec.map { "\($0.0):\($0.1)" }
    }

    static func ids(_ m: DocumentModel, _ titles: String...) -> Set<UUID> {
        Set(m.draft.rows.filter { titles.contains($0.title) }.map(\.id))
    }

    static func id(_ m: DocumentModel, _ title: String) -> UUID {
        m.draft.rows.first { $0.title == title }!.id
    }
}

/// The table of GUI_SPEC §9.1 (first row, last row, blocks with children, consecutive and
/// non-consecutive multi-selections).
enum DraftCases {
    enum Op: Sendable {
        case indent, outdent, moveUp, moveDown, delete, deleteKeep
    }

    struct Case: Sendable, CustomStringConvertible {
        var op: Op
        var targets: [String]
        /// nil: the operation must refuse and leave the draft unchanged.
        var expected: [(String, Int)]?
        var description: String { "\(op) \(targets)" }
    }

    static let all: [Case] = [
        // indent: the block becomes the last child of its previous sibling
        Case(op: .indent, targets: ["B"], expected: [("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 1), ("B", 1), ("B1", 2), ("C", 0)]),
        Case(op: .indent, targets: ["A2"], expected: [("A", 0), ("A1", 1), ("A2", 2), ("A2a", 3), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .indent, targets: ["A2", "A3"], expected: [("A", 0), ("A1", 1), ("A2", 2), ("A2a", 3), ("A3", 2), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .indent, targets: ["C"], expected: [("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 1), ("B", 0), ("B1", 1), ("C", 1)]),
        Case(op: .indent, targets: ["A"], expected: nil),     // first row
        Case(op: .indent, targets: ["A1"], expected: nil),    // first child: no previous sibling
        Case(op: .indent, targets: ["A2a"], expected: nil),
        // outdent: order unchanged, following siblings become children
        Case(op: .outdent, targets: ["A2"], expected: [("A", 0), ("A1", 1), ("A2", 0), ("A2a", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .outdent, targets: ["A1", "A2a"], expected: [("A", 0), ("A1", 0), ("A2", 1), ("A2a", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .outdent, targets: ["A3"], expected: [("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 0), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .outdent, targets: ["A", "B", "C"], expected: nil),
        // move up / down: swap with the neighbouring sibling's block, never across parents
        Case(op: .moveUp, targets: ["A2"], expected: [("A", 0), ("A2", 1), ("A2a", 2), ("A1", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .moveUp, targets: ["B"], expected: [("B", 0), ("B1", 1), ("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 1), ("C", 0)]),
        Case(op: .moveUp, targets: ["A2", "A3"], expected: [("A", 0), ("A2", 1), ("A2a", 2), ("A3", 1), ("A1", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .moveUp, targets: ["A2", "A2a"], expected: [("A", 0), ("A2", 1), ("A2a", 2), ("A1", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .moveUp, targets: ["A1"], expected: nil),        // first child
        Case(op: .moveUp, targets: ["A"], expected: nil),         // first row
        Case(op: .moveUp, targets: ["B1"], expected: nil),        // only child: never into another parent
        Case(op: .moveUp, targets: ["A1", "A3"], expected: nil),  // not consecutive
        Case(op: .moveUp, targets: ["A3", "B"], expected: nil),   // different levels
        Case(op: .moveDown, targets: ["A1"], expected: [("A", 0), ("A2", 1), ("A2a", 2), ("A1", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .moveDown, targets: ["A", "B"], expected: [("C", 0), ("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("A3", 1), ("B", 0), ("B1", 1)]),
        Case(op: .moveDown, targets: ["A3"], expected: nil),      // last child
        Case(op: .moveDown, targets: ["C"], expected: nil),       // last row
        // delete with children, or keeping them (lifted one level per deleted ancestor)
        Case(op: .delete, targets: ["A2"], expected: [("A", 0), ("A1", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .delete, targets: ["A2", "A2a"], expected: [("A", 0), ("A1", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .delete, targets: ["A"], expected: [("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .delete, targets: ["A1", "B1", "C"], expected: [("A", 0), ("A2", 1), ("A2a", 2), ("A3", 1), ("B", 0)]),
        Case(op: .deleteKeep, targets: ["A"], expected: [("A1", 0), ("A2", 0), ("A2a", 1), ("A3", 0), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .deleteKeep, targets: ["A", "A2"], expected: [("A1", 0), ("A2a", 0), ("A3", 0), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .deleteKeep, targets: ["A2a"], expected: [("A", 0), ("A1", 1), ("A2", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]),
        Case(op: .delete, targets: [], expected: nil),
    ]
}

@MainActor
@Suite struct DraftOperationTests {
    typealias Case = DraftCases.Case

    @Test(arguments: DraftCases.all)
    func operation(_ c: Case) {
        let m = Tree.model()
        let ids = Set(c.targets.map { Tree.id(m, $0) })
        let before = m.draft
        let can: Bool? = switch c.op {
        case .indent: m.canIndent(ids)
        case .outdent: m.canOutdent(ids)
        case .moveUp: m.canMoveUp(ids)
        case .moveDown: m.canMoveDown(ids)
        default: nil
        }
        let changed: Bool = switch c.op {
        case .indent: m.indent(ids)
        case .outdent: m.outdent(ids)
        case .moveUp: m.moveUp(ids)
        case .moveDown: m.moveDown(ids)
        case .delete: m.delete(ids)
        case .deleteKeep: m.delete(ids, keepChildren: true)
        }
        #expect(OutlineDraft.levelsAreValid(m.draft.rows))
        if let expected = c.expected {
            #expect(changed)
            #expect(Tree.shape(m) == Tree.shape(expected))
            #expect(m.undoManager.canUndo)
            m.undoManager.undo()
            #expect(m.draft == before)
        } else {
            #expect(!changed)
            #expect(m.draft == before)
            #expect(!m.undoManager.canUndo)
        }
        if let can { #expect(can == changed) }
    }

    @Test func addSiblingAndChild() {
        let m = Tree.model()
        m.previewDidShow(page: 42)
        let s = m.addSibling(after: Tree.id(m, "A2"), title: "N")
        #expect(Tree.shape(m) == Tree.shape([("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("N", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]))
        #expect(m.row(s)?.manualPage == 42)
        #expect(m.selection == [s] && m.focusedRowID == s)
        #expect(m.editRequest?.rowID == s && m.editRequest?.field == .title)

        let c = m.addChild(of: Tree.id(m, "A2"), title: "K")
        #expect(Tree.shape(m) == Tree.shape([("A", 0), ("A1", 1), ("A2", 1), ("A2a", 2), ("K", 2), ("N", 1), ("A3", 1), ("B", 0), ("B1", 1), ("C", 0)]))
        #expect(m.focusedRowID == c)

        let e = m.addSibling(after: nil, title: "Z")
        #expect(m.draft.rows.last?.id == e && m.draft.rows.last?.level == 0)
        _ = m.addChild(of: Tree.id(m, "Z"), title: "Z1")
        #expect(Array(Tree.shape(m).suffix(2)) == ["Z:0", "Z1:1"])

        // an empty draft
        let empty = Tree.model([])
        let first = empty.addSibling(after: nil)
        #expect(empty.draft.rows.map(\.id) == [first] && empty.draft.rows[0].level == 0 && empty.draft.rows[0].title.isEmpty)
    }

    @Test func deleteSelectsTheNextRowElseThePrevious() {
        let m = Tree.model()
        m.delete(Tree.ids(m, "A2"))
        #expect(m.focusedRowID == Tree.id(m, "A3") && m.selection == [Tree.id(m, "A3")])
        m.delete(Tree.ids(m, "C"))
        #expect(m.focusedRowID == Tree.id(m, "B1"))
        m.delete(Set(m.draft.rows.map(\.id)))
        #expect(m.draft.rows.isEmpty && m.focusedRowID == nil && m.selection.isEmpty)
    }

    @Test func unknownIDsChangeNothing() {
        let m = Tree.model()
        let before = m.draft
        let ghost: Set<UUID> = [UUID()]
        #expect(!m.indent(ghost) && !m.outdent(ghost) && !m.moveUp(ghost) && !m.moveDown(ghost))
        #expect(!m.delete(ghost) && !m.setConfirmed(ghost, true) && !m.shiftPages(ghost, by: 2) && !m.clearOverride(ghost))
        #expect(!m.setTitle(UUID(), "x") && !m.setPhysicalPage(UUID(), 3) && !m.pinToPreviewPage(UUID()))
        #expect(m.draft == before && !m.undoManager.canUndo)
    }

    /// A deterministic generator (SplitMix64).
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 500 random operations: the invariant holds after every step; a refused operation leaves
    /// the draft untouched; undoing everything restores the start field by field, redoing
    /// everything restores the end.
    @Test func randomOperationsKeepTheInvariantAndUndoCleanly() {
        var rng = SeededRNG(state: 20_260_930)
        let m = DocumentModel(previewRows: Tree.rows(Tree.base) + [
            OutlineRow(title: "P", level: 0, printedPage: PrintedPageRef(style: .arabic, value: 40)),
            OutlineRow(title: "R", level: 1, printedPage: PrintedPageRef(style: .roman, value: 3)),
        ], pageCount: 80, mapping: PageMapping(offset: 2))
        let start = m.draft
        var steps = 0
        for n in 0..<500 {
            let rows = m.draft.rows
            var pick: Set<UUID> = []
            if !rows.isEmpty {
                let k = Int.random(in: 1...min(3, rows.count), using: &rng)
                for _ in 0..<k { pick.insert(rows[Int.random(in: 0..<rows.count, using: &rng)].id) }
            }
            let one = pick.first
            let before = m.draft
            let changed: Bool
            switch Int.random(in: 0..<16, using: &rng) {
            case 0: changed = m.indent(pick)
            case 1: changed = m.outdent(pick)
            case 2: changed = m.moveUp(pick)
            case 3: changed = m.moveDown(pick)
            case 4:
                _ = m.addSibling(after: one, title: "s\(n)")
                changed = true
            case 5:
                if let one { _ = m.addChild(of: one, title: "c\(n)") } else { _ = m.addSibling(after: nil, title: "c\(n)") }
                changed = true
            case 6: changed = rows.count > 3 ? m.delete(pick) : false
            case 7: changed = rows.count > 3 ? m.delete(pick, keepChildren: true) : false
            case 8: changed = one.map { m.setTitle($0, "t\(n) ") } ?? false
            case 9: changed = m.shiftPages(pick, by: Int.random(in: -3...3, using: &rng))
            case 10: changed = m.setConfirmed(pick, Bool.random(using: &rng))
            case 11: changed = m.setOffset(Int.random(in: -5...5, using: &rng))
            case 12: changed = one.map { m.setPhysicalPage($0, Int.random(in: 1...80, using: &rng)) } ?? false
            case 13: changed = m.clearOverride(pick)
            case 14: changed = m.setRomanOffset(Bool.random(using: &rng) ? nil : Int.random(in: 0...6, using: &rng))
            default: changed = one.map { m.calibrateOffset(using: $0, physicalPage: Int.random(in: 1...80, using: &rng)) } ?? false
            }
            #expect(OutlineDraft.levelsAreValid(m.draft.rows), "step \(n)")
            if changed {
                steps += 1
            } else {
                #expect(m.draft == before, "step \(n) reported no change but changed the draft")
            }
        }
        let end = m.draft
        var undone = 0
        while m.undoManager.canUndo {
            m.undoManager.undo()
            undone += 1
            #expect(OutlineDraft.levelsAreValid(m.draft.rows))
        }
        #expect(undone == steps)
        #expect(m.draft == start)
        while m.undoManager.canRedo { m.undoManager.redo() }
        #expect(m.draft == end)
    }
}
