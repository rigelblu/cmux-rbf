import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the order Delete Group closes workspaces in is the same on every run. It is
// the deepest level first, the groups of one level in the order they stand in the sidebar, the deleted group last.
@MainActor
struct WorkspaceGroupNestedDeleteOrderTests {
    private static let childNames = ["c0", "c1", "c2", "c3", "c4", "c5"]

    /// P holds six child groups at one level; the second child holds a group of its own.
    private func closes() -> [String] {
        var lab = Labels()
        var tabs = [lab.ws("p", in: "P")]
        var groups = [lab.group("P", own: "p")]
        for name in Self.childNames {
            tabs.append(lab.ws("\(name)o", in: name))
            tabs.append(lab.ws("\(name)x", in: name))
            groups.append(lab.group(name, parent: "P", own: "\(name)o"))
            if name == "c1" {
                tabs.append(lab.ws("g", in: "G"))
                groups.append(lab.group("G", parent: "c1", own: "g"))
            }
        }
        tabs.append(lab.ws("z"))
        let w = NestedWorld(NestWindow(tabs: tabs, groups: groups))
        #expect(w.groups.deleteWorkspaceGroup(groupId: lab.id("P")) == 14)
        return w.host.closedWorkspaceIds.map { lab.name($0) }
    }

    @Test
    func deleteGroupClosesTheDeepestLevelFirstThenEachLevelInSidebarOrderAndTheDeletedGroupLast() {
        let expected = ["g"]
            + Self.childNames.flatMap { ["\($0)x", "\($0)o"] }
            + ["p"]
        #expect(closes() == expected)
    }

    @Test
    func theSameDeleteRunTwiceFromTheSameStateClosesInTheSameOrder() {
        #expect(closes() == closes())
    }
}
