import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// Nested workspace groups (#cm-106): what one plan costs. A top-level plan in a window with a nested group once rebuilt
// the flattened request three times; it builds it once. The test counts the flattened requests one plan builds, in a
// window of 300 workspaces in 30 groups and in one a tenth the size, with and without a nested group. A count does not
// depend on how busy the machine is, which a time ratio does.
@Suite struct SidebarNestedGroupDropPlanTimeTests {
    private func rows(groupCount: Int, nested: Bool) -> [DropRow] {
        var rows: [DropRow] = (0..<10).map { .ws("loose\($0)") }
        for group in 0..<groupCount {
            var children: [DropRow] = (0..<9).map { .ws("g\(group)w\($0)") }
            if nested && group == 3 {
                children.append(.grp("child", own: "childOwn", [.ws("c1"), .ws("c2")]))
            }
            rows.append(.grp("G\(group)", own: "g\(group)own", children))
        }
        return rows
    }

    #if DEBUG
    /// How many flattened requests one plan builds.
    private func flattenedRequestBuilds(_ window: NestedDropWindow, dragged: String, over: String) -> Int {
        let request = window.request(dragged: window.id(dragged), at: window.point(over, .upper, .right))
        let counter = SidebarNestedFlattenCounter()
        SidebarNestedFlattenProbe.$counter.withValue(counter) {
            _ = SidebarWorkspaceReorderDropResolver().plan(for: request)
        }
        return counter.builds
    }

    @Test func aTopLevelPlanInANestedWindowBuildsTheFlattenedRequestOnceHoweverBigTheWindowIs() {
        let small = flattenedRequestBuilds(NestedDropWindow(rows(groupCount: 4, nested: true)), dragged: "loose1", over: "loose6")
        let big = flattenedRequestBuilds(NestedDropWindow(rows(groupCount: 30, nested: true)), dragged: "loose1", over: "loose6")
        #expect(small == 1, "flattened requests built by one top-level plan, 4 groups")
        #expect(big == 1, "flattened requests built by one top-level plan, 30 groups")
    }

    @Test func aPlanInAWindowWithNoNestedGroupBuildsNoFlattenedRequest() {
        let flat = flattenedRequestBuilds(NestedDropWindow(rows(groupCount: 30, nested: false)), dragged: "loose1", over: "loose6")
        #expect(flat == 0, "flattened requests built by one plan in a window with no nested group")
    }
    #endif
}
