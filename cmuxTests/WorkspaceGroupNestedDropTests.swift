import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxUpdater
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): a drop in the sidebar around nested groups, through the real code. The window is built with the
// entrances the app has (`createWorkspaceGroup`, `addWorkspaceToGroup`), the real sidebar is mounted in a window, a
// live drag session is begun in the app's own drag registry, the table controller plans the hover with the app's own
// planner and paints the line on the real cells, and the release goes through the controller's drop into
// `ContentView.performWorkspaceReorderPlan` and the real `TabManager`.
@MainActor
@Suite("Workspace group nesting, a drop in the sidebar", .serialized)
struct WorkspaceGroupNestedDropTests {
    private let suiteName = "WorkspaceGroupNestedDropTests.shared"

    private struct Mounted {
        let window: NSWindow
        let table: NSTableView
        let container: SidebarWorkspaceTableContainerView
        let controller: SidebarWorkspaceTableController
        let defaults: UserDefaults
    }

    /// `L` loose; `P` holds `A` and `p1`; `A` holds `a1` and `a2`. Each group has a workspace behind its name.
    private struct Window {
        let manager: TabManager
        var names: [UUID: String] = [:]
        let l: UUID, a1: UUID, a2: UUID, p1: UUID
        let p: UUID, a: UUID
        func id(_ name: String) -> UUID { names.first { $0.value == name }!.key }
    }

    private func window() throws -> Window {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let (l, a1, a2, p1) = (ids[0], ids[1], ids[2], ids[3])
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [a1, p1]))
        // The first workspace to join sits in P, so the new group is made inside P at its place.
        let a = try #require(manager.createWorkspaceGroup(name: "A", childWorkspaceIds: [a1]))
        manager.addWorkspaceToGroup(workspaceId: a2, groupId: a)
        manager.selectWorkspace(manager.tabs[0])
        var window = Window(manager: manager, l: l, a1: a1, a2: a2, p1: p1, p: p, a: a)
        window.names = [l: "L", a1: "a1", a2: "a2", p1: "p1"]
        window.names[try #require(manager.workspaceGroupAnchor(for: p)?.id)] = "P"
        window.names[try #require(manager.workspaceGroupAnchor(for: a)?.id)] = "A"
        return window
    }

    /// `L` loose; `P` holds `A` and `p1`; `A` holds `a1` and `B`; `B` holds `b1`. Three levels of group.
    private func threeLevelWindow() throws -> Window {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let (l, a1, b1, p1) = (ids[0], ids[1], ids[2], ids[3])
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [a1, b1, p1]))
        let a = try #require(manager.createWorkspaceGroup(name: "A", childWorkspaceIds: [a1]))
        manager.addWorkspaceToGroup(workspaceId: b1, groupId: a)
        let b = try #require(manager.createWorkspaceGroup(name: "B", childWorkspaceIds: [b1]))
        manager.selectWorkspace(manager.tabs[0])
        var window = Window(manager: manager, l: l, a1: a1, a2: b1, p1: p1, p: p, a: a)
        window.names = [l: "L", a1: "a1", b1: "b1", p1: "p1"]
        window.names[try #require(manager.workspaceGroupAnchor(for: p)?.id)] = "P"
        window.names[try #require(manager.workspaceGroupAnchor(for: a)?.id)] = "A"
        window.names[try #require(manager.workspaceGroupAnchor(for: b)?.id)] = "B"
        return window
    }

    /// The rows as the sidebar draws them, each with how many groups hold it.
    private func rows(_ w: Window) -> [String] {
        let model = w.manager.workspaces
        let groups = model.workspaceGroups
        let anchors = Dictionary(groups.map { ($0.anchorWorkspaceId, $0.id) }, uniquingKeysWith: { first, _ in first })
        return WorkspaceGroupRowWalk.rows(groups: groups, workspaces: model.tabs.map { WorkspaceGroupWorkspaceItem($0) }).map { row in
            switch row.kind {
            case .header(let groupId):
                return "\(groups.first { $0.id == groupId }.flatMap { w.names[$0.anchorWorkspaceId] } ?? "?"):\(row.depth)"
            case .workspace(let id):
                _ = anchors
                return "\(w.names[id] ?? "?"):\(row.depth)"
            }
        }
    }

    private func mount(_ manager: TabManager) async throws -> Mounted {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
        let featureFlags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
        featureFlags.setOverride(true, for: CmuxFeatureFlags.appKitSidebarListFlag)
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID(), featureFlags: featureFlags)
            .environmentObject(manager)
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .defaultAppStorage(defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        await drain(window)
        let container = try #require(descendants(of: SidebarWorkspaceTableContainerView.self, in: window.contentView).first)
        let controller = try #require(container.tableView.dataSource as? SidebarWorkspaceTableController)
        return Mounted(window: window, table: container.tableView, container: container, controller: controller, defaults: defaults)
    }

    private func close(_ mounted: Mounted) {
        mounted.window.contentView = nil
        mounted.window.close()
        mounted.defaults.removePersistentDomain(forName: suiteName)
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var matches: [View] = []
        if let match = root as? View { matches.append(match) }
        for subview in root.subviews { matches.append(contentsOf: descendants(of: type, in: subview)) }
        return matches
    }

    private func drain(_ window: NSWindow, iterations: Int = 30) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    // MARK: - Driving a drag

    private enum Zone { case upper, lower, bottomEdge }
    private enum Half { case left, right }
    private enum Row { case workspace(UUID), header(UUID) }

    private func rowIndex(_ mounted: Mounted, _ row: Row) throws -> Int {
        for index in 0..<mounted.table.numberOfRows {
            switch (row, mounted.table.view(atColumn: 0, row: index, makeIfNecessary: false)) {
            case (.workspace(let id), let cell as SidebarWorkspaceRowTableCellView) where cell.currentModelForMeasurement?.workspaceId == id:
                return index
            case (.header(let id), let cell as SidebarGroupHeaderTableCellView) where cell.currentModelForTesting?.groupId == id:
                return index
            default:
                continue
            }
        }
        throw TestError("the row \(row) is not in the list")
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The pointer in window coordinates over a row's zone and half of the sidebar.
    private func windowPoint(_ mounted: Mounted, row: Int, _ zone: Zone, _ half: Half) -> NSPoint {
        let rect = mounted.table.rect(ofRow: row)
        let y: CGFloat
        switch zone {
        case .upper: y = rect.minY + 7
        case .lower: y = rect.minY + rect.height * 0.75
        case .bottomEdge: y = rect.maxY - 1
        }
        let x = rect.minX + rect.width * (half == .left ? 0.25 : 0.75)
        return mounted.table.convert(NSPoint(x: x, y: y), to: nil)
    }

    /// Begins a live drag of `dragged` in the app's own registry and hovers a row's zone. True when a drop was planned.
    private func hover(_ mounted: Mounted, dragging dragged: UUID, over target: Row, _ zone: Zone, _ half: Half) throws -> Bool {
        let registry = try #require(AppDelegate.shared?.sidebarWorkspaceDragRegistry)
        let session = registry.beginSession(workspaceId: dragged)
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.setString(session.pasteboardValue, forType: NSPasteboard.PasteboardType(SidebarWorkspaceDragSession.pasteboardTypeIdentifier))
        let row = try rowIndex(mounted, target)
        return mounted.controller.updateReorderDrag(windowPoint: windowPoint(mounted, row: row, zone, half))
    }

    /// Releases at the last hover through the controller's drop. Returns whether the drop was handled.
    private func release(_ mounted: Mounted, dragged: UUID) -> Bool {
        let dropView = mounted.container.reorderDropView
        guard let perform = dropView.performDropAtPoint else { return false }
        let done = perform(.zero, dropView.targets)
        AppDelegate.shared?.sidebarWorkspaceDragRegistry.end(workspaceId: dragged)
        return done
    }

    /// Mounts the window with several workspaces selected in the sidebar, by the debug hook the UI tests use
    /// (`CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES`: indexes into the tabs, the last one focused). The hook is read
    /// when the sidebar first appears, so it is set for the mount only. It is applied after the sidebar appears, not by the
    /// time the mount has drained, so this waits until the table reports the selection that was asked for, and throws, with
    /// what the table reports, if it never does.
    private func mount(_ w: Window, selecting ids: [UUID]) async throws -> Mounted {
        let key = "CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"
        let indices = try ids.map { id in try #require(w.manager.tabs.firstIndex { $0.id == id }) }
        setenv(key, indices.map(String.init).joined(separator: ","), 1)
        defer { unsetenv(key) }
        let mounted = try await mount(w.manager)
        for _ in 0..<400 where reportedSelection(mounted) != Set(ids) { await drain(mounted.window, iterations: 5) }
        let reported = reportedSelection(mounted)
        guard reported == Set(ids) else {
            close(mounted)
            throw TestError("the table never reported the selection that was asked for: asked \(ids.map { w.names[$0] ?? "?" }.sorted()), reported \(reported.map { w.names[$0] ?? "?" }.sorted())")
        }
        return mounted
    }

    /// The workspaces the table's rows show as selected.
    private func reportedSelection(_ mounted: Mounted) -> Set<UUID> {
        Set(descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table).compactMap { cell in
            cell.currentModelForMeasurement.flatMap { $0.isMultiSelected ? $0.workspaceId : nil }
        })
    }

    private func cleanUp(_ mounted: Mounted, dragged: UUID) {
        mounted.controller.reorderDropDragExited()
        AppDelegate.shared?.sidebarWorkspaceDragRegistry.end(workspaceId: dragged)
        NSPasteboard(name: .drag).clearContents()
    }

    /// The drop lines drawn now, each with its x in window coordinates, read from the laid-out line: those the cells
    /// draw, and the end-of-list line the container draws.
    private func drawnLines(_ mounted: Mounted) -> [(row: String, edge: String, x: CGFloat)] {
        var lines: [(row: String, edge: String, x: CGFloat)] = []
        func windowX(_ view: NSView, _ x: CGFloat) -> CGFloat { view.convert(NSPoint(x: x, y: 0), to: nil).x }
        for cell in descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table) {
            cell.layoutSubtreeIfNeeded()
            let paint = cell.dropIndicatorPaintForTesting
            let frames = cell.dropIndicatorFramesForTesting
            let name = cell.currentModelForMeasurement.map { "\($0.workspaceId)" } ?? "?"
            if paint.top { lines.append((name, "top", windowX(cell, frames.top.minX))) }
            if paint.bottom { lines.append((name, "bottom", windowX(cell, frames.bottom.minX))) }
        }
        for cell in descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table) {
            cell.layoutSubtreeIfNeeded()
            let paint = cell.dropIndicatorPaintForTesting
            let frames = cell.dropIndicatorFramesForTesting
            let name = cell.currentModelForTesting.map { "header \($0.groupId)" } ?? "?"
            if paint.top { lines.append((name, "top", windowX(cell, frames.top.minX))) }
            if paint.bottom { lines.append((name, "bottom", windowX(cell, frames.bottom.minX))) }
        }
        let end = mounted.container.emptyDropIndicatorView
        if !end.isHidden { lines.append(("end of list", "bottom", windowX(end.superview ?? end, end.frame.minX))) }
        return lines
    }

    /// Where a row's background starts, read from the laid-out cell of a workspace.
    private func backgroundX(_ mounted: Mounted, _ workspaceId: UUID) throws -> CGFloat {
        let cell = try #require(descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
            .first { $0.currentModelForMeasurement?.workspaceId == workspaceId })
        cell.layoutSubtreeIfNeeded()
        return cell.convert(NSPoint(x: cell.backgroundFrameForTesting.minX, y: 0), to: nil).x
    }

    // MARK: - Scenario 27

    @Test func aWorkspaceAtTheBottomEdgeOfChildAGoesToAOnTheRightAndToPOnTheLeft() async throws {
        let cases: [(half: Half, expected: [String])] = [
            (.right, ["P:0", "A:1", "a1:2", "a2:2", "L:2", "p1:1"]),
            (.left, ["P:0", "A:1", "a1:2", "a2:2", "L:1", "p1:1"])
        ]
        for testCase in cases {
            let w = try window()
            #expect(rows(w) == ["L:0", "P:0", "A:1", "a1:2", "a2:2", "p1:1"], "the window the entrances build")
            let mounted = try await mount(w.manager)
            defer { close(mounted); cleanUp(mounted, dragged: w.l) }
            #expect(try hover(mounted, dragging: w.l, over: .workspace(w.a2), .bottomEdge, testCase.half), "a drop is planned")
            #expect(release(mounted, dragged: w.l), "the controller handled the drop")
            await drain(mounted.window)
            #expect(rows(w) == testCase.expected, "half \(testCase.half)")
        }
    }

    @Test func theDropLineIsIndentedToTheLevelTheDropLandsAt() async throws {
        let w = try window()
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: w.l) }
        // The step from the top level to the level of P's rows, and to the level of A's rows, read from the rows.
        let top = try backgroundX(mounted, w.l)
        let depth1 = try backgroundX(mounted, w.p1)
        let depth2 = try backgroundX(mounted, w.a2)
        func lineX(over target: Row, _ zone: Zone, _ half: Half) throws -> CGFloat {
            #expect(try hover(mounted, dragging: w.l, over: target, zone, half), "a drop is planned")
            let lines = drawnLines(mounted)
            #expect(lines.count == 1, "one line is drawn: \(lines)")
            return try #require(lines.first).x
        }
        // The edge below A's last row: right half is A's level (2), left half is P's (1). Below P's last row, the
        // left half is the top level (0).
        let atA = try lineX(over: .workspace(w.a2), .bottomEdge, .right)
        let atP = try lineX(over: .workspace(w.a2), .bottomEdge, .left)
        let atTop = try lineX(over: .workspace(w.p1), .bottomEdge, .left)
        #expect(atP - atTop == depth1 - top, "P's level is one step in from the top level: line \(atP - atTop), rows \(depth1 - top)")
        #expect(atA - atTop == depth2 - top, "A's level is two steps in: line \(atA - atTop), rows \(depth2 - top)")
        #expect(depth2 - top > depth1 - top && depth1 - top > 0)
    }

    @Test func aNestedHeaderMovesAmongItsParentsRowsAndNowhereElse() async throws {
        let w = try window()
        let aAnchor = try #require(w.manager.workspaceGroupAnchor(for: w.a)?.id)
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: aAnchor) }
        // Outside P: no plan, no line, nothing changes.
        #expect(try !hover(mounted, dragging: aAnchor, over: .workspace(w.l), .lower, .right))
        #expect(drawnLines(mounted).isEmpty)
        #expect(rows(w) == ["L:0", "P:0", "A:1", "a1:2", "a2:2", "p1:1"])
        // Below p1, a row of P: A goes there.
        #expect(try hover(mounted, dragging: aAnchor, over: .workspace(w.p1), .bottomEdge, .right))
        #expect(release(mounted, dragged: aAnchor))
        await drain(mounted.window)
        #expect(rows(w) == ["L:0", "P:0", "p1:1", "A:1", "a1:2", "a2:2"])
    }

    // MARK: - The line at every level, on every kind of cell

    @Test func theDropLineStepsInOneLevelAtATimeOnAThreeLevelWindow() async throws {
        let w = try threeLevelWindow()
        #expect(rows(w) == ["L:0", "P:0", "A:1", "a1:2", "B:2", "b1:3", "p1:1"])
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: w.l) }
        let b1 = try #require(w.names.first { $0.value == "b1" }?.key)
        let background = [
            try backgroundX(mounted, w.l), try backgroundX(mounted, w.p1), try backgroundX(mounted, w.a1), try backgroundX(mounted, b1)
        ]
        func lineX(over target: Row, _ zone: Zone, _ half: Half) throws -> CGFloat {
            #expect(try hover(mounted, dragging: w.l, over: target, zone, half), "a drop is planned")
            let lines = drawnLines(mounted)
            #expect(lines.count == 1, "one line is drawn: \(lines)")
            return try #require(lines.first).x
        }
        // Below b1: right half is B (level 3). Left half leaves B and A, to P (level 1). Below p1: the top level (0).
        let level3 = try lineX(over: .workspace(b1), .bottomEdge, .right)
        let level1 = try lineX(over: .workspace(b1), .bottomEdge, .left)
        let level0 = try lineX(over: .workspace(w.p1), .bottomEdge, .left)
        #expect(level1 - level0 == background[1] - background[0], "level 1: line \(level1 - level0), rows \(background[1] - background[0])")
        #expect(level3 - level0 == background[3] - background[0], "level 3: line \(level3 - level0), rows \(background[3] - background[0])")
        // Level 2: the lower half of A's header joins A, first among its rows.
        let level2 = try lineX(over: .header(w.a), .lower, .right)
        #expect(level2 - level0 == background[2] - background[0], "level 2: line \(level2 - level0), rows \(background[2] - background[0])")
    }

    @Test func aLineOnAHeaderCellIsIndentedToTheLevelOfTheDrop() async throws {
        let w = try window()
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: w.l) }
        // The boundary before p1 is a place among P's rows: its line is on p1's cell. The boundary before A's header is
        // the same level: its line is on the header cell. The two lines are drawn at the same x.
        #expect(try hover(mounted, dragging: w.l, over: .workspace(w.p1), .upper, .right))
        let onWorkspace = drawnLines(mounted)
        #expect(onWorkspace.count == 1)
        #expect(try hover(mounted, dragging: w.l, over: .header(w.a), .upper, .right))
        let onHeader = drawnLines(mounted)
        #expect(onHeader.count == 1)
        #expect(onHeader.first?.row.hasPrefix("header") == true, "the line is on the header's cell: \(onHeader)")
        #expect(onHeader.first?.x == onWorkspace.first?.x, "header line \(String(describing: onHeader.first?.x)), workspace line \(String(describing: onWorkspace.first?.x))")
    }

    @Test func theEndOfListLineIsDrawnAtTheTopLevelAndAGroupsEndLineByItsLastRow() async throws {
        let w = try window()
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: w.a2) }
        let end = mounted.container.emptyDropIndicatorView
        // Dragged from inside A, below the last row (p1, a row of P): the left half is the top level: the end-of-list line.
        #expect(try hover(mounted, dragging: w.a2, over: .workspace(w.p1), .bottomEdge, .left))
        #expect(!end.isHidden, "the end-of-list line is drawn")
        #expect(end.frame.minX == SidebarReorderIndicatorView.horizontalInset, "at the top level it starts at the sidebar's edge: \(end.frame)")
        #expect(drawnLines(mounted).count == 1, "only the end-of-list line is drawn")
        // The right half is P: the line is drawn by the last row's cell, one level in, and not by the end-of-list view.
        #expect(try hover(mounted, dragging: w.a2, over: .workspace(w.p1), .bottomEdge, .right))
        #expect(end.isHidden)
        let lines = drawnLines(mounted)
        #expect(lines.count == 1)
        #expect(lines.first?.row != "end of list")
        #expect((lines.first?.x ?? 0) > end.superview!.convert(NSPoint(x: end.frame.minX, y: 0), to: nil).x, "inside P the line starts further in: \(lines)")
    }

    @Test func aGroupsLineRowsAreTheRowsOfItsWholeRun() async throws {
        let w = try threeLevelWindow()
        let mounted = try await mount(w.manager)
        defer { close(mounted) }
        let visible = (0..<mounted.table.numberOfRows).compactMap { row -> UUID? in
            switch mounted.table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarWorkspaceRowTableCellView: return cell.currentModelForMeasurement?.workspaceId
            case let cell as SidebarGroupHeaderTableCellView: return cell.currentModelForTesting?.anchorWorkspaceId
            default: return nil
            }
        }
        #expect(visible.count == 7, "seven rows are drawn")
        let model = w.manager.workspaces
        let run = SidebarNestedDropLine.runRowIds(groupId: w.p, tabs: w.manager.tabs, groups: model.workspaceGroups, visibleRowIds: visible)
        // P's run: its header, A's header, a1, B's header, b1 and p1: every row but the loose L.
        #expect(run == Array(visible.dropFirst()), "the run of P is every row under it, at every level: \(String(describing: run))")
        let inner = SidebarNestedDropLine.runRowIds(groupId: w.a, tabs: w.manager.tabs, groups: model.workspaceGroups, visibleRowIds: visible)
        #expect(inner?.count == 4, "A's run: its header, a1, B's header, b1")
        // A window with no nested group keeps the direct members: the function answers nothing and the caller does as before.
        let flat = TabManager(autoWelcomeIfNeeded: false)
        flat.addWorkspace(autoWelcomeIfNeeded: false)
        let group = try #require(flat.createWorkspaceGroup(name: "F", childWorkspaceIds: [flat.tabs[1].id]))
        #expect(SidebarNestedDropLine.runRowIds(groupId: group, tabs: flat.tabs, groups: flat.workspaceGroups, visibleRowIds: flat.tabs.map(\.id)) == nil)
    }

    // MARK: - A line the table paints, and releases that go through the real table

    /// The lines drawn now, as `(row, edge)` with the row named by its workspace id.
    private func lineKeys(_ mounted: Mounted) -> [String] {
        drawnLines(mounted).map { "\($0.row) \($0.edge)" }
    }

    @Test func aWorkspaceLeavingItsChildGroupWhereItStandsHasALinePaintedOnTheNextRowThatStays() async throws {
        // `L | P[A[a1, a2], p1]`: a2, the last row of A, onto its own lower-left half or onto the upper half of p1 leaves A and
        // stays where it is in P. The line is the top of p1: a line under a1 would be the top of a2, the dragged row, which the
        // table never paints on.
        let gestures: [(Row, Zone, Half)] = [(.workspace(try window().a2), .lower, .left), (.workspace(try window().p1), .upper, .right)]
        for index in gestures.indices {
            let w = try window()
            let mounted = try await mount(w.manager)
            defer { close(mounted); cleanUp(mounted, dragged: w.a2) }
            let target: Row = index == 0 ? .workspace(w.a2) : .workspace(w.p1)
            #expect(try hover(mounted, dragging: w.a2, over: target, gestures[index].1, gestures[index].2), "a drop is planned")
            #expect(lineKeys(mounted) == ["\(w.p1) top"], "one line, on the top of p1: \(lineKeys(mounted))")
            #expect(release(mounted, dragged: w.a2), "the controller handled the drop")
            await drain(mounted.window)
            #expect(rows(w) == ["L:0", "P:0", "A:1", "a1:2", "a2:1", "p1:1"], "a2 is a row of P, where it stood")
        }
    }

    @Test func severalSelectedRowsDroppedAtTheEndOfAChildGroupAllJoinItWhenReleased() async throws {
        let w = try window()
        let mounted = try await mount(w, selecting: [w.l, w.p1])
        defer { close(mounted); cleanUp(mounted, dragged: w.l) }
        #expect(try hover(mounted, dragging: w.l, over: .workspace(w.a2), .bottomEdge, .right), "a drop is planned")
        #expect(reportedSelection(mounted) == [w.l, w.p1], "the selection is still both rows when the drag hovers")
        #expect(lineKeys(mounted).count == 1, "one line: \(lineKeys(mounted))")
        #expect(release(mounted, dragged: w.l), "the controller handled the drop")
        await drain(mounted.window)
        #expect(rows(w) == ["P:0", "A:1", "a1:2", "a2:2", "L:2", "p1:2"], "both selected rows are in A")
    }

    @Test func severalSelectedRowsDroppedAtATopLevelPlaceAllGoToTheTopLevelWhenReleased() async throws {
        let w = try window()
        let mounted = try await mount(w, selecting: [w.l, w.a2])
        defer { close(mounted); cleanUp(mounted, dragged: w.a2) }
        // Below p1, the last row, on the left half: the top level.
        #expect(try hover(mounted, dragging: w.a2, over: .workspace(w.p1), .bottomEdge, .left), "a drop is planned")
        #expect(reportedSelection(mounted) == [w.l, w.a2], "the selection is still both rows when the drag hovers")
        #expect(lineKeys(mounted).count == 1, "one line: \(lineKeys(mounted))")
        #expect(release(mounted, dragged: w.a2), "the controller handled the drop")
        await drain(mounted.window)
        #expect(rows(w) == ["P:0", "A:1", "a1:2", "p1:1", "L:0", "a2:0"], "both selected rows are at the top level, at the end")
    }

    @Test func oneRowDroppedAtATopLevelPlaceGoesToTheTopLevelWhenReleased() async throws {
        let w = try window()
        let mounted = try await mount(w.manager)
        defer { close(mounted); cleanUp(mounted, dragged: w.a2) }
        #expect(try hover(mounted, dragging: w.a2, over: .workspace(w.p1), .bottomEdge, .left), "a drop is planned")
        #expect(release(mounted, dragged: w.a2), "the controller handled the drop")
        await drain(mounted.window)
        #expect(rows(w) == ["L:0", "P:0", "A:1", "a1:2", "p1:1", "a2:0"], "a2 is at the top level, at the end")
    }

    @Test func aFlatWindowGetsNoLineLevelAndItsLinesAreDrawnAsBefore() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ids[2]]))
        manager.selectWorkspace(manager.tabs[0])
        let mounted = try await mount(manager)
        defer { close(mounted); cleanUp(mounted, dragged: ids[0]) }
        // The line above a group's header starts at the sidebar's inset. The line for joining the group is the top line of its
        // first member's cell, also at the sidebar's inset: nothing is indented in a window with no nested group.
        func origin(_ view: NSView) -> CGFloat { view.convert(NSPoint(x: 0, y: 0), to: nil).x }
        let base = origin(try #require(descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table).first))
        #expect(try hover(mounted, dragging: ids[0], over: .header(group), .upper, .right))
        #expect(drawnLines(mounted).map(\.x) == [base + SidebarReorderIndicatorView.horizontalInset])
        #expect(try hover(mounted, dragging: ids[0], over: .header(group), .lower, .right))
        #expect(drawnLines(mounted).map(\.x) == [base + SidebarReorderIndicatorView.horizontalInset])
        #expect(SidebarNestedDropLine.level(
            for: SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: ids[0], indicator: nil, action: .reorder(targetIndex: 0, usesTopLevelRows: false, explicitGroupId: nil)),
            depthById: [:]
        ) == nil, "a window with no nested group has no line level")
    }

    @Test func aFlatWindowsBottomLineOnAGroupHeaderKeepsTheMemberIndentItHadBeforeNestedGroups() async throws {
        // A group with nothing in it, last in the list: joining it draws the line under its header, which a flat window has
        // always started one member indent in. A line level of 0 for a flat window would start it at the sidebar's inset.
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let loose = manager.tabs[0].id
        let group = try #require(manager.createWorkspaceGroup(name: "E", childWorkspaceIds: []))
        manager.selectWorkspace(manager.tabs[0])
        let mounted = try await mount(manager)
        defer { close(mounted); cleanUp(mounted, dragged: loose) }
        func origin(_ view: NSView) -> CGFloat { view.convert(NSPoint(x: 0, y: 0), to: nil).x }
        let base = origin(try #require(descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table).first))
        #expect(try hover(mounted, dragging: loose, over: .header(group), .lower, .right), "a drop is planned")
        let lines = drawnLines(mounted)
        #expect(lines.count == 1, "one line: \(lines)")
        #expect(lines.first?.row.hasPrefix("header") == true && lines.first?.edge == "bottom", "the line is the bottom of the header cell: \(lines)")
        #expect(
            lines.first?.x == base + SidebarReorderIndicatorView.horizontalInset + SidebarWorkspaceGroupHeaderMetrics.memberScopedDropIndicatorLeadingInset,
            "a flat window's header bottom line starts one member indent in: \(lines), base \(base)"
        )
    }
}
