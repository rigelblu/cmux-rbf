import AppKit
import Foundation
import SwiftUI
import Testing

import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarStatusHeaderCountTests {
    private typealias Sidebar = VerticalTabsSidebar

    private static func environment() -> SidebarWorkspaceTableEnvironmentSnapshot {
        .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: SidebarLazyContractProbe())
    }

    private static func statusModel(
        kind: SidebarStatusHeaderKind = .statusGroup("next"),
        name: String = "Next",
        memberCount: Int,
        isCollapsed: Bool = false,
        unreadCount: Int = 0
    ) -> SidebarGroupHeaderRowModel {
        Sidebar.statusHeaderModel(
            kind: kind,
            presentation: SidebarStatusGroupPresentation(name: name, tintHex: "#2F6FDB", glyph: nil, behavesAs: .todo),
            memberCount: memberCount, unreadCount: unreadCount, isCollapsed: isCollapsed,
            environment: environment(), sidebarFontScale: 1.0
        )
    }

    private static func workspaceGroupModel(memberCount: Int) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(), anchorWorkspaceId: UUID(), name: "Group", iconSymbol: "folder",
            tintHex: nil, customColorHex: nil, isCollapsed: false, isPinned: false, isAnchorActive: false,
            isMultiSelected: false, multiSelectionBackgroundStyle: .clear,
            memberCount: memberCount, anchorUnreadCount: 0, canMarkRead: false, canMarkUnread: true,
            hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: true,
            shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0,
            fontScale: 1, globalFontMagnificationPercent: 100, cwdContextMenuItems: [],
            rowSpacing: 2, isFirstRow: true, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false, colorSchemeIsDark: false
        )
    }

    private static func cell(width: CGFloat = 320, showing model: SidebarGroupHeaderRowModel) -> SidebarGroupHeaderTableCellView {
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        cell.configurePresentation(model: model)
        cell.layoutSubtreeIfNeeded()
        cell.layout()
        return cell
    }

    // MARK: The count rule

    @Test func aStatusWithWorkspacesShowsItsCountAndAnEmptyOneShowsNone() {
        #expect(SidebarStatusHeaderText.statusGroupCountText(memberCount: 3) == "(3)")
        #expect(SidebarStatusHeaderText.statusGroupCountText(memberCount: 1) == "(1)")
        #expect(SidebarStatusHeaderText.statusGroupCountText(memberCount: 0) == nil)
    }

    // MARK: SwiftUI renderer

    @Test func theSwiftUIHeaderCountsANestedGroupsWorkspacesToo() throws {
        let loose = UUID()
        let anchor = UUID()
        let member = UUID()
        var group = WorkspaceGroup(id: UUID(), name: "Nested", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: anchor, customColor: nil, iconSymbol: nil)
        group.statusId = "next"
        let list = WorkspaceStatusList(entries: [.init(id: "next", name: "Next", extends: .todo),
            .init(id: "upcoming", name: "Upcoming", extends: .todo)], source: .file)
        let groups = WorkspaceGroupStatusProjection(groups: [group],
            workspaces: [.init(id: anchor, groupId: group.id, isPinned: false),
                         .init(id: member, groupId: group.id, isPinned: false)],
            list: list)
        let projection = WorkspaceStatusGroupProjection(groups: [
            .init(statusId: "next", memberWorkspaceIds: [loose]),
            .init(statusId: "upcoming", memberWorkspaceIds: []),
        ], workspaceGroups: groups)
        let presentations = [
            "next": SidebarStatusGroupPresentation(name: "Next", tintHex: nil, glyph: nil, behavesAs: .todo),
            "upcoming": SidebarStatusGroupPresentation(name: "Upcoming", tintHex: nil, glyph: nil, behavesAs: .todo),
        ]
        let next = try #require(Sidebar.sidebarStatusGroupHeaderRow(
            statusId: "next", projection: projection, presentations: presentations,
            listWidth: 320, environment: Self.environment(), sidebarFontScale: 1.0))
        #expect(next.memberCount == 3)
        #expect(next.countText == "(3)")
        let upcoming = try #require(Sidebar.sidebarStatusGroupHeaderRow(
            statusId: "upcoming", projection: projection, presentations: presentations,
            listWidth: 320, environment: Self.environment(), sidebarFontScale: 1.0))
        #expect(upcoming.countText == nil)
    }

    /// The x, in points, of the rightmost pixel in the header's middle rows that isn't the band: where its text ends.
    private static func rightmostInkX(_ header: SidebarStatusGroupSwiftUIHeader, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: header.frame(width: width))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let mid = rep.pixelsHigh / 2
        let band = try #require(rep.colorAt(x: rep.pixelsWide - Int(30 * scale), y: mid))
        var rightmost = 0
        for y in (mid - Int(4 * scale))...(mid + Int(4 * scale)) {
            for x in stride(from: rep.pixelsWide - Int(30 * scale), through: 0, by: -1) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(c.redComponent - band.redComponent) + abs(c.greenComponent - band.greenComponent)
                    + abs(c.blueComponent - band.blueComponent)
                if delta > 0.3 { rightmost = max(rightmost, x); break }
            }
        }
        return CGFloat(rightmost) / scale
    }

    @Test func theSwiftUIHeaderDrawsItsCountAfterTheName() throws {
        let presentation = SidebarStatusGroupPresentation(name: "Next", tintHex: "#2F6FDB", glyph: nil, behavesAs: .todo)
        func header(_ count: Int) -> SidebarStatusGroupSwiftUIHeader {
            SidebarStatusGroupSwiftUIHeader(statusId: "next", presentation: presentation, memberCount: count, isCollapsed: false,
                listWidth: 320, colorScheme: .light, fontScale: 1, globalFontMagnificationPercent: 100)
        }
        let withCount = try Self.rightmostInkX(header(3), width: 320)
        let without = try Self.rightmostInkX(header(0), width: 320)
        let countWidth = NSString(string: "(3)").size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        #expect(without > 20)
        #expect(withCount - without > countWidth)
    }

    // MARK: AppKit renderer

    @Test func theAppKitCellShowsTheCountBesideTheBareNameFoldedAndOpen() throws {
        for folded in [false, true] {
            let cell = Self.cell(showing: Self.statusModel(memberCount: 3, isCollapsed: folded))
            #expect(cell.nameTextForTesting == "Next")
            #expect(!cell.countFieldForTesting.isHidden)
            #expect(cell.countFieldForTesting.stringValue == "(3)")
            let nameEnd = cell.nameFieldFrameForTesting.minX
                + ceil(NSString(string: "Next").size(withAttributes: [.font: try #require(cell.nameFontForTesting)]).width)
            #expect(abs(cell.countFieldForTesting.frame.minX - nameEnd - 4) <= 1)
        }
    }

    @Test func anEmptyStatusAndTheSectionHeadersShowNoCount() {
        #expect(Self.cell(showing: Self.statusModel(memberCount: 0)).countFieldForTesting.isHidden)
        let pinned = Self.statusModel(kind: .pinnedArea, name: "Pinned", memberCount: 4)
        #expect(Self.cell(showing: pinned).countFieldForTesting.isHidden)
        let area = Self.statusModel(kind: .statusesArea, name: "Workblocks", memberCount: 4)
        #expect(Self.cell(showing: area).countFieldForTesting.isHidden)
    }

    @Test func aReusedCellShowingAWorkspaceGroupDropsTheStatusCount() {
        let cell = Self.cell(showing: Self.statusModel(memberCount: 3))
        #expect(!cell.countFieldForTesting.isHidden)
        cell.configurePresentation(model: Self.workspaceGroupModel(memberCount: 4))
        cell.layout()
        #expect(cell.countFieldForTesting.isHidden)
        #expect(cell.countFieldForTesting.frame.width == 0)
    }

    @Test func aLongNameTruncatesAndKeepsTheWholeCountBeforeTheUnreadBadge() throws {
        let name = "Working (autonomously)"
        let cell = Self.cell(width: 220, showing: Self.statusModel(
            name: name, memberCount: 12, isCollapsed: true, unreadCount: 2))
        let font = try #require(cell.nameFontForTesting)
        let countWidth = ceil(NSString(string: "(12)").size(withAttributes: [.font: font]).width)
        let nameWidth = ceil(NSString(string: name).size(withAttributes: [.font: font]).width)
        let count = cell.countFieldForTesting.frame
        #expect(!cell.countFieldForTesting.isHidden)
        #expect(count.width >= countWidth)
        let contentMaxX = cell.bandFrameForTesting.maxX - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        #expect(count.maxX <= contentMaxX)
        #expect(cell.unreadBadgeViewForTesting.frame.maxX <= contentMaxX)
        #expect(abs(cell.unreadBadgeViewForTesting.frame.maxX - contentMaxX) <= 1) // a status header never reveals its +, so a truncated name uses that room
        #expect(cell.nameFieldFrameForTesting.width < nameWidth)
        #expect(cell.unreadBadgeViewForTesting.frame.minX >= count.maxX)
    }

    @Test func voiceOverStillReadsTheCountOnceFromTheLabel() {
        let cell = Self.cell(showing: Self.statusModel(memberCount: 3))
        #expect(cell.accessibilityLabel() == "Status group, Next, 3 workspaces, expanded")
    }
}
