import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// (#cm-110.5) A tab dropped on the line between two sidebar rows makes its workspace where a workspace dragged from elsewhere to that line would land, found by the workspaces beside the line and never by a count of rows.
// 10_expected-results.md, cm-110.10: "the new workspace lands at the place in the tab order a workspace from elsewhere dropped at that spot would take, never at the count of visible rows above the pointer"; below every row, "the new workspace is loose at the end of the sidebar".
@MainActor
@Suite("A tab dropped between sidebar rows", .serialized)
struct SidebarNewWorkspaceTabIndexTests {
    private enum Spec {
        /// `folded` names the workspaces a folded header hides; they are in the tab order and have no row.
        case header(SidebarStatusHeaderKind, folded: [String] = [])
        /// The group's header row stands for its anchor workspace `name`, which has its own slot in the tab order. `folded` names the members a folded group hides.
        case groupHeader(String, pinned: Bool, folded: [String] = [], pinnedByGroup: Bool = false)
        /// A group with no workspace at all: its header row is not in the tab order.
        case emptyGroupHeader(pinned: Bool)
        case colorSectionHeader
        /// `pinnedByGroup`: a pinned group holds the row, so it is in the pinned run without being pinned itself.
        case tab(String, pinned: Bool, pinnedByGroup: Bool = false)
    }

    private struct Dropped: Equatable {
        let index: Int?
        let into: UUID?
        let line: SidebarDropIndicator?
    }

    private struct Band: View, Equatable { var body: some View { Color.gray.frame(height: 28) } }

    /// The real AppKit table and its real bonsplit drop view, with a spy where the app moves the tab into a new workspace.
    @MainActor private final class Scene {
        let controller = SidebarWorkspaceTableController()
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        var tabIds: [String: UUID] = [:]
        var rowIds: [Int: UUID] = [:]
        var tabNames: [String] = []
        var newWorkspaceIndexes: [Int] = []

        /// `tabOrder` names every workspace in the tab order, hidden ones too; by default the order of the rows, each folded header's hidden members right after it.
        init(_ rows: [Spec], tabOrder: [String]? = nil) async {
            container = controller.makeContainerView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 1400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init())
            func id(_ name: String) -> UUID {
                if let known = tabIds[name] { return known }
                let made = UUID(); tabIds[name] = made; tabNames.append(name); return made
            }
            var configurations: [SidebarWorkspaceTableRowConfiguration] = []
            for (position, spec) in rows.enumerated() {
                switch spec {
                case .header(let kind, let folded):
                    let hidden = folded.map(id)
                    var folds = WorkspaceStatusGroupsState()
                    if !hidden.isEmpty {
                        switch kind {
                        case .pinnedArea: folds.pinnedCollapsed = true
                        case .workspacesArea: folds.workspacesCollapsed = true
                        case .statusesArea: folds.areaCollapsed = true
                        case .statusGroup(let statusId): folds.collapsedStatusIds.insert(statusId)
                        }
                    }
                    configurations.append(VerticalTabsSidebar.statusHeaderConfiguration(kind: kind, presentation: nil, memberCount: hidden.count, memberIds: Set(hidden),
                        folds: folds, environment: environment, onToggle: {}))
                case .groupHeader(let name, let pinned, let folded, let pinnedByGroup):
                    let anchorId = id(name), hidden = folded.map(id)
                    let group = WorkspaceGroup(id: UUID(), name: name, isCollapsed: !hidden.isEmpty, isPinned: pinned, anchorWorkspaceId: anchorId, customColor: nil, iconSymbol: nil)
                    var row = SidebarWorkspaceTableRowConfiguration(id: .group(group.id), workspaceId: anchorId, groupId: group.id, isGroupHeader: true, isPinned: pinned,
                        environment: environment, equivalenceValue: Band(), makeContent: { _, _ in AnyView(Band()) })
                    row.isPinnedByGroup = pinnedByGroup
                    row.dropTabIds = VerticalTabsSidebar.groupDropTabIds(group: group, tabIds: [anchorId] + hidden,
                        groupIdByWorkspaceId: Dictionary(uniqueKeysWithValues: ([anchorId] + hidden).map { ($0, Optional(group.id)) }), groupsById: [group.id: group])
                    configurations.append(row)
                case .emptyGroupHeader(let pinned):
                    let group = WorkspaceGroup(id: UUID(), name: "E", isCollapsed: false, isPinned: pinned, anchor: .empty(UUID()), customColor: nil, iconSymbol: nil)
                    var row = SidebarWorkspaceTableRowConfiguration(id: .group(group.id), workspaceId: group.anchorWorkspaceId, groupId: group.id, isGroupHeader: true, isPinned: pinned,
                        environment: environment, equivalenceValue: Band(), makeContent: { _, _ in AnyView(Band()) })
                    row.dropTabIds = VerticalTabsSidebar.groupDropTabIds(group: group, tabIds: [], groupIdByWorkspaceId: [:], groupsById: [group.id: group])
                    configurations.append(row)
                case .colorSectionHeader:
                    configurations.append(.init(id: .colorSection(SidebarWorkspaceColorSectionID(normalizedHex: "#119933", pinTier: .unpinned)), workspaceId: UUID(),
                        groupId: nil, isGroupHeader: false, isPinned: false, colorSectionToggle: {}, environment: environment,
                        equivalenceValue: Band(), makeContent: { _, _ in AnyView(Band()) }))
                case .tab(let name, let pinned, let pinnedByGroup):
                    let tabId = id(name)
                    var row = SidebarWorkspaceTableRowConfiguration(id: .workspace(tabId), workspaceId: tabId, groupId: nil, isGroupHeader: false, isPinned: pinned,
                        environment: environment, equivalenceValue: Band(), makeContent: { _, _ in AnyView(Band()) })
                    row.isPinnedByGroup = pinnedByGroup
                    configurations.append(row)
                }
                rowIds[position] = configurations[position].workspaceId
            }
            if let tabOrder { tabNames = tabOrder }
            let actions = SidebarWorkspaceTableActions(attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
                beginWorkspaceDrag: { _ in }, movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
                updateWorkspaceDrag: { _, _, _ in nil }, performWorkspaceDrop: { _, _, _ in false }, commitWorkspaceDropPlan: { _ in false },
                clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil }, currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in true },
                moveBonsplitToExistingWorkspace: { _, _ in true },
                moveBonsplitToNewWorkspace: { [unowned self] index, _ in newWorkspaceIndexes.append(index); return UUID() },
                didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in })
            container.tableView.intercellSpacing = NSSize(width: 0, height: 2)
            controller.apply(rows: configurations, actions: actions, workspaceIds: tabNames.compactMap { tabIds[$0] }, selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
            await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
            container.layoutSubtreeIfNeeded(); container.tableView.layoutSubtreeIfNeeded()
        }

        func close() {
            controller.dismantleContainerView(container)
            window.contentView = nil; window.close()
        }

        /// Drops a tab at `fraction` down row number `position`, through the drop view; returns the new-workspace index the app was asked for.
        func drop(onRow position: Int, fraction: CGFloat) throws -> Dropped {
            let view = container.bonsplitDropView
            var into: UUID?
            view.performExistingWorkspaceMove = { id, _ in into = id; return true }
            view.setWorkspaceDropTargetCollectionActive(true)
            defer { view.setWorkspaceDropTargetCollectionActive(false) }
            let id = try #require(rowIds[position])
            let target = try #require(controller.refreshReorderDropTargets(includeHeaders: true).first { $0.workspaceId == id })
            let point = CGPoint(x: 60, y: target.frame.minY + target.frame.height * fraction)
            let before = newWorkspaceIndexes.count
            let result = view.debugDrop(point: view.convert(point, from: container.reorderDropView),
                transfer: BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID()))
            try #require(result.performed)
            return Dropped(index: newWorkspaceIndexes.count > before ? newWorkspaceIndexes.last : nil, into: into, line: result.indicator)
        }

        /// Drops a tab at `fraction` down row number `position` and reports whether the drop was refused: nothing accepted, no line, no workspace made.
        func refusal(onRow position: Int, fraction: CGFloat) throws -> (refused: Bool, line: SidebarDropIndicator?) {
            let view = container.bonsplitDropView
            view.performExistingWorkspaceMove = { _, _ in true }
            view.setWorkspaceDropTargetCollectionActive(true)
            defer { view.setWorkspaceDropTargetCollectionActive(false) }
            let id = try #require(rowIds[position])
            let target = try #require(controller.refreshReorderDropTargets(includeHeaders: true).first { $0.workspaceId == id })
            let before = newWorkspaceIndexes.count
            let result = view.debugDrop(point: view.convert(CGPoint(x: 60, y: target.frame.minY + target.frame.height * fraction), from: container.reorderDropView),
                transfer: BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID()))
            return (!result.accepted && !result.performed && result.indicator == nil && newWorkspaceIndexes.count == before, result.indicator)
        }

        /// Drops a tab above the first row, outside every row.
        func dropAboveEverything() throws -> Dropped {
            let view = container.bonsplitDropView
            view.setWorkspaceDropTargetCollectionActive(true)
            defer { view.setWorkspaceDropTargetCollectionActive(false) }
            let top = try #require(controller.refreshReorderDropTargets(includeHeaders: true).map { $0.frame.minY }.min())
            let before = newWorkspaceIndexes.count
            let result = view.debugDrop(point: view.convert(CGPoint(x: 60, y: top - 5), from: container.reorderDropView),
                transfer: BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID()))
            try #require(result.performed)
            return Dropped(index: newWorkspaceIndexes.count > before ? newWorkspaceIndexes.last : nil, into: nil, line: result.indicator)
        }

        /// Below every row: the tab goes last.
        func dropBelowEverything() throws -> Dropped {
            let view = container.bonsplitDropView
            view.setWorkspaceDropTargetCollectionActive(true)
            defer { view.setWorkspaceDropTargetCollectionActive(false) }
            let bottom = try #require(controller.refreshReorderDropTargets(includeHeaders: true).map { $0.frame.maxY }.max())
            let before = newWorkspaceIndexes.count
            let result = view.debugDrop(point: view.convert(CGPoint(x: 60, y: bottom + 20), from: container.reorderDropView),
                transfer: BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID()))
            try #require(result.performed)
            return Dropped(index: newWorkspaceIndexes.count > before ? newWorkspaceIndexes.last : nil, into: nil, line: result.indicator)
        }
    }

    private static let topEdge: CGFloat = 0.02
    private static let bottomEdge: CGFloat = 0.98
    private static let pinnedWorkspacesStatuses: [Spec] = [
        .header(.pinnedArea), .tab("K1", pinned: true), .tab("K2", pinned: true),
        .header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false), .tab("L3", pinned: false), .tab("L4", pinned: false),
        .header(.statusesArea),
    ]

    @Test func underAPinnedHeaderAndAWorkspacesHeaderTheLineAboveARowIsThatRowsTabPosition() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            // Rows: 0 Pinned, 1 K1, 2 K2, 3 Workspaces, 4 L1, 5 L2, 6 L3, 7 L4, 8 Statuses. Tabs: K1 K2 L1 L2 L3 L4.
            let l3 = try s.drop(onRow: 6, fraction: Self.topEdge)
            #expect(l3.index == 4, "The line above L3 is tab position 4, not row position 6; got \(String(describing: l3.index))")
            #expect(l3.line == SidebarDropIndicator(tabId: s.tabIds["L3"], edge: .top), "The drawn line stays above L3")
            let l1 = try s.drop(onRow: 4, fraction: Self.topEdge)
            #expect(l1.index == 2, "The line right under the Workspaces header is after both pins; got \(String(describing: l1.index))")
            #expect(l1.line == SidebarDropIndicator(tabId: s.tabIds["L1"], edge: .top))
        }
    }

    @Test func theLineUnderTheLastWorkspaceIsThePositionAfterIt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            let statuses = try s.drop(onRow: 7, fraction: Self.bottomEdge)
            #expect(statuses.index == 6, "The line above the Statuses header, under L4, is tab position 6; got \(String(describing: statuses.index))")
            #expect(statuses.line == SidebarDropIndicator(tabId: s.rowIds[8], edge: .top))
        }
    }

    @Test func theLineUnderThePinsStaysBelowThem() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            let workspaces = try s.drop(onRow: 2, fraction: Self.bottomEdge)
            #expect(workspaces.index == 2, "A new workspace never lands among the pins; got \(String(describing: workspaces.index))")
        }
    }

    @Test func aLineAmongThePinsMakesTheWorkspaceAfterThem() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            for position in [1, 2] {
                let among = try s.drop(onRow: position, fraction: Self.topEdge)
                #expect(among.index == 2, "A new workspace never lands among the pins (row \(position)); got \(String(describing: among.index))")
                #expect(among.line == SidebarDropIndicator(tabId: s.rowIds[3], edge: .top), "The line is drawn where the workspace lands, above the Workspaces header")
            }
        }
    }

    @Test func withoutPinsOnlyTheWorkspacesHeaderIsSkipped() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene([.header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false), .tab("L3", pinned: false), .tab("L4", pinned: false)])
            defer { s.close() }
            let l3 = try s.drop(onRow: 3, fraction: Self.topEdge)
            #expect(l3.index == 2, "The line above L3 is tab position 2; got \(String(describing: l3.index))")
        }
    }

    @Test func withNoHeadersTheRowPositionIsTheTabPosition() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene([.tab("K1", pinned: true), .tab("K2", pinned: true), .tab("L1", pinned: false), .tab("L2", pinned: false), .tab("L3", pinned: false)])
            defer { s.close() }
            let l3 = try s.drop(onRow: 4, fraction: Self.topEdge)
            #expect(l3.index == 4)
            let l1 = try s.drop(onRow: 2, fraction: Self.topEdge)
            #expect(l1.index == 2)
        }
    }

    /// A group's header row stands for the group's anchor workspace, which has its own slot in the tab order (measured live, `round4-grouphdr-*.json`).
    // Not a claim that this is right: a tab let go between an unpinned group's member rows makes a loose workspace inside the group's run of tabs and splits the group. Upstream does the same, so it is not a regression from .5; it is an open slice on the board. The expectations below record what happens today.
    @Test func aWorkspaceGroupsHeaderIsItsAnchorsTabPosition() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: G header (the anchor), g1, g2, L1. Tabs: anchor, g1, g2, L1.
            let s = await Scene([.groupHeader("G", pinned: false), .tab("g1", pinned: false), .tab("g2", pinned: false), .tab("L1", pinned: false)])
            defer { s.close() }
            let g1 = try s.drop(onRow: 1, fraction: Self.topEdge)
            #expect(g1.index == 1, "The line under the group's header is after the anchor's slot; got \(String(describing: g1.index))")
            let g2 = try s.drop(onRow: 2, fraction: Self.topEdge)
            #expect(g2.index == 2, "got \(String(describing: g2.index))")
            let l1 = try s.drop(onRow: 3, fraction: Self.topEdge)
            #expect(l1.index == 3, "The line under the last member counts the anchor too; got \(String(describing: l1.index))")
        }
    }

    @Test func aPinnedEmptyGroupsHeaderKeepsTheNewWorkspaceBelowIt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: pinned empty group E (its anchor is tab 0), L1, L2.
            let s = await Scene([.groupHeader("E", pinned: true), .tab("L1", pinned: false), .tab("L2", pinned: false)])
            defer { s.close() }
            let above = try s.drop(onRow: 0, fraction: Self.topEdge)
            #expect(above.index == 1 && above.line == SidebarDropIndicator(tabId: s.tabIds["L1"], edge: .top), "Above a pinned group goes below it; got \(String(describing: above.index))")
            let below = try s.drop(onRow: 1, fraction: Self.topEdge)
            #expect(below.index == 1, "got \(String(describing: below.index))")
        }
    }

    @Test func aColorSectionsHeaderIsNotATabPosition() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene([.colorSectionHeader, .tab("c1", pinned: false), .tab("c2", pinned: false), .tab("L1", pinned: false)])
            defer { s.close() }
            let l1 = try s.drop(onRow: 3, fraction: Self.topEdge)
            #expect(l1.index == 2, "The color section's header row is not a tab; got \(String(describing: l1.index))")
        }
    }

    @Test func belowEveryRowTheTabGoesLast() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            let below = try s.dropBelowEverything()
            #expect(below.index == 6, "Past the Statuses header every tab is above; got \(String(describing: below.index))")
        }
    }

    // 02_decisions 2026-10-25 ruling (19): "A tab dropped on a section header row (`Pinned`, `Workspaces` or `Statuses`, including the line drawn on that header's top edge) is refused, with no line"
    @Test func theMiddleOfASectionHeaderIsRefused() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedWorkspacesStatuses); defer { s.close() }
            for position in [0, 3, 8] {
                let middle = try s.refusal(onRow: position, fraction: 0.5)
                #expect(middle.refused, "The middle of header row \(position) is refused: no plan, no line, no workspace (line \(String(describing: middle.line)))")
            }
        }
    }

    // MARK: Rows are not tabs

    private static let workspacesFirstWithStatusBetween: [Spec] = [
        .header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false),
        .header(.statusesArea), .header(.statusGroup("parked")), .tab("P1", pinned: false),
    ]
    private static let statusesFirstWithStatusBetween: [Spec] = [
        .header(.statusesArea), .header(.statusGroup("parked")), .tab("P1", pinned: false),
        .header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false),
    ]
    /// The status group's member P1 sits between the loose rows in the tab order, as it does by default.
    private static let statusBetweenTabs = ["L1", "P1", "L2"]

    // 10_expected-results.md, cm-110.10: "never at the count of visible rows above the pointer"
    @Test func aStatusGroupBetweenLooseRowsInTheTabOrderDoesNotShiftALineWhenWorkspacesComeFirst() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.workspacesFirstWithStatusBetween, tabOrder: Self.statusBetweenTabs); defer { s.close() }
            // Rows: 0 Workspaces, 1 L1, 2 L2, 3 Statuses, 4 Parked, 5 P1. Tabs: L1 P1 L2.
            let aboveL2 = try s.drop(onRow: 2, fraction: Self.topEdge)
            #expect(aboveL2.index == 2, "The line above L2 is before L2 (tab position 2), not after the one tab row above it (1); got \(String(describing: aboveL2.index))")
            let belowL2 = try s.drop(onRow: 2, fraction: Self.bottomEdge)
            #expect(belowL2.index == 3, "The line under L2 is after L2 (3), not after the two tab rows above it (2); got \(String(describing: belowL2.index))")
            let aboveL1 = try s.drop(onRow: 1, fraction: Self.topEdge)
            #expect(aboveL1.index == 0, "The line above L1 is before L1; got \(String(describing: aboveL1.index))")
        }
    }

    @Test func aStatusGroupBetweenLooseRowsInTheTabOrderDoesNotShiftALineWhenStatusesComeFirst() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.statusesFirstWithStatusBetween, tabOrder: Self.statusBetweenTabs); defer { s.close() }
            // Rows: 0 Statuses, 1 Parked, 2 P1, 3 Workspaces, 4 L1, 5 L2. Tabs: L1 P1 L2.
            let aboveL1 = try s.drop(onRow: 4, fraction: Self.topEdge)
            #expect(aboveL1.index == 0, "The line above L1 is before L1, not after the tab row P1 above it (1); got \(String(describing: aboveL1.index))")
            let aboveL2 = try s.drop(onRow: 5, fraction: Self.topEdge)
            #expect(aboveL2.index == 2, "got \(String(describing: aboveL2.index))")
            let below = try s.dropBelowEverything()
            #expect(below.index == 3, "got \(String(describing: below.index))")
        }
    }

    // 10_expected-results.md, cm-110.10: below every row, "the new workspace is loose at the end of the sidebar"
    @Test func belowEveryRowTheTabGoesLastWhateverIsFolded() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let cases: [(String, [Spec], [String])] = [
                ("Pinned folded", [.header(.pinnedArea, folded: ["K1", "K2"]), .header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false), .header(.statusesArea)], ["K1", "K2", "L1", "L2"]),
                ("Workspaces folded", [.header(.pinnedArea), .tab("K1", pinned: true), .tab("K2", pinned: true), .header(.workspacesArea, folded: ["L1", "L2"]), .header(.statusesArea)], ["K1", "K2", "L1", "L2"]),
                ("a workspace group folded", [.groupHeader("G", pinned: false, folded: ["g1", "g2"]), .tab("L1", pinned: false)], ["G", "g1", "g2", "L1"]),
                ("a status group folded", [.header(.workspacesArea), .tab("L1", pinned: false), .header(.statusesArea), .header(.statusGroup("parked"), folded: ["P1", "P2"])], ["L1", "P1", "P2"]),
            ]
            for (name, rows, tabs) in cases {
                let s = await Scene(rows, tabOrder: tabs); defer { s.close() }
                let below = try s.dropBelowEverything()
                #expect(below.index == tabs.count, "\(name): the tab goes last (\(tabs.count)); got \(String(describing: below.index))")
            }
        }
    }

    @Test func aLineBesideAFoldedGroupGoesBeforeItsFirstOrAfterItsLastHiddenMember() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: 0 group G (anchor G, folded: g1 g2), 1 Statuses, 2 Parked, 3 P1. Tabs: P1 G g1 g2, so the next tab row after the group (P1) is not next to it in the tab order.
            let s = await Scene([.groupHeader("G", pinned: false, folded: ["g1", "g2"]), .header(.statusesArea), .header(.statusGroup("parked")), .tab("P1", pinned: false)],
                tabOrder: ["P1", "G", "g1", "g2"])
            defer { s.close() }
            let above = try s.drop(onRow: 0, fraction: Self.topEdge)
            #expect(above.index == 1, "The line above a folded group is before its first hidden tab, its anchor (1), not its last (3); got \(String(describing: above.index))")
            let under = try s.drop(onRow: 0, fraction: Self.bottomEdge)
            #expect(under.index == 4, "The line under a folded group is after its last member (4), not before the next tab row (0); got \(String(describing: under.index))")
        }
    }

    @Test func aLineAboveAFoldedSectionGoesBeforeItsFirstHiddenMember() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: 0 Statuses, 1 Parked, 2 P1, 3 Workspaces (folded: L1 L2). Tabs: L1 P1 L2. The line under P1 is above the folded Workspaces header.
            let s = await Scene([.header(.statusesArea), .header(.statusGroup("parked")), .tab("P1", pinned: false), .header(.workspacesArea, folded: ["L1", "L2"])],
                tabOrder: ["L1", "P1", "L2"])
            defer { s.close() }
            let above = try s.drop(onRow: 2, fraction: Self.bottomEdge)
            #expect(above.index == 0, "Above a folded header is before its first hidden member (0), not after P1 (2); got \(String(describing: above.index))")
        }
    }

    // A rebuilt row (an unread repaint, or the retained hidden presentation) keeps the workspaces it stands for.
    @Test func aRowRebuiltForUnreadOrKeptHiddenKeepsTheWorkspacesItStandsFor() {
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init())
        let model = VerticalTabsSidebar.statusHeaderModel(kind: .statusGroup("parked"),
            presentation: SidebarStatusGroupPresentation(name: "Parked", tintHex: "#6B7280", glyph: .symbol("archivebox"), behavesAs: .todo),
            memberCount: 2, unreadCount: 0, isCollapsed: true, environment: environment)
        let hidden = [UUID(), UUID()]
        func changed(_ snapshot: SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel { var next = model; next.anchorUnreadCount = 3; return next }
        var statusHeader = SidebarWorkspaceTableRowConfiguration(statusHeaderModel: model, statusHeaderKind: .statusGroup("parked"),
            actions: VerticalTabsSidebar.statusHeaderActions(), environment: environment, unreadDependencyWorkspaceIds: Set(hidden), unreadRebuild: changed)
        statusHeader.dropTabIds = hidden
        let repainted = statusHeader.applyingUnreadSnapshot(SidebarUnreadSnapshot())
        #expect(repainted.appKitGroupHeaderModel?.anchorUnreadCount == 3, "The repaint rebuilt the row")
        #expect(repainted.dropTabIds == hidden, "A status header rebuilt for unread keeps its hidden members")
        var groupHeader = SidebarWorkspaceTableRowConfiguration(groupHeaderModel: model, actions: VerticalTabsSidebar.statusHeaderActions(),
            environment: environment, unreadDependencyWorkspaceIds: Set(hidden), unreadRebuild: changed)
        groupHeader.dropTabIds = hidden
        groupHeader.isPinnedByGroup = true
        let repaintedGroup = groupHeader.applyingUnreadSnapshot(SidebarUnreadSnapshot())
        #expect(repaintedGroup.appKitGroupHeaderModel?.anchorUnreadCount == 3, "The repaint rebuilt the row")
        #expect(repaintedGroup.dropTabIds == hidden, "A group header rebuilt for unread keeps its hidden members")
        #expect(repaintedGroup.isPinnedByGroup, "...and that a pinned group holds it")
        #expect(statusHeader.presentationSnapshot().dropTabIds == hidden, "The retained hidden presentation keeps them too")
    }

    // 10_expected-results.md, cm-110.10: "never at the count of visible rows above the pointer"; a pinned workspace group is pinned
    @Test func withPinnedFoldedAndAPinnedGroupTheTabNeverLandsBeforeOrInsideIt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: 0 Pinned (folded: group G, g1, g2), 1 Workspaces, 2 L1, 3 Statuses. Tabs: G g1 g2 L1.
            let s = await Scene([.header(.pinnedArea, folded: ["G", "g1", "g2"]), .header(.workspacesArea), .tab("L1", pinned: false), .header(.statusesArea)],
                tabOrder: ["G", "g1", "g2", "L1"])
            defer { s.close() }
            let aboveEverything = try s.dropAboveEverything()
            #expect(aboveEverything.index == 3, "Above every row: after the whole pinned group (3), never before its anchor (0); got \(String(describing: aboveEverything.index))")
            let aboveL1 = try s.drop(onRow: 2, fraction: Self.topEdge)
            #expect(aboveL1.index == 3, "Above L1: after the whole pinned group (3); got \(String(describing: aboveL1.index))")
        }
    }

    @Test func aGroupWithNoWorkspaceAtAllIsNotATabPosition() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: 0 empty group E (no anchor workspace), 1 L1, 2 L2. Tabs: L1 L2.
            let s = await Scene([.emptyGroupHeader(pinned: false), .tab("L1", pinned: false), .tab("L2", pinned: false)], tabOrder: ["L1", "L2"])
            defer { s.close() }
            let aboveL2 = try s.drop(onRow: 2, fraction: Self.topEdge)
            #expect(aboveL2.index == 1, "The empty group's header is no tab: the line above L2 is tab position 1; got \(String(describing: aboveL2.index))")
            let aboveL1 = try s.drop(onRow: 1, fraction: Self.topEdge)
            #expect(aboveL1.index == 0, "got \(String(describing: aboveL1.index))")
        }
    }

    @Test func aGroupHeaderStandsForItsAnchorOrFoldedForEverythingItHolds() {
        let anchor = UUID(), member = UUID(), nestedAnchor = UUID(), nestedMember = UUID(), outside = UUID()
        let parent = WorkspaceGroup(id: UUID(), name: "P", isCollapsed: false, isPinned: false, anchorWorkspaceId: anchor, customColor: nil, iconSymbol: nil)
        let child = WorkspaceGroup(id: UUID(), name: "Q", isCollapsed: false, isPinned: false, anchorWorkspaceId: nestedAnchor, customColor: nil, iconSymbol: nil, parentGroupId: parent.id)
        let membership: [UUID: UUID?] = [anchor: parent.id, member: parent.id, nestedAnchor: child.id, nestedMember: child.id, outside: nil]
        let tabs = [outside, anchor, member, nestedAnchor, nestedMember]
        let byId = [parent.id: parent, child.id: child]
        func ids(_ group: WorkspaceGroup) -> [UUID] {
            VerticalTabsSidebar.groupDropTabIds(group: group, tabIds: tabs, groupIdByWorkspaceId: membership, groupsById: byId)
        }
        #expect(ids(parent) == [anchor], "Expanded: the anchor only")
        var folded = parent; folded.isCollapsed = true
        #expect(ids(folded) == [anchor, member, nestedAnchor, nestedMember], "Folded: everything it holds, nested groups too, in tab order")
        let empty = WorkspaceGroup(id: UUID(), name: "E", isCollapsed: false, isPinned: false, anchor: .empty(UUID()), customColor: nil, iconSymbol: nil)
        #expect(ids(empty).isEmpty, "A model-empty group stands for no workspace")
    }

    // MARK: The same line, dragged as a loose workspace

    private struct Line {
        let name: String, dragged: String, row: String?, edge: SidebarDropEdge
    }

    /// Where `marker` stands among the other tabs, the dragged workspace left out.
    private static func slot(of marker: UUID, in order: [UUID], without dragged: UUID) -> Int {
        order.prefix { $0 != marker }.filter { $0 != dragged }.count
    }

    // 10_expected-results.md, cm-110.10: "the new workspace lands at the place in the tab order a workspace from elsewhere dropped at that spot would take"
    @Test(arguments: [WorkspaceSectionOrder.workspacesFirst, .statusesFirst])
    private func aTabDroppedOnALineLandsWhereALooseWorkspaceDraggedThereWould(_ order: WorkspaceSectionOrder) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let lines: [Line] = order == .workspacesFirst
                ? [Line(name: "above l2", dragged: "l1", row: "l2", edge: .top), Line(name: "under u", dragged: "l1", row: "u", edge: .bottom), Line(name: "above l1", dragged: "u", row: "l1", edge: .top)]
                : [Line(name: "above l1", dragged: "u", row: "l1", edge: .top), Line(name: "above l2", dragged: "l1", row: "l2", edge: .top), Line(name: "under every row", dragged: "l1", row: nil, edge: .bottom)]
            for line in lines {
                // The tab drop: the index the app is asked to make the workspace at.
                let tabDrop = try F(scene: .interleaved, sectionOrder: order); defer { tabDrop.close() }
                tabDrop.resolveSections(); await tabDrop.applyRows()
                let view = tabDrop.container.bonsplitDropView
                view.canPerformAction = { _, _ in true }
                view.setWorkspaceDropTargetCollectionActive(true)
                defer { view.setWorkspaceDropTargetCollectionActive(false) }
                let point = try Self.point(line, in: tabDrop)
                let result = view.debugDrop(point: view.convert(point, from: tabDrop.container.reorderDropView),
                    transfer: BonsplitTabDragPayload.Transfer(debugTabId: UUID(), sourcePaneId: UUID()))
                try #require(result.performed, "\(order) \(line.name): a new workspace is made")
                let index = try #require(tabDrop.newWorkspaceIndexes.last)
                var ids = tabDrop.manager.tabs.map(\.id)
                let marker = UUID()
                ids.insert(marker, at: min(index, ids.count))
                let dragged = tabDrop.w(line.dragged).id
                // The reference: a loose workspace dragged to the same point.
                let reference = try F(scene: .interleaved, sectionOrder: order); defer { reference.close() }
                reference.resolveSections(); await reference.applyRows()
                reference.selected = [reference.w(line.dragged).id]
                try reference.begin(row: .workspace(reference.w(line.dragged).id))
                let referencePlan = try #require(try reference.route(point: try Self.point(line, in: reference), targets: reference.targets(.native)), "\(order) \(line.name): a loose workspace has a plan there")
                try #require(reference.commit(referencePlan))
                let landed = Self.slot(of: reference.w(line.dragged).id, in: reference.manager.tabs.map(\.id), without: reference.w(line.dragged).id)
                #expect(Self.slot(of: marker, in: ids, without: dragged) == landed, "\(order) \(line.name): the new workspace (tab index \(index)) lands among the other tabs where the dragged one does (\(landed))")
            }
        }
    }

    private typealias F = SidebarNestedStatusDropFixture
    private static func point(_ line: Line, in f: F) throws -> CGPoint {
        let measured = f.physicalMeasurements()
        if let row = line.row {
            let frame = try #require(measured[f.w(row).id]?.content)
            return CGPoint(x: 60, y: line.edge == .top ? frame.minY + 1 : frame.maxY - 1)
        }
        let bottom = try #require(measured.values.map { $0.content.maxY }.max())
        return CGPoint(x: 60, y: bottom + 20)
    }

    // MARK: The clamp under a new workspace

    // A pinned group pins its members, though they are not pinned one by one.
    @Test func aPinnedGroupKeepsANewWorkspaceBelowAllOfItsMembers() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let manager = TabManager()
            let member = manager.addWorkspace(), second = manager.addWorkspace()
            let group = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [member.id, second.id]))
            manager.setWorkspaceGroupPinned(groupId: group, isPinned: true)
            try #require(!member.isPinned && !second.isPinned, "The members are not pinned one by one")
            let held = manager.tabs.filter { $0.groupId == group }.count
            try #require(held >= 3 && manager.tabs.prefix(held).allSatisfy { $0.groupId == group }, "The pinned group leads the tab order")
            let source = manager.addWorkspace()
            manager.selectWorkspace(source)
            let panelId = try #require(source.focusedPanelId)
            let detached = try #require(source.detachSurface(panelId: panelId))
            let inserted = try #require(manager.addWorkspace(fromDetachedSurface: detached, insertionIndexOverride: 0))
            #expect(manager.tabs.firstIndex { $0.id == inserted.id } == held, "Dropped at 0, the new workspace goes after the whole pinned group (\(held)), not before or inside it")
        }
    }

    // MARK: A tab on a section header row is refused

    /// Tabs L1 P1 L2 P2 L3 (P1, P2 Parked), as the second cold review found them; with pins, K1 is pinned and first.
    private static func headerLayout(statusesFirst: Bool, statusesFolded: Bool, pins: Bool) -> (rows: [Spec], tabs: [String], headers: [(name: String, row: Int)]) {
        let pinned: [Spec] = pins ? [.header(.pinnedArea), .tab("K1", pinned: true)] : []
        let workspaces: [Spec] = [.header(.workspacesArea), .tab("L1", pinned: false), .tab("L2", pinned: false), .tab("L3", pinned: false)]
        let statuses: [Spec] = statusesFolded
            ? [.header(.statusesArea, folded: ["P1", "P2"])]
            : [.header(.statusesArea), .header(.statusGroup("parked")), .tab("P1", pinned: false), .tab("P2", pinned: false)]
        let rows = pinned + (statusesFirst ? statuses + workspaces : workspaces + statuses)
        var headers: [(name: String, row: Int)] = []
        for (position, spec) in rows.enumerated() {
            if case .header(let kind, _) = spec {
                switch kind {
                case .pinnedArea: headers.append(("Pinned", position))
                case .workspacesArea: headers.append(("Workspaces", position))
                case .statusesArea: headers.append(("Statuses", position))
                case .statusGroup: break
                }
            }
        }
        return (rows, (pins ? ["K1"] : []) + ["L1", "P1", "L2", "P2", "L3"], headers)
    }

    // 02_decisions 2026-10-25 ruling (19): "A tab dropped on a section header row (`Pinned`, `Workspaces` or `Statuses`, including the line drawn on that header's top edge) is refused, with no line"
    @Test(arguments: [false, true], [false, true])
    private func aTabOnASectionHeaderRowIsRefusedWhereverItLandsInTheRow(_ statusesFirst: Bool, _ statusesFolded: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            for pins in [false, true] {
                let layout = Self.headerLayout(statusesFirst: statusesFirst, statusesFolded: statusesFolded, pins: pins)
                let s = await Scene(layout.rows, tabOrder: layout.tabs); defer { s.close() }
                for (name, row) in layout.headers {
                    for (band, fraction) in [("top edge", Self.topEdge), ("middle", 0.5), ("bottom edge", 0.98)] {
                        let result = try s.refusal(onRow: row, fraction: fraction)
                        #expect(result.refused, "statusesFirst \(statusesFirst), Statuses folded \(statusesFolded), pins \(pins): the \(name) header's \(band) is refused with no line and no workspace (line \(String(describing: result.line)))")
                    }
                }
            }
        }
    }

    // The same, with the list scrolled so a section header is the top visible row: the table only measures the visible rows.
    @Test func aTabOnAScrolledSectionHeaderIsRefusedAndAStatusGroupHeaderIsNot() {
        func target(_ y: CGFloat, tabIds: [UUID]? = nil, header: Bool = false) -> SidebarDropPlanner.WorkspaceDropTarget {
            .init(workspaceId: UUID(), isPinned: false, frame: CGRect(x: 0, y: y, width: 200, height: 26), tabIds: tabIds, isSectionHeader: header)
        }
        let statuses = target(0, tabIds: [], header: true), parked = target(28, tabIds: []), p1 = target(56)
        let planner = SidebarDropPlanner()
        #expect(planner.workspaceAction(for: CGPoint(x: 10, y: 1), targets: [statuses, parked, p1]) == nil, "The Statuses header is the top visible row: its top edge is refused")
        let onStatusGroup = planner.workspaceAction(for: CGPoint(x: 10, y: 29), targets: [statuses, parked, p1])
        guard case .newWorkspace? = onStatusGroup else { Issue.record("A status group's header keeps its top-edge line, got \(String(describing: onStatusGroup))"); return }
    }

    // MARK: A pinned group's members are in the pinned run

    private static let pinnedGroupMembers: [Spec] = [
        .header(.pinnedArea), .groupHeader("PG", pinned: true), .tab("m1", pinned: false, pinnedByGroup: true), .tab("m2", pinned: false, pinnedByGroup: true),
        .header(.workspacesArea), .tab("L1", pinned: false),
    ]

    // 10_expected-results.md, cm-110.10: a new workspace never lands among the pinned; the line is drawn where it lands
    @Test func aLineAmongAPinnedGroupsMembersIsDrawnWhereTheWorkspaceLandsAfterThem() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let s = await Scene(Self.pinnedGroupMembers, tabOrder: ["PG", "m1", "m2", "L1"]); defer { s.close() }
            // Rows: 0 Pinned, 1 PG, 2 m1, 3 m2, 4 Workspaces, 5 L1. Tabs: PG m1 m2 L1.
            for position in [2, 3] {
                let among = try s.drop(onRow: position, fraction: Self.topEdge)
                #expect(among.index == 3, "Row \(position): after the whole pinned group (3); got \(String(describing: among.index))")
                #expect(among.line == SidebarDropIndicator(tabId: s.rowIds[4], edge: .top), "Row \(position): the line is drawn above the Workspaces header, where it lands, not inside Pinned; got \(String(describing: among.line))")
            }
            let between = try s.drop(onRow: 2, fraction: Self.bottomEdge)
            #expect(between.index == 3 && between.line == SidebarDropIndicator(tabId: s.rowIds[4], edge: .top), "Between m1 and m2: the same; got \(String(describing: between))")
        }
    }

    @Test func aLineInsideANestedGroupInAPinnedGroupIsDrawnAfterThePinnedRun() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Rows: 0 Pinned, 1 PG, 2 NG (inside PG), 3 n1, 4 m2, 5 Workspaces, 6 L1. Tabs: PG NG n1 m2 L1.
            let s = await Scene([.header(.pinnedArea), .groupHeader("PG", pinned: true), .groupHeader("NG", pinned: false, pinnedByGroup: true),
                .tab("n1", pinned: false, pinnedByGroup: true), .tab("m2", pinned: false, pinnedByGroup: true), .header(.workspacesArea), .tab("L1", pinned: false)],
                tabOrder: ["PG", "NG", "n1", "m2", "L1"])
            defer { s.close() }
            for position in [2, 3, 4] {
                let inside = try s.drop(onRow: position, fraction: Self.topEdge)
                #expect(inside.index == 4 && inside.line == SidebarDropIndicator(tabId: s.rowIds[5], edge: .top),
                    "Row \(position): after the whole pinned run (4), the line above the Workspaces header; got \(String(describing: inside))")
            }
        }
    }

    @Test func aGroupHoldsARowInThePinnedRunWhenItOrAGroupAboveItIsPinned() {
        func group(_ id: UUID, pinned: Bool, parent: UUID? = nil) -> WorkspaceGroup {
            WorkspaceGroup(id: id, name: "G", isCollapsed: false, isPinned: pinned, anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil, parentGroupId: parent)
        }
        let top = UUID(), middle = UUID(), loose = UUID()
        let byId = [top: group(top, pinned: true), middle: group(middle, pinned: false, parent: top), loose: group(loose, pinned: false)]
        #expect(VerticalTabsSidebar.isPinnedByGroup(groupId: top, groupsById: byId), "The pinned group itself")
        #expect(VerticalTabsSidebar.isPinnedByGroup(groupId: middle, groupsById: byId), "A group inside a pinned group")
        #expect(!VerticalTabsSidebar.isPinnedByGroup(groupId: loose, groupsById: byId), "An unpinned group on its own")
        #expect(!VerticalTabsSidebar.isPinnedByGroup(groupId: nil, groupsById: byId), "A row in no group")
    }
}
