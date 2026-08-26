import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarWorkspaceColorSectionProjectionTests {
    @Test func groupsOnlyEligibleWorkspacesByNormalizedColorAndPinTier() {
        let tealPinned = UUID()
        let tealUnpinned = UUID()
        let uncolored = UUID()
        let realGroupMember = UUID()
        let realGroupId = UUID()
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: [
                .init(id: tealPinned, groupId: nil, isPinned: true, customColor: "#14b8a6"),
                .init(id: uncolored, groupId: nil, isPinned: false, customColor: nil),
                .init(id: tealUnpinned, groupId: nil, isPinned: false, customColor: "14B8A6"),
                .init(id: realGroupMember, groupId: realGroupId, isPinned: false, customColor: "#14B8A6"),
            ],
            paletteEntries: [
                WorkspaceColorPaletteEntry(name: "Teal", hex: "#14B8A6", label: "Backend"),
            ],
            collapsedHexes: ["#14B8A6"]
        )

        #expect(projection.sections.map(\.id) == [
            .init(normalizedHex: "#14B8A6", pinTier: .pinned),
            .init(normalizedHex: "#14B8A6", pinTier: .unpinned),
        ])
        #expect(projection.sections.map(\.title) == ["Backend (Teal)", "Backend (Teal)"])
        #expect(projection.sections.map(\.memberWorkspaceIds) == [[tealPinned], [tealUnpinned]])
        #expect(projection.sections.allSatisfy { $0.isCollapsed })
        #expect(projection.sectionByWorkspaceId[uncolored] == nil)
        #expect(projection.sectionByWorkspaceId[realGroupMember] == nil)
    }

    @Test func projectsHeadersAtFirstMemberAndPreservesAllOtherRows() {
        let first = UUID(), middle = UUID(), second = UUID(), plain = UUID()
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: [
                .init(id: first, groupId: nil, isPinned: false, customColor: "#112233"),
                .init(id: middle, groupId: nil, isPinned: false, customColor: nil),
                .init(id: second, groupId: nil, isPinned: false, customColor: "112233"),
                .init(id: plain, groupId: nil, isPinned: false, customColor: nil),
            ],
            paletteEntries: [
                .init(name: "First", hex: "#112233"),
                .init(name: "Duplicate", hex: "112233"),
            ],
            collapsedHexes: []
        )
        let items = projection.applying(to: [first, middle, second, plain].map {
            .workspace(workspaceId: $0)
        })
        #expect(items.count == 5)
        guard case .colorSectionHeader(let header) = items[0] else {
            Issue.record("Expected a generated section header")
            return
        }
        #expect(header.title == "First")
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: items) == [first, second, middle, plain])
    }
}

@MainActor
@Suite struct SidebarWorkspaceColorSectionPersistenceTests {
    @Test func oldAndMalformedSnapshotsDefaultExpandedWhileKeysNormalize() throws {
        let old = #"{"isVisible":true,"selection":"tabs","width":220}"#.data(using: .utf8)!
        let malformed = #"{"isVisible":true,"selection":"tabs","width":220,"colorSectionCollapsedHexes":"bad"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(SessionSidebarSnapshot.self, from: old).colorSectionCollapsedHexes == nil)
        #expect(try JSONDecoder().decode(SessionSidebarSnapshot.self, from: malformed).colorSectionCollapsedHexes == nil)

        let state = SidebarState(collapsedColorSectionHexes: ["aabbcc", "invalid"])
        #expect(state.collapsedColorSectionHexes == ["#AABBCC"])

        let snapshot = SessionSidebarSnapshot(
            isVisible: true,
            selection: .tabs,
            width: 220,
            colorSectionCollapsedHexes: state.collapsedColorSectionHexes.sorted()
        )
        let roundTrip = try JSONDecoder().decode(
            SessionSidebarSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(roundTrip.colorSectionCollapsedHexes == ["#AABBCC"])
    }
}

@MainActor
@Suite struct SidebarWorkspaceColorSectionSelectionTests {
    @Test func revealExpandsEveryPinTierSharingTheHex() {
        let state = SidebarState(collapsedColorSectionHexes: ["#ABCDEF"])
        state.expandColorSection(hex: "abcdef")
        #expect(state.collapsedColorSectionHexes.isEmpty)
    }

    @Test func everySelectedWorkspaceChangeUsesTheSharedRevealHook() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selected = manager.addTab(select: false)
        selected.customColor = "#ABCDEF"
        let state = SidebarState(collapsedColorSectionHexes: ["#ABCDEF"])
        manager.revealSelectedWorkspaceInSidebar = { workspace in
            state.expandColorSection(containing: workspace)
        }

        manager.selectedTabId = selected.id

        #expect(state.collapsedColorSectionHexes.isEmpty)
    }
}

@MainActor
@Suite struct SidebarWorkspaceColorSectionDragTests {
    @Test func sectionMembershipIsExactAcrossColorAndPinTier() {
        let pinned = UUID(), unpinned = UUID(), other = UUID()
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: [
                .init(id: pinned, groupId: nil, isPinned: true, customColor: "#123456"),
                .init(id: unpinned, groupId: nil, isPinned: false, customColor: "#123456"),
                .init(id: other, groupId: nil, isPinned: false, customColor: "#654321"),
            ],
            paletteEntries: [],
            collapsedHexes: []
        )
        #expect(projection.sectionByWorkspaceId[pinned]?.memberWorkspaceIds == [pinned])
        #expect(projection.sectionByWorkspaceId[unpinned]?.memberWorkspaceIds == [unpinned])
        #expect(projection.sectionByWorkspaceId[other]?.id != projection.sectionByWorkspaceId[unpinned]?.id)
    }

    @Test func legalReorderPermutesOnlySectionMemberSlots() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let first = try #require(manager.selectedWorkspace)
        let nonmember = manager.addTab(select: false)
        let second = manager.addTab(select: false)
        let third = manager.addTab(select: false)

        #expect(manager.reorderWorkspace(tabId: nonmember.id, after: first.id))

        first.customColor = "#123456"
        second.customColor = "#123456"
        third.customColor = "#123456"
        #expect(manager.reorderWorkspaceWithinColorSection(
            tabId: second.id,
            targetWorkspaceId: first.id,
            insertBefore: true,
            memberWorkspaceIds: [first.id, third.id, second.id]
        ))
        #expect(manager.tabs.map(\.id) == [second.id, nonmember.id, first.id, third.id])

        third.isPinned = true
        #expect(!manager.reorderWorkspaceWithinColorSection(
            tabId: first.id,
            targetWorkspaceId: third.id,
            insertBefore: true,
            memberWorkspaceIds: [second.id, first.id, third.id]
        ))
    }
}

@MainActor
@Suite struct SidebarWorkspaceColorSectionRendererTests {
    @Test func headerCarriesOnlyPassiveSectionMetadata() {
        let member = UUID()
        let section = SidebarWorkspaceColorSection(
            id: .init(normalizedHex: "#14B8A6", pinTier: .unpinned),
            title: "Backend (Teal)",
            memberWorkspaceIds: [member],
            isCollapsed: false
        )
        let item = SidebarWorkspaceRenderItem.colorSectionHeader(section: section)
        #expect(item.id == .colorSection(section.id))
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: [item]).isEmpty)
        let header = SidebarWorkspaceColorSectionHeader(
            section: section,
            colorScheme: .light,
            onToggle: {}
        )
        #expect(header.accessibilityLabel == "Color section, Backend (Teal), 1 workspaces, expanded")
    }
}

@MainActor
@Suite struct SidebarWorkspaceColorSectionProjectionComplexityTests {
    @Test func projectsLargeInputInOneStableSourceOrder() {
        let ids = (0..<1_000).map { _ in UUID() }
        let snapshots = ids.enumerated().map { index, id in
            SidebarWorkspaceColorSectionWorkspaceSnapshot(
                id: id,
                groupId: nil,
                isPinned: index < 300,
                customColor: String(format: "#%06X", index % 32)
            )
        }
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: snapshots,
            paletteEntries: [],
            collapsedHexes: []
        )
        #expect(projection.sections.count == 64)
        #expect(projection.sectionByWorkspaceId.count == 1_000)
        #expect(projection.sections.flatMap(\.memberWorkspaceIds).count == 1_000)
        #expect(projection.diagnostics == .init(
            paletteEntryVisitCount: 0,
            workspaceVisitCount: 1_000
        ))
    }
}
