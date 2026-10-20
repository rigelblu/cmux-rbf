import Testing
@testable import CmuxWorkspaces

@Suite("Group status cycle")
struct WorkspaceGroupStatusCycleTests {
    private let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "done", name: "Done"),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working),
        WorkspaceStatusEntry(id: "todo", name: "Future")
    ], source: .file)

    @Test func anUnsetGroupStartsAtTheBottomEntry() {
        #expect(WorkspaceGroupStatusCycle().target(statusId: nil, list: list) == "todo")
        let todoFirst = WorkspaceStatusList(entries: [list.entries[2], list.entries[0], list.entries[1]], source: .file)
        #expect(WorkspaceGroupStatusCycle().target(statusId: nil, list: todoFirst) == "doing")
    }
    @Test func eachPressMovesUpAndWrapsWithoutNone() {
        let cycle = WorkspaceGroupStatusCycle()
        #expect(cycle.target(statusId: "todo", list: list) == "doing")
        #expect(cycle.target(statusId: "doing", list: list) == "done")
        #expect(cycle.target(statusId: "done", list: list) == "todo")
    }
    @Test func aSingleEntryRemainsSelected() {
        let single = WorkspaceStatusList(entries: [list.entries[1]], source: .file)
        #expect(WorkspaceGroupStatusCycle().target(statusId: "doing", list: single) == "doing")
    }
    @Test func anEmptyListDoesNothing() {
        #expect(WorkspaceGroupStatusCycle().target(statusId: "doing", list: .init(entries: [], source: .file)) == nil)
    }
    @Test func anUnavailableStoredStatusStartsAtTheBottom() {
        #expect(WorkspaceGroupStatusCycle().target(statusId: "removed", list: list) == "todo")
    }
}
