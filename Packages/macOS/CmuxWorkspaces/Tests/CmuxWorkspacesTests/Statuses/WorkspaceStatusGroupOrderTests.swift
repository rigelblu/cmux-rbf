import Testing
@testable import CmuxWorkspaces

struct WorkspaceStatusGroupOrderTests {
    @Test func fileReorderAppliesBeforeAnyDrag() {
        #expect(WorkspaceStatusGroupOrder.resolved(fileIds: ["c", "a", "b"], storedOrder: nil) == ["c", "a", "b"])
    }
    @Test func fileReorderDoesNotReplaceDraggedOrder() {
        #expect(WorkspaceStatusGroupOrder.resolved(fileIds: ["c", "a", "b"], storedOrder: ["b", "a", "c"]) == ["b", "a", "c"])
    }
    @Test func aNewStatusLandsBetweenItsFileNeighbours() {
        #expect(WorkspaceStatusGroupOrder.resolved(fileIds: ["a", "new", "b", "c"], storedOrder: ["c", "a", "b"]) == ["c", "a", "new", "b"])
    }
    @Test func aNewFirstStatusLandsBeforeItsFollowingFileNeighbour() {
        #expect(WorkspaceStatusGroupOrder.resolved(fileIds: ["new", "a", "b"], storedOrder: ["b", "a"]) == ["b", "new", "a"])
    }
    @Test func draggingKeepsUnknownStoredIdsForTheirReturn() throws {
        let moved = try #require(WorkspaceStatusGroupOrder.moving("b", relativeTo: "a", insertBefore: true,
            fileIds: ["a", "b"], storedOrder: ["a", "not-listed", "b"]))
        #expect(moved == ["b", "a", "not-listed"])
        #expect(WorkspaceStatusGroupOrder.resolved(fileIds: ["a", "not-listed", "b"], storedOrder: moved) == moved)
    }
    @Test func draggingAlsoIncludesNewFileStatusesWithoutPruningThem() throws {
        let moved = try #require(WorkspaceStatusGroupOrder.moving("c", relativeTo: "new", insertBefore: false,
            fileIds: ["a", "new", "b", "c"], storedOrder: ["c", "a", "b"]))
        #expect(moved == ["a", "new", "c", "b"])
    }
}
