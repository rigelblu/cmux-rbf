import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceStatusGroupProjectionTests {
    typealias F = WorkspaceStatusFixtures

    private let parkedColorHex = "#ffaa00"
    private let nextColorHex = "#00aaff"
    private let doneColorHex = "#00ff00"
    private let reviewColorHex = "#aa00ff"
    private let unrelatedColorHex = "#123456"

    private var resolvedHexByStatusId: [String: String] {
        [
            "parked": parkedColorHex,
            "next": nextColorHex,
            "done": doneColorHex,
            "review": reviewColorHex,
        ]
    }

    // MARK: - Membership Table Tests (build-brief lines 198-208)

    struct MembershipTestCase: Sendable, CustomStringConvertible {
        let name: String
        let resolution: WorkspaceStatusResolution
        let colorHex: String?
        let isStatusHidden: Bool
        let isPinned: Bool
        let groupId: UUID?
        let list: WorkspaceStatusList
        let expectedStatusGroupId: String?

        var description: String { name }
    }

    @Test("Membership table rows for status group projection", arguments: [
        MembershipTestCase(
            name: "ownInEffect joins its status group",
            resolution: .ownInEffect(F.parked),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "parked"
        ),
        MembershipTestCase(
            name: "cmuxInEffect offered joins its status group",
            resolution: .cmuxInEffect(F.done, offered: true),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "done"
        ),
        MembershipTestCase(
            name: "detected done joins done group when list has done",
            resolution: .detected(.done),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "done"
        ),
        MembershipTestCase(
            name: "detected review joins review group when list has review",
            resolution: .detected(.review),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "review"
        ),
        MembershipTestCase(
            name: "detected todo goes by color (matches next)",
            resolution: .detected(.todo),
            colorHex: "#00aaff",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "next"
        ),
        MembershipTestCase(
            name: "detected working goes by color (matches parked)",
            resolution: .detected(.working),
            colorHex: "#ffaa00",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "parked"
        ),
        MembershipTestCase(
            name: "detected needsAttention goes by color (no match -> no group)",
            resolution: .detected(.needsAttention),
            colorHex: "#123456",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "ownNotListed goes by color (matches next)",
            resolution: .ownNotListed(id: "unlisted", detected: .done),
            colorHex: "#00aaff",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "next"
        ),
        MembershipTestCase(
            name: "ownNotListed goes by color (no match -> no group)",
            resolution: .ownNotListed(id: "unlisted", detected: .done),
            colorHex: "#123456",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "cmuxInEffect offered false goes by color (matches parked)",
            resolution: .cmuxInEffect(WorkspaceStatusEntry(id: "working", name: nil), offered: false),
            colorHex: "#ffaa00",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "parked"
        ),
        MembershipTestCase(
            name: "cmuxLapsed detected done joins done group",
            resolution: .cmuxLapsed(detected: .done),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "done"
        ),
        MembershipTestCase(
            name: "cmuxLapsed detected review joins review group",
            resolution: .cmuxLapsed(detected: .review),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "review"
        ),
        MembershipTestCase(
            name: "cmuxLapsed other goes by color (matches next)",
            resolution: .cmuxLapsed(detected: .working),
            colorHex: "#00aaff",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: "next"
        ),
        MembershipTestCase(
            name: "pinned workspace joins no status group",
            resolution: .ownInEffect(F.parked),
            colorHex: "#ffaa00",
            isStatusHidden: false,
            isPinned: true,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "workspace in workspace group joins no status group",
            resolution: .ownInEffect(F.parked),
            colorHex: "#ffaa00",
            isStatusHidden: false,
            isPinned: false,
            groupId: UUID(),
            list: F.toms,
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "workspace on None joins no group despite a matching color",
            resolution: .ownInEffect(F.parked),
            colorHex: "#00aaff",
            isStatusHidden: true,
            isPinned: false,
            groupId: nil,
            list: F.toms,
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "detected done with no done entry goes by its color (parked color)",
            resolution: .detected(.done),
            colorHex: "#ffaa00",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: WorkspaceStatusList(entries: [F.parked, F.next], source: .file),
            expectedStatusGroupId: "parked"
        ),
        MembershipTestCase(
            name: "detected done with no done entry and no color joins no group",
            resolution: .detected(.done),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: WorkspaceStatusList(entries: [F.parked, F.next], source: .file),
            expectedStatusGroupId: nil
        ),
        MembershipTestCase(
            name: "detected review with no review entry goes by its color (next color)",
            resolution: .detected(.review),
            colorHex: "#00aaff",
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: WorkspaceStatusList(entries: [F.parked, F.next], source: .file),
            expectedStatusGroupId: "next"
        ),
        MembershipTestCase(
            name: "detected review with no review entry and no color joins no group",
            resolution: .detected(.review),
            colorHex: nil,
            isStatusHidden: false,
            isPinned: false,
            groupId: nil,
            list: WorkspaceStatusList(entries: [F.parked, F.next], source: .file),
            expectedStatusGroupId: nil
        ),
    ])
    func membershipTableTests(testCase: MembershipTestCase) {
        let wsId = UUID()
        let item = WorkspaceStatusGroupProjectionItem(
            workspaceId: wsId,
            groupId: testCase.groupId,
            isPinned: testCase.isPinned,
            isStatusHidden: testCase.isStatusHidden,
            normalizedColorHex: testCase.colorHex,
            resolution: testCase.resolution
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item],
            list: testCase.list,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        guard let projection else {
            #expect(testCase.expectedStatusGroupId == nil, "Expected group \(String(describing: testCase.expectedStatusGroupId)) but got no projection")
            return
        }

        if let expectedGroupId = testCase.expectedStatusGroupId {
            let group = projection.group(for: expectedGroupId)
            #expect(group != nil, "Expected status group \(expectedGroupId) to exist")
            #expect(group?.memberWorkspaceIds == [wsId], "Expected \(expectedGroupId) to contain [\(wsId)], got \(String(describing: group?.memberWorkspaceIds))")
            #expect(projection.contains(workspaceId: wsId))
        } else {
            #expect(!projection.contains(workspaceId: wsId), "Expected workspace to be in no group")
        }
    }

    // MARK: - Non-Drop 09:446-496 Rules

    @Test func statusWinsOverColorWhenDisagreeing() {
        // Workspace has status "parked", but wears "next"'s color "#00aaff".
        let wsId = UUID()
        let item = WorkspaceStatusGroupProjectionItem(
            workspaceId: wsId,
            normalizedColorHex: nextColorHex,
            resolution: .ownInEffect(F.parked)
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item],
            list: F.toms,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        #expect(projection?.group(for: "parked")?.memberWorkspaceIds == [wsId])
        #expect(projection?.group(for: "next")?.memberWorkspaceIds == [])
    }

    @Test func firstStatusInFileOrderWinsWhenTwoStatusesShareColor() {
        // Suppose paused and blocked both resolve to "#ffaa00".
        // In toms list, paused is before blocked.
        let hexMap = ["paused": "#ffaa00", "blocked": "#ffaa00"]
        let wsId = UUID()
        let item = WorkspaceStatusGroupProjectionItem(
            workspaceId: wsId,
            normalizedColorHex: "#ffaa00",
            resolution: .detected(.todo)
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item],
            list: F.toms,
            resolvedHexByStatusId: hexMap
        )
        #expect(projection?.group(for: "paused")?.memberWorkspaceIds == [wsId])
        #expect(projection?.group(for: "blocked")?.memberWorkspaceIds == [])
    }

    @Test func unresolvableColorDoesNotMatchByColor() {
        // Status "future" has no resolved hex.
        let ws1 = UUID()
        let ws2 = UUID()
        let item1 = WorkspaceStatusGroupProjectionItem(
            workspaceId: ws1,
            normalizedColorHex: "#999999",
            resolution: .ownInEffect(F.future)
        )
        let item2 = WorkspaceStatusGroupProjectionItem(
            workspaceId: ws2,
            normalizedColorHex: "#999999",
            resolution: .detected(.todo)
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item1, item2],
            list: F.toms,
            resolvedHexByStatusId: [:] // no resolved colors
        )
        #expect(projection?.group(for: "future")?.memberWorkspaceIds == [ws1])
        #expect(projection?.contains(workspaceId: ws2) == false)
    }

    @Test func listWithNoEntriesShowsNoArea() {
        let emptyList = WorkspaceStatusList(entries: [], source: .file)
        let item = WorkspaceStatusGroupProjectionItem(
            workspaceId: UUID(),
            resolution: .ownInEffect(F.parked)
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item],
            list: emptyList,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        #expect(projection == nil)
    }

    @Test func cmuxFiveSourceShowsNoArea() {
        let item = WorkspaceStatusGroupProjectionItem(
            workspaceId: UUID(),
            resolution: .detected(.done)
        )
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [item],
            list: WorkspaceStatusList.cmuxFive,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        #expect(projection == nil)
    }

    @Test func allStatusesShowEvenWhenEmpty() {
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: [],
            list: F.toms,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        #expect(projection != nil)
        #expect(projection?.groups.count == F.tomsEntries.count)
        for entry in F.tomsEntries {
            #expect(projection?.group(for: entry.id)?.memberWorkspaceIds == [])
        }
    }

    @Test func membersPreserveInputWorkspaceListOrder() {
        let w1 = UUID()
        let w2 = UUID()
        let w3 = UUID()
        let items = [
            WorkspaceStatusGroupProjectionItem(workspaceId: w1, resolution: .ownInEffect(F.parked)),
            WorkspaceStatusGroupProjectionItem(workspaceId: w2, resolution: .ownInEffect(F.next)),
            WorkspaceStatusGroupProjectionItem(workspaceId: w3, resolution: .ownInEffect(F.parked)),
        ]
        let projection = WorkspaceStatusGroupProjection.project(
            workspaces: items,
            list: F.toms,
            resolvedHexByStatusId: resolvedHexByStatusId
        )
        #expect(projection?.group(for: "parked")?.memberWorkspaceIds == [w1, w3])
        #expect(projection?.group(for: "next")?.memberWorkspaceIds == [w2])
    }

    // MARK: - Stored Order Pure Operations

    @Test func defaultOrderIsFileOrder() {
        let order = WorkspaceStatusGroupProjection.orderedStatusIds(entries: F.tomsEntries, storedOrder: nil)
        #expect(order == F.tomsIDs)
    }

    @Test func storedOrderOverridesFileOrder() {
        let reversed = Array(F.tomsIDs.reversed())
        let order = WorkspaceStatusGroupProjection.orderedStatusIds(entries: F.tomsEntries, storedOrder: reversed)
        #expect(order == reversed)
    }

    @Test func statusAddedToFileAfterDragLandsRelativeToFileNeighbours() {
        // Stored drag order: ["parked", "next", "future"]
        // Original file was ["next", "parked", "future"]
        // File adds "upcoming" between "next" and "parked"
        let entries = [F.next, F.upcoming, F.parked, F.future]
        let stored = ["parked", "next", "future"]
        let order = WorkspaceStatusGroupProjection.orderedStatusIds(entries: entries, storedOrder: stored)
        // In file, upcoming is after next. In stored, next is at index 1.
        // Upcoming should land after its predecessor "next".
        #expect(order == ["parked", "next", "upcoming", "future"])
    }

    @Test func fileReorderAfterDragChangesNothing() {
        let stored = ["parked", "next", "done"]
        let reorderedEntries = [F.done, F.parked, F.next]
        let order = WorkspaceStatusGroupProjection.orderedStatusIds(entries: reorderedEntries, storedOrder: stored)
        #expect(order == stored)
    }
}
