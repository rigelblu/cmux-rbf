import CmuxSettings
import Foundation
import SwiftUI
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
        #expect(projection.sections.map(\.title) == ["Backend", "Backend"])
        #expect(projection.sections.map(\.memberWorkspaceIds) == [[tealPinned], [tealUnpinned]])
        #expect(projection.sections.allSatisfy { $0.isCollapsed })
        #expect(projection.sectionByWorkspaceId[uncolored] == nil)
        #expect(projection.sectionByWorkspaceId[realGroupMember] == nil)
    }

    @Test(arguments: [
        (
            entry: WorkspaceColorPaletteEntry(name: "Indigo", hex: "#4F46E5"),
            expectedTitle: "Indigo"
        ),
        (
            entry: WorkspaceColorPaletteEntry(name: "Purple", hex: "#9333EA", label: "Goal: SECONDARY"),
            expectedTitle: "Goal: SECONDARY"
        ),
        (
            entry: WorkspaceColorPaletteEntry(
                name: "custom-1",
                hex: "#112233",
                customDisplayName: "Night Shift"
            ),
            expectedTitle: "Night Shift"
        ),
    ])
    func paletteTitleUsesMeaningThenCustomNameThenRawName(
        entry: WorkspaceColorPaletteEntry,
        expectedTitle: String
    ) throws {
        let workspaceID = UUID()
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: [
                .init(id: workspaceID, groupId: nil, isPinned: false, customColor: entry.hex),
            ],
            paletteEntries: [entry],
            collapsedHexes: []
        )

        #expect(try #require(projection.sections.first).title == expectedTitle)
        #expect(entry.displayName == (entry.label.map { "\($0) (\(entry.customDisplayName ?? entry.name))" }
            ?? entry.customDisplayName
            ?? entry.name))
    }

    @Test func unlistedHexKeepsTheExistingCustomFallback() throws {
        let workspaceID = UUID()
        let projection = SidebarWorkspaceColorSectionProjection.project(
            workspaces: [
                .init(id: workspaceID, groupId: nil, isPinned: false, customColor: "#123456"),
            ],
            paletteEntries: [],
            collapsedHexes: []
        )

        #expect(try #require(projection.sections.first).title == "Custom (#123456)")
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
        let selected = try #require(manager.addTab(select: false))
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
        #expect(projection.sectionByWorkspaceId[pinned]?.title == "Custom (#123456)")
        #expect(projection.sectionByWorkspaceId[other]?.title == "Custom (#654321)")
    }

    @Test func legalReorderPermutesOnlySectionMemberSlots() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let first = try #require(manager.selectedWorkspace)
        let nonmember = try #require(manager.addTab(select: false))
        let second = try #require(manager.addTab(select: false))
        let third = try #require(manager.addTab(select: false))

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
            title: "Backend",
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
        #expect(header.renderedTitle == section.title)
        #expect(header.accessibilityLabel == "Color section, Backend, 1 workspaces, expanded")
        #expect(
            header.headerBand
                == SidebarWorkspaceColorSectionHeaderBand.resolve(
                    normalizedHex: section.id.normalizedHex,
                    colorScheme: .light,
                    contrast: .standard
                )
        )
    }

    @Test func interactiveRowIdsKeepsGroupAnchorsAndDropsOnlyColorSectionDupes() {
        let groupId = UUID()
        let anchor = UUID()
        let member = UUID()
        let colorMember = UUID()
        let loose = UUID()
        let section = SidebarWorkspaceColorSection(
            id: .init(normalizedHex: "#14B8A6", pinTier: .unpinned),
            title: "Backend (Teal)",
            memberWorkspaceIds: [colorMember],
            isCollapsed: false
        )
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: groupId, anchorWorkspaceId: anchor),
            .workspace(workspaceId: member),
            .colorSectionHeader(section: section),
            .workspace(workspaceId: colorMember),
            .workspace(workspaceId: loose),
        ]

        let interactive = SidebarWorkspaceRenderItem.interactiveRowIds(from: items)

        // Regression guard: a real group's anchor must remain a valid
        // drag/reorder target (`#cm-56` silently dropped it while narrowing
        // out the color-section header's duplicate id). `numberedWorkspaceIds`
        // stays `.workspace`-only by design — verify the two never collapse
        // to the same behavior.
        #expect(interactive == [anchor, member, colorMember, loose])
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: items) == [member, colorMember, loose])
        #expect(interactive != SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: items))
    }

    @Test func colorSectionMemberMayOnlyLeaveItsSectionForARealGroup() {
        let group = UUID()

        // The one allowed escape: a group-scoped reorder. `Move to Group` in
        // the context menu performs this same move, so the drag must agree.
        #expect(SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(
            action: .reorder(targetIndex: 2, usesTopLevelRows: false, explicitGroupId: group)
        ))

        // Everything Scenario 4 exercised stays refused here, and so falls
        // through to the same-section rule rather than escaping the section.
        #expect(!SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(
            action: .reorder(targetIndex: 2, usesTopLevelRows: true, explicitGroupId: nil)
        ))
        #expect(!SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(
            action: .crossWindow(insertionIndex: 0, proposedInsertionIndex: 0)
        ))
        #expect(!SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(
            action: .colorSection(
                targetWorkspaceId: UUID(),
                insertBefore: true,
                memberWorkspaceIds: [UUID()]
            )
        ))
    }

    @Test func colorSectionMembersIndentLikeRealGroupMembers() {
        // Dogfood 2026-08-28: a color section read as a flat run because its
        // members sat flush left while a real group's members were inset. Both
        // headers are containers, so both sets of members carry the indent.
        #expect(SidebarWorkspaceColorSectionDropPolicy.indentsUnderHeader(
            isGrouped: false, isColorSectionMember: true
        ))
        #expect(SidebarWorkspaceColorSectionDropPolicy.indentsUnderHeader(
            isGrouped: true, isColorSectionMember: false
        ))
        // A loose, uncolored workspace still hangs at the sidebar's own edge.
        #expect(!SidebarWorkspaceColorSectionDropPolicy.indentsUnderHeader(
            isGrouped: false, isColorSectionMember: false
        ))
    }

    @Test func headerBandMatchesCM49ContainerBandAcrossAppearances() {
        let appearances: [(ColorScheme, ColorSchemeContrast, SidebarGroupHeaderBandPalette.RenderedAppearance)] = [
            (.light, .standard, .aqua),
            (.dark, .standard, .darkAqua),
            (.light, .increased, .highContrastAqua),
            (.dark, .increased, .highContrastDarkAqua),
        ]

        for (colorScheme, contrast, renderedAppearance) in appearances {
            let actual = SidebarWorkspaceColorSectionHeaderBand.resolve(
                normalizedHex: "#14B8A6",
                colorScheme: colorScheme,
                contrast: contrast
            )
            let cm49Band = SidebarGroupHeaderBandPalette(
                tintHex: "#14B8A6",
                isAnchorActive: false,
                isMultiSelected: false,
                multiSelectionBackgroundStyle: .clear,
                renderedAppearance: renderedAppearance
            )

            #expect(actual.bandColor == cm49Band.bandColor)
            #expect(actual.bandOpacity == cm49Band.bandOpacity)
            #expect(actual.primaryTextColor == cm49Band.primaryTextColor)
            #expect(actual.bandOpacity == SidebarGroupHeaderBandPalette.restingBandOpacity)
        }
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
