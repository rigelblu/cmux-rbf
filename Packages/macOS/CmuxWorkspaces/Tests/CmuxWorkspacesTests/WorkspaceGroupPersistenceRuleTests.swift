import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceGroupPersistenceRuleTests")
struct WorkspaceGroupPersistenceRuleTests {
    enum Entry {
        case save
        case restore
        case pruning
    }

    struct TableRow {
        let name: String
        let entry: Entry
        let candidates: [(name: String, id: UUID, parent: UUID?, noOwnWorkspace: Bool, isPinned: Bool)]
        let occupiedNames: [String]
        let expectedKeptNames: [String]
    }

    @Test
    func keepRuleTable() {
        let gA = UUID()
        let gB = UUID()
        let gC = UUID()
        let gP = UUID()
        let gGP = UUID()
        let ghost = UUID()

        let table: [TableRow] = [
            TableRow(
                name: "save: occupied group is kept",
                entry: .save,
                candidates: [("A", gA, nil, false, false)],
                occupiedNames: ["A"],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "save: unpinned empty group header is kept",
                entry: .save,
                candidates: [("A", gA, nil, true, false)],
                occupiedNames: [],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "save: unpinned group with missing members is not kept",
                entry: .save,
                candidates: [("A", gA, nil, false, false)],
                occupiedNames: [],
                expectedKeptNames: []
            ),
            TableRow(
                name: "save: pinned, has its own workspace, no restorable member: dropped",
                entry: .save,
                candidates: [("A", gA, nil, false, true)],
                occupiedNames: [],
                expectedKeptNames: []
            ),
            TableRow(
                name: "save: parent of kept child group is kept",
                entry: .save,
                candidates: [
                    ("P", gP, nil, false, false),
                    ("C", gC, gP, false, false)
                ],
                occupiedNames: ["C"],
                expectedKeptNames: ["C", "P"]
            ),
            TableRow(
                name: "save: grandparent chain of kept child is kept",
                entry: .save,
                candidates: [
                    ("GP", gGP, nil, false, false),
                    ("P", gP, gGP, false, false),
                    ("C", gC, gP, false, false)
                ],
                occupiedNames: ["C"],
                expectedKeptNames: ["C", "P", "GP"]
            ),
            TableRow(
                name: "save: a parent id that names no group is not added",
                entry: .save,
                candidates: [("A", gA, ghost, false, false)],
                occupiedNames: ["A"],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "restore: unpinned group with no restored members is dropped",
                entry: .restore,
                candidates: [("A", gA, nil, false, false)],
                occupiedNames: [],
                expectedKeptNames: []
            ),
            TableRow(
                name: "restore: pinned group with no restored members is kept",
                entry: .restore,
                candidates: [("A", gA, nil, false, true)],
                occupiedNames: [],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "restore: empty header survives regardless of pin",
                entry: .restore,
                candidates: [
                    ("A", gA, nil, true, false),
                    ("B", gB, nil, true, true)
                ],
                occupiedNames: [],
                expectedKeptNames: ["A", "B"]
            ),
            TableRow(
                name: "restore: parent kept when child is kept via pinned empty",
                entry: .restore,
                candidates: [
                    ("P", gP, nil, false, false),
                    ("C", gC, gP, false, true)
                ],
                occupiedNames: [],
                expectedKeptNames: ["C", "P"]
            ),
            TableRow(
                name: "restore: a parent id that names no group is not added",
                entry: .restore,
                candidates: [("A", gA, ghost, true, false)],
                occupiedNames: [],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "pruning: pinned, has its own workspace, no kept member: dropped",
                entry: .pruning,
                candidates: [("A", gA, nil, false, true)],
                occupiedNames: [],
                expectedKeptNames: []
            ),
            TableRow(
                name: "pruning: empty header is kept",
                entry: .pruning,
                candidates: [("A", gA, nil, true, false)],
                occupiedNames: [],
                expectedKeptNames: ["A"]
            ),
            TableRow(
                name: "pruning: parent of a kept child is kept",
                entry: .pruning,
                candidates: [
                    ("P", gP, nil, false, false),
                    ("C", gC, gP, false, false)
                ],
                occupiedNames: ["C"],
                expectedKeptNames: ["C", "P"]
            ),
            TableRow(
                name: "pruning: a parent id that names no group is not added",
                entry: .pruning,
                candidates: [("A", gA, ghost, false, false)],
                occupiedNames: ["A"],
                expectedKeptNames: ["A"]
            )
        ]

        for row in table {
            let idByName = Dictionary(uniqueKeysWithValues: row.candidates.map { ($0.name, $0.id) })
            let occupied = Set(row.occupiedNames.compactMap { idByName[$0] })
            let kept: Set<UUID>
            switch row.entry {
            case .save:
                let groups = row.candidates.map { candidate in
                    WorkspaceGroup(
                        id: candidate.id,
                        name: candidate.name,
                        isCollapsed: false,
                        isPinned: candidate.isPinned,
                        anchor: candidate.noOwnWorkspace ? .empty(candidate.id) : .workspace(UUID()),
                        customColor: nil,
                        iconSymbol: nil,
                        parentGroupId: candidate.parent
                    )
                }
                kept = WorkspaceGroupPersistenceRule.keptGroupIdsForSave(
                    groups: groups,
                    occupiedGroupIds: occupied
                )
            case .restore, .pruning:
                let saved = row.candidates.map {
                    (id: $0.id, parentGroupId: $0.parent, anchorIsEmpty: Optional($0.noOwnWorkspace), isPinned: Optional($0.isPinned))
                }
                kept = row.entry == .restore
                    ? WorkspaceGroupPersistenceRule.keptGroupIdsForRestore(saved: saved, occupiedGroupIds: occupied)
                    : WorkspaceGroupPersistenceRule.keptGroupIdsForPruning(saved: saved, occupiedGroupIds: occupied)
            }
            // Compare ids, not names: an id that names no group has no name to show.
            let expected = Set(row.expectedKeptNames.compactMap { idByName[$0] })
            #expect(kept == expected, "\(row.name): expected \(expected.count) ids, got \(kept.count) (extra: \(kept.subtracting(expected)), missing: \(expected.subtracting(kept)))")
        }
    }

    @Test
    func savedFlagsThatAreAbsentReadAsNotEmptyAndNotPinned() {
        let id = UUID()
        let saved: [WorkspaceGroupPersistenceRule.SavedGroup] = [(id: id, parentGroupId: nil, anchorIsEmpty: nil, isPinned: nil)]
        #expect(WorkspaceGroupPersistenceRule.keptGroupIdsForRestore(saved: saved, occupiedGroupIds: []).isEmpty)
        #expect(WorkspaceGroupPersistenceRule.keptGroupIdsForPruning(saved: saved, occupiedGroupIds: []).isEmpty)
        #expect(WorkspaceGroupPersistenceRule.keptGroupIdsForPruning(saved: saved, occupiedGroupIds: [id]) == [id])
    }
}
