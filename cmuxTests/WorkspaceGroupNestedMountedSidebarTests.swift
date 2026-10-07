import AppKit
import CmuxFoundation
import CmuxUpdater
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): what the app's own builder and table controller produce, read from the real sidebar
// mounted in a window. The earlier tests build a header model by hand and prove the cell; these prove that the
// app ever hands the cell such a model.
@MainActor
@Suite("Workspace group nesting, the mounted sidebar", .serialized)
struct WorkspaceGroupNestedMountedSidebarTests {
    /// One fixed suite per window a test mounts at the same time: a second mount in a test must not empty the suite the
    /// first window still uses.
    private enum Suite: String {
        case first = "WorkspaceGroupNestedMountedSidebarTests.shared"
        case second = "WorkspaceGroupNestedMountedSidebarTests.second"
    }

    private struct Mounted {
        let window: NSWindow
        let table: NSTableView
        let controller: SidebarWorkspaceTableController
        /// The `UserDefaults` suite the mount used; `close` empties it.
        let suiteName: String
        let defaults: UserDefaults
    }

    private func mount(_ manager: TabManager, suite: Suite = .first) async throws -> Mounted {
        _ = NSApplication.shared
        // A fixed suite name, not one per mount: a suite leaves a plist file in ~/Library/Preferences that
        // `removePersistentDomain` does not remove (a run with the file also removed at `close` still left one per
        // mount). The suite is `.serialized` and emptied at the start of each mount and at `close`.
        let suiteName = suite.rawValue
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
        let containers = descendants(of: SidebarWorkspaceTableContainerView.self, in: window.contentView)
        let container = try #require(containers.first)
        let controller = try #require(container.tableView.dataSource as? SidebarWorkspaceTableController)
        return Mounted(window: window, table: container.tableView, controller: controller, suiteName: suiteName, defaults: defaults)
    }

    private func close(_ mounted: Mounted) {
        mounted.window.contentView = nil
        mounted.window.close()
        mounted.defaults.removePersistentDomain(forName: mounted.suiteName)
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

    private func headerCell(_ mounted: Mounted, _ groupId: UUID) -> SidebarGroupHeaderTableCellView? {
        descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
            .first { $0.currentModelForTesting?.groupId == groupId }
    }

    private func workspaceCell(_ mounted: Mounted, _ workspaceId: UUID) -> SidebarWorkspaceRowTableCellView? {
        descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
            .first { $0.currentModelForMeasurement?.workspaceId == workspaceId }
    }

    /// A window with no nested group: `G` holds a workspace; `E` is a pinned header whose own workspace was closed.
    private func flatWindow() throws -> (manager: TabManager, selected: UUID, own: UUID, empty: UUID, other: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let own = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ids[1]]))
        let empty = try #require(manager.createWorkspaceGroup(name: "E", childWorkspaceIds: []))
        manager.toggleWorkspaceGroupPinned(groupId: empty)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: empty)))
        manager.selectWorkspace(manager.tabs[0])
        #expect(manager.workspaceGroups.first { $0.id == empty }?.liveAnchorWorkspaceId == nil)
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        return (manager, ids[0], own, empty, ids[1])
    }

    /// `P` holds only `Q`; `Q` holds `w1` and `R`; `R` holds `w2`. `P` has no workspace of its own.
    private func nestedWindow() throws -> (manager: TabManager, p: UUID, q: UUID, r: UUID, inQ: UUID, inR: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[1]]))
        let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[2]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: r, intoParent: q) == .moved)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: p)))
        manager.selectWorkspace(manager.tabs[0])
        #expect(manager.workspaceGroups.first { $0.id == p }?.liveAnchorWorkspaceId == nil)
        return (manager, p, q, r, ids[1], ids[2])
    }

    // MARK: - The builder

    @Test func theBuilderCallsAHeaderWithNoLiveWorkspaceWithoutOneInAFlatWindowAndInANestedOne() async throws {
        let flat = try flatWindow()
        let flatMounted = try await mount(flat.manager)
        defer { close(flatMounted) }
        let empty = try #require(headerCell(flatMounted, flat.empty), "the empty header is in the list")
        let own = try #require(headerCell(flatMounted, flat.own), "the header with a workspace is in the list")
        #expect(empty.currentModelForTesting?.hasOwnWorkspace == false, "flat window, header with no live workspace")
        #expect(own.currentModelForTesting?.hasOwnWorkspace == true, "flat window, header with a workspace")

        let nested = try nestedWindow()
        let nestedMounted = try await mount(nested.manager, suite: .second)
        defer { close(nestedMounted) }
        let p = try #require(headerCell(nestedMounted, nested.p))
        let q = try #require(headerCell(nestedMounted, nested.q))
        #expect(p.currentModelForTesting?.hasOwnWorkspace == false, "nested window, header with no live workspace")
        #expect(q.currentModelForTesting?.hasOwnWorkspace == true, "nested window, header with a workspace")
    }

    // MARK: - The dot

    @Test func aHeaderWithNoWorkspaceDrawsADotWhereAHeaderWithOneDrawsItsFilledIcon() async throws {
        let flat = try flatWindow()
        let mounted = try await mount(flat.manager)
        defer { close(mounted) }
        let ownCell = try #require(headerCell(mounted, flat.own))
        let emptyCell = try #require(headerCell(mounted, flat.empty))
        let ownModel = try #require(ownCell.currentModelForTesting)
        let filledName = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: ownModel.iconSymbol, configured: nil)

        // The icon view of the header with a workspace holds the symbol built on its own at the same size and weight.
        let pointSize = GlobalFontMagnification.scaledSize(
            SidebarWorkspaceGroupHeaderMetrics(fontScale: ownModel.fontScale).iconFontSize,
            percent: ownModel.globalFontMagnificationPercent
        )
        func pixels(_ image: NSImage?) -> Data? { image?.tiffRepresentation }
        let filled = pixels(RenderableSystemSymbol.configuredAppKitImage(systemName: filledName, pointSize: pointSize, weight: .semibold))
        #expect(filled != nil)
        #expect(pixels(ownCell.iconImageForTesting) == filled, "the header with a workspace holds the filled \(filledName)")
        #expect(emptyCell.iconImageForTesting?.size == NSSize(width: 8, height: 8), "the header with no workspace holds an 8 pt dot")
    }

    // MARK: - The indent of a row

    /// `u` sits at the top level; `P` holds `w1`, and `Q` in it holds `w2`, and `R` in that holds `w3`. Workspaces at
    /// depth 0, 1, 2 and 3, and headers at depth 0, 1 and 2.
    private func threeLevelWindow() throws -> (manager: TabManager, u: UUID, w1: UUID, w2: UUID, w3: UUID, p: UUID, q: UUID, r: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: r, intoParent: q) == .moved)
        manager.selectWorkspace(manager.tabs[0])
        return (manager, ids[0], ids[1], ids[2], ids[3], p, q, r)
    }

    @Test func aRowTwoOrThreeLevelsDeepIsDrawnTwoOrThreeStepsIn() async throws {
        let nested = try threeLevelWindow()
        let mounted = try await mount(nested.manager)
        defer { close(mounted) }
        func frames(_ id: UUID) throws -> (background: CGFloat, title: CGFloat) {
            let cell = try #require(workspaceCell(mounted, id), "the row of \(id) is in the list")
            cell.layoutSubtreeIfNeeded()
            return (cell.backgroundFrameForTesting.minX, cell.titleFrameForTesting.minX)
        }
        let topFrames = try frames(nested.u)
        let top = topFrames.background
        let depth1 = try frames(nested.w1).background
        let depth2 = try frames(nested.w2).background
        let depth3 = try frames(nested.w3).background
        // Each level sits one step further in than the one above it (a step is 12 points; the sidebar is wide
        // enough for the cap of 40% of its width to be out of the way at depth 3).
        #expect(depth1 - top == 12, "depth 1: \(depth1 - top) points in")
        #expect(depth2 - top == 24, "depth 2: \(depth2 - top) points in")
        #expect(depth3 - top == 36, "depth 3: \(depth3 - top) points in")
        // The content moves with the background: the title starts as far in as the row does.
        let titleTop = topFrames.title
        #expect(try frames(nested.w1).title - titleTop == 12, "title at depth 1")
        #expect(try frames(nested.w2).title - titleTop == 24, "title at depth 2")
        #expect(try frames(nested.w3).title - titleTop == 36, "title at depth 3")
        // The headers: P at the top, Q one in, R two in.
        #expect(headerCell(mounted, nested.p)?.currentModelForTesting?.depth == 0)
        #expect(headerCell(mounted, nested.q)?.currentModelForTesting?.depth == 1)
        #expect(headerCell(mounted, nested.r)?.currentModelForTesting?.depth == 2)
    }

    // MARK: - The press preview

    @Test func aPressOnAHeaderWithNoWorkspaceLeavesTheHighlightOnTheSelectedRow() async throws {
        let flat = try flatWindow()
        let mounted = try await mount(flat.manager)
        defer { close(mounted) }
        let selected = try #require(workspaceCell(mounted, flat.selected))
        let other = try #require(workspaceCell(mounted, flat.other))
        let emptyHeader = try #require(headerCell(mounted, flat.empty))
        #expect(selected.currentModelForMeasurement?.isActive == true, "the fixture selects the first workspace")
        var peeled = 0
        selected.applyModelProbeForTesting = { model in if !model.isActive { peeled += 1 } }

        // The press on the header with no workspace: no preview, so the selected row is not peeled.
        mounted.controller.previewSelection(row: mounted.table.row(for: emptyHeader), modifiers: [], hitView: nil)
        #expect(peeled == 0, "a press on a header with no workspace peeled the highlight off the selected row")

        // Control: a press on another workspace does peel it, so the probe can see a peel.
        mounted.controller.previewSelection(row: mounted.table.row(for: other), modifiers: [], hitView: nil)
        #expect(peeled > 0, "the control press did not peel the selected row")
    }

    // MARK: - The name colour in the optimistic deselect paint

    @Test func aPlainClickPaintsTheDeselectedHeaderNameLikeAHeaderThatWasNeverActive() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let active = try #require(manager.createWorkspaceGroup(name: "A", childWorkspaceIds: [ids[1]]))
        let idle = try #require(manager.createWorkspaceGroup(name: "I", childWorkspaceIds: [ids[2]]))
        manager.selectWorkspace(try #require(manager.workspaceGroupAnchor(for: active)))
        let mounted = try await mount(manager)
        defer { close(mounted) }
        let activeCell = try #require(headerCell(mounted, active))
        let idleCell = try #require(headerCell(mounted, idle))
        #expect(activeCell.currentModelForTesting?.isAnchorActive == true, "the fixture selects A's own workspace")
        #expect(idleCell.currentModelForTesting?.isAnchorActive == false)

        func rgba(_ color: NSColor) -> [CGFloat] {
            guard let c = color.usingColorSpace(.sRGB) else { return [] }
            return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { (($0 * 1000).rounded()) / 1000 }
        }
        let idleName = rgba(idleCell.nameTextColorForTesting)
        #expect(!idleName.isEmpty)
        // The name starts in a colour no header uses, so the check sees the paint write the name at all. (An active
        // header's name and an idle one's are the same colour in some appearances, so the starting colour is not enough.)
        let nameField = try #require(descendants(of: NSTextField.self, in: activeCell).first { $0.stringValue == "A" })
        nameField.textColor = .systemPink
        #expect(rgba(nameField.textColor ?? .clear) != idleName, "the starting colour is not the idle colour")
        activeCell.showOptimisticDeselection()
        #expect(rgba(nameField.textColor ?? .clear) == idleName, "the deselected header's name is painted as an idle header's")
    }

    @Test func theBuilderNeverHandsAHeaderWithNoWorkspaceAnActiveOrMultiSelectedModelSoTheDeselectPaintCannotReachIt() async throws {
        let flat = try flatWindow()
        let mounted = try await mount(flat.manager)
        defer { close(mounted) }
        let emptyCell = try #require(headerCell(mounted, flat.empty))
        let ownCell = try #require(headerCell(mounted, flat.own))
        // Drive the selection: select each workspace in turn. (A multi-selection could not be driven from outside the
        // window: `ContentView` keeps it in its own state, fed by clicks. The builder computes `isMultiSelected` the same
        // way as `isAnchorActive`, from the header's live workspace, `VerticalTabsSidebar+WorkspaceGroups.swift:21-22`
        // and `:193-194`, so a header with none is never multi-selected either.)
        for workspace in flat.manager.tabs {
            flat.manager.selectWorkspace(workspace)
            await drain(mounted.window)
            let model = try #require(headerCell(mounted, flat.empty)?.currentModelForTesting)
            #expect(!model.isAnchorActive && !model.isMultiSelected, "selecting \(workspace.id): the empty header is not active or selected")
        }
        let emptyModel = try #require(emptyCell.currentModelForTesting)
        // Control: the same drive does reach a header that has a workspace, or the check above proves nothing.
        flat.manager.selectWorkspace(try #require(flat.manager.workspaceGroupAnchor(for: flat.own)))
        await drain(mounted.window)
        let ownModel = try #require(headerCell(mounted, flat.own)?.currentModelForTesting)
        #expect(ownModel.isAnchorActive, "control: the header with a workspace becomes active when its workspace is selected")
        _ = ownCell

        // The paint returns at once for such a model, so the name keeps whatever colour it had.
        let nameField = try #require(descendants(of: NSTextField.self, in: emptyCell).first { $0.stringValue == emptyModel.name })
        nameField.textColor = .systemPink
        emptyCell.showOptimisticDeselection()
        #expect(nameField.textColor == .systemPink, "showOptimisticDeselection did nothing for the header with no workspace")
    }

    // MARK: - The level every row tells assistive technology

    private func levelOf(_ cell: SidebarWorkspaceRowTableCellView?) -> String? { cell?.accessibilityValue() as? String }
    private func levelOf(_ cell: SidebarGroupHeaderTableCellView?) -> String? { cell?.accessibilityValue() as? String }

    @Test func inAWindowWithNoNestedGroupALooseRowAndAHeaderSayLevel1AndAMemberRowSaysLevel2() async throws {
        let flat = try flatWindow()
        #expect(!flat.manager.workspaces.hasNestedWorkspaceGroup)
        let mounted = try await mount(flat.manager)
        defer { close(mounted) }
        #expect(levelOf(workspaceCell(mounted, flat.selected)) == "Level 1", "a row in no group")
        #expect(levelOf(headerCell(mounted, flat.own)) == "Level 1", "a header with a workspace")
        #expect(levelOf(headerCell(mounted, flat.empty)) == "Level 1, No workspace of its own", "a header with none")
        #expect(levelOf(workspaceCell(mounted, flat.other)) == "Level 2", "a row directly in a top-level group")
        // Telling the level changes nothing that is drawn: the drawing's depth stays 0 in this window.
        #expect(workspaceCell(mounted, flat.other)?.currentModelForMeasurement?.depth == 0)
    }

    @Test func inAThreeLevelWindowEveryRowSaysOneLevelDeeperThanTheHeaderThatHoldsIt() async throws {
        let nested = try threeLevelWindow()
        let mounted = try await mount(nested.manager)
        defer { close(mounted) }
        #expect(levelOf(workspaceCell(mounted, nested.u)) == "Level 1")
        #expect(levelOf(headerCell(mounted, nested.p)) == "Level 1")
        #expect(levelOf(workspaceCell(mounted, nested.w1)) == "Level 2")
        #expect(levelOf(headerCell(mounted, nested.q)) == "Level 2")
        #expect(levelOf(workspaceCell(mounted, nested.w2)) == "Level 3")
        #expect(levelOf(headerCell(mounted, nested.r)) == "Level 3")
        #expect(levelOf(workspaceCell(mounted, nested.w3)) == "Level 4")
    }

    @Test func aHeaderWithNoWorkspaceOfItsOwnHasTheFoldHelpThroughTheMountedCell() async throws {
        let flat = try flatWindow()
        let mounted = try await mount(flat.manager)
        defer { close(mounted) }
        #expect(headerCell(mounted, flat.empty)?.accessibilityHelp() == "Fold or unfold the group")
        #expect(headerCell(mounted, flat.own)?.accessibilityHelp() == nil)
    }
}
