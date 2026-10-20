import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Group status and color picks")
struct WorkspaceGroupStatusActionsTests {
    private let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "Brown"),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working, color: "Green"),
        WorkspaceStatusEntry(id: "uncolored", name: "Uncolored", extends: .todo),
        WorkspaceStatusEntry(id: "missing", name: "Missing", extends: .todo, color: "Missing")
    ], source: .file)

    private var actions: WorkspaceGroupStatusActions {
        WorkspaceGroupStatusActions(list: list, resolveColor: { ["Brown": "#765432", "Green": "#008800"][$0] })
    }

    private func group(status: String? = nil, color: String? = "#112233") -> WorkspaceGroup {
        var group = WorkspaceGroup(id: UUID(), name: "Group", isCollapsed: false, isPinned: false,
                                   anchorWorkspaceId: UUID(), customColor: color, iconSymbol: nil)
        group.statusId = status
        return group
    }

    @Test func statusWritesItsColor() {
        var group = group()
        #expect(actions.apply(.status(id: "parked"), to: &group))
        #expect(group.statusId == "parked")
        #expect(group.customColor == "#765432")
    }

    @Test(arguments: [WorkspaceStatusPickAction.auto, .hide])
    func clearingRemovesBothFields(_ action: WorkspaceStatusPickAction) {
        var group = group(status: "parked", color: "#765432")
        #expect(actions.apply(action, to: &group))
        #expect(group.statusId == nil)
        #expect(group.customColor == nil)
    }

    @Test(arguments: ["uncolored", "missing", "done"])
    func statusWithNoAvailableColorRemovesOldColor(_ id: String) {
        var group = group(status: "parked", color: "#765432")
        #expect(actions.apply(.status(id: id), to: &group))
        #expect(group.statusId == id)
        #expect(group.customColor == nil)
    }

    @Test func unknownStatusIsRefusedWithoutMutation() {
        var group = group(status: "parked", color: "#765432")
        let before = group
        #expect(!actions.apply(.status(id: "unknown"), to: &group))
        #expect(group == before)
    }

    @Test func statusColorPicksItsStatus() {
        var group = group()
        actions.applyColor("#765432", to: &group)
        #expect(group.statusId == "parked")
        #expect(group.customColor == "#765432")
    }

    @Test func anotherStatusColorReplacesStatus() {
        var group = group(status: "parked", color: "#765432")
        actions.applyColor("#008800", to: &group)
        #expect(group.statusId == "doing")
        #expect(group.customColor == "#008800")
    }

    @Test func plainColorClearsStatusAndKeepsPickedColor() {
        var group = group(status: "parked", color: "#765432")
        actions.applyColor("#ABCDEF", to: &group)
        #expect(group.statusId == nil)
        #expect(group.customColor == "#ABCDEF")
    }

    @Test(arguments: [nil, ""] as [String?])
    func noColorClearsBothFields(_ hex: String?) {
        var group = group(status: "parked", color: "#765432")
        actions.applyColor(hex, to: &group)
        #expect(group.statusId == nil)
        #expect(group.customColor == nil)
    }

    @Test func colorMatchingNormalizesHexAndUsesListOrder() {
        var group = group()
        let duplicateList = WorkspaceStatusList(entries: [
            WorkspaceStatusEntry(id: "first", name: "First", extends: .todo, color: "One"),
            WorkspaceStatusEntry(id: "second", name: "Second", extends: .todo, color: "Two")
        ], source: .file)
        let writer = WorkspaceGroupStatusActions(list: duplicateList, resolveColor: { _ in "#abcdef" })
        writer.applyColor("ABCDEF", to: &group)
        #expect(group.statusId == "first")
        #expect(group.customColor == "#ABCDEF")
    }
}
