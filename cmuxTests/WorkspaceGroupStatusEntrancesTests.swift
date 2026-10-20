import AppKit
import CmuxCommandPalette
import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Group status UI entrances", .serialized)
struct WorkspaceGroupStatusEntrancesTests {
    private let list = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "done", name: "Done", color: "#334455", icon: .shape(.check)),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working, color: "#00C65F", icon: .shape(.half)),
        WorkspaceStatusEntry(id: "todo", name: "Future", color: "#765432", icon: .shape(.dottedRing))
    ], source: .file)
    private let colors = ["done": "#334455", "doing": "#00C65F", "todo": "#765432"]
    private struct Fixture {
        let manager: TabManager
        let anchor: Workspace
        let member: Workspace
        let groupId: UUID
    }
    private func fixture() -> Fixture {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let anchor = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let member = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let id = UUID()
        anchor.groupId = id; member.groupId = id
        manager.workspaceGroups = [WorkspaceGroup(id: id, name: "Group", isCollapsed: false, isPinned: false,
                                                 anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil)]
        manager.selectedTabId = anchor.id
        return Fixture(manager: manager, anchor: anchor, member: member, groupId: id)
    }
    private func actions(_ f: Fixture, enabled: Bool = true) -> WorkspaceGroupStatusUIActions {
        .init(tabManager: f.manager, writer: WorkspaceGroupStatusActions(list: list, resolveColor: { $0 }), controlsEnabled: enabled)
    }
    private func menu(_ f: Fixture, enabled: Bool = true) -> SidebarWorkspaceGroupStatusMenu? {
        SidebarWorkspaceGroupStatusMenu.resolve(group: f.manager.workspaceGroups[0], list: list,
                                               colorHexes: colors, controlsEnabled: enabled)
    }
    private func withApp(_ f: Fixture, body: (AppDelegate) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let entries = try JSONEncoder().encode(list.entries)
        try ("{\"workspaceStatuses\":" + String(decoding: entries, as: UTF8.self) + "}").write(to: file, atomically: true, encoding: .utf8)
        let suite = "GroupStatusEntrances." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults, resolveColor: { $0 },
                                             paletteFingerprint: { "fixture" }, clock: ContinuousClock())
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        delegate.tabManager = f.manager
        AppDelegate.shared = delegate
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let oldControls = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            AppDelegate.shared = previous
            if let oldControls { UserDefaults.standard.set(oldControls, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body(delegate)
    }

    @Test func selectedAnchorPicksTheGroupWithoutTouchingItsWorkspace() {
        let f = fixture(); var fallback: [UUID] = []
        let anchorOverride = f.anchor.todoState.statusOverride
        let anchorOwn = f.anchor.todoState.ownStatus
        #expect(actions(f).applySelected(.status(id: "doing"), workspaceApply: { _, workspaces in fallback = workspaces.map(\.id) }))
        #expect(f.manager.workspaceGroups[0].statusId == "doing")
        #expect(f.manager.workspaceGroups[0].customColor == "#00C65F")
        #expect(fallback.isEmpty)
        #expect(f.anchor.todoState.statusOverride == anchorOverride && f.anchor.todoState.ownStatus == anchorOwn)
    }
    @Test func selectedMemberKeepsTheWorkspaceActionPath() {
        let f = fixture(); f.manager.selectedTabId = f.member.id
        var fallback: [(WorkspaceStatusPickAction, [UUID])] = []
        actions(f).applySelected(.done, workspaceApply: { action, workspaces in fallback.append((action, workspaces.map(\.id))) })
        #expect(fallback.count == 1)
        #expect(fallback.first?.0 == .done)
        #expect(fallback.first?.1 == [f.member.id])
        #expect(f.manager.workspaceGroups[0].statusId == nil)
    }
    @Test func controlsOffRefusesEveryGroupUIWrite() {
        let f = fixture(); let before = f.manager.workspaceGroups
        var fallbackCalls = 0
        #expect(!actions(f, enabled: false).applySelected(.done, workspaceApply: { _, _ in fallbackCalls += 1 }))
        #expect(!actions(f, enabled: false).applyGroup(.status(id: "doing"), groupId: f.groupId))
        #expect(!actions(f, enabled: false).cycleSelected(workspaceCycle: { _ in fallbackCalls += 1 }))
        #expect(f.manager.workspaceGroups == before)
        #expect(fallbackCalls == 0)
    }
    @Test func selectedGroupCycleStartsAtBottomAndWraps() {
        let f = fixture(); let sut = actions(f); var fallbackCalls = 0
        for expected in ["todo", "doing", "done", "todo"] {
            #expect(sut.cycleSelected(workspaceCycle: { _ in fallbackCalls += 1 }))
            #expect(f.manager.workspaceGroups[0].statusId == expected)
            #expect(f.manager.workspaceGroups[0].customColor == colors[expected])
        }
        #expect(fallbackCalls == 0)
        #expect(f.anchor.todoState.statusOverride == nil && f.anchor.todoState.ownStatus == nil)
    }
    @Test func aHeaderPickTargetsItsGroupWithoutDependingOnSelection() {
        let f = fixture(); f.manager.selectedTabId = f.member.id
        #expect(actions(f).applyGroup(.status(id: "doing"), groupId: f.groupId))
        #expect(f.manager.workspaceGroups[0].statusId == "doing")
        #expect(f.manager.workspaceGroups[0].customColor == "#00C65F")
        #expect(f.member.todoState.statusOverride == nil && f.member.todoState.ownStatus == nil)
    }
    @Test func paletteAutoOnAGroupClearsStatusAndColor() {
        let f = fixture(); f.manager.workspaceGroups[0].statusId = "doing"; f.manager.workspaceGroups[0].customColor = "#00C65F"
        actions(f).applySelected(.auto, workspaceApply: { _, _ in Issue.record("group Auto reached workspace") })
        #expect(f.manager.workspaceGroups[0].statusId == nil)
        #expect(f.manager.workspaceGroups[0].customColor == nil)
        #expect(f.anchor.todoState.statusOverride == nil && f.anchor.todoState.ownStatus == nil)
    }
    @Test func realPaletteHandlersUseTheCurrentlySelectedGroup() throws {
        let f = fixture()
        try withApp(f) { _ in
            var registry = CommandPaletteHandlerRegistry(); var fallbackCalls = 0
            WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: f.manager, list: list,
                                                          controlsEnabled: true, apply: { _, _ in fallbackCalls += 1 })
            registry.handler(for: "palette.workspaceStatus.doing")?()
            #expect(f.manager.workspaceGroups[0].statusId == "doing")
            registry.handler(for: "palette.workspaceStatusAuto")?()
            #expect(f.manager.workspaceGroups[0].statusId == nil && f.manager.workspaceGroups[0].customColor == nil)
            registry.handler(for: WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId)?()
            #expect(f.manager.workspaceGroups[0].statusId == "done")
            #expect(fallbackCalls == 0)
            #expect(f.anchor.todoState.statusOverride == nil && f.anchor.todoState.ownStatus == nil)
            f.manager.selectedTabId = f.member.id
            registry.handler(for: "palette.workspaceStatus.doing")?()
            #expect(fallbackCalls == 1)
            #expect(f.manager.workspaceGroups[0].statusId == "done")
        }
    }
    @Test func realShortcutsTargetTheGroupWhileItsAnchorIsSelected() throws {
        let f = fixture()
        try withApp(f) { delegate in
            #expect(delegate.handleMarkWorkspaceDoneShortcut())
            #expect(f.manager.workspaceGroups[0].statusId == "done")
            #expect(delegate.handleCycleWorkspaceStatusShortcut())
            #expect(f.manager.workspaceGroups[0].statusId == "todo")
            #expect(f.anchor.todoState.statusOverride == nil && f.anchor.todoState.ownStatus == nil)
        }
    }
    @Test func groupMenuIsNoneThenTheListWithCurrentTickAndGlyphs() throws {
        let f = fixture(); f.manager.workspaceGroups[0].statusId = "doing"
        let menu = try #require(menu(f))
        #expect(menu.rows.map(\.action) == [.hide, .status(id: "done"), .status(id: "doing"), .status(id: "todo")])
        #expect(menu.rows.map(\.title) == [String(localized: "workspaceGroup.status.none", defaultValue: "None"), "Done", "Doing", "Future"])
        #expect(menu.rows.map(\.isSelected) == [false, false, true, false])
        #expect(menu.rows.dropFirst().map { $0.glyph?.glyph } == list.entries.map(\.icon))
        #expect(menu.rows.dropFirst().map { $0.glyph?.colorHex } == list.entries.map { colors[$0.id] })
    }
    @Test func groupMenuIsAbsentWhenControlsAreOff() {
        #expect(menu(fixture(), enabled: false) == nil)
    }

    @Test func noCustomListHidesGroupEntrancesAndUsesWorkspaceActions() {
        let f = fixture()
        f.manager.workspaceGroups[0].statusId = "done"
        f.manager.workspaceGroups[0].customColor = "#334455"
        let before = f.manager.workspaceGroups
        let sut = WorkspaceGroupStatusUIActions(tabManager: f.manager,
            writer: .init(list: .cmuxFive, resolveColor: { $0 }), controlsEnabled: true)
        #expect(SidebarWorkspaceGroupStatusMenu.resolve(group: before[0], list: .cmuxFive,
            colorHexes: [:], controlsEnabled: true) == nil)
        #expect(SidebarWorkspaceGroupStatusGlyph.resolve(group: before[0], list: .cmuxFive,
            colorHexes: [:], controlsEnabled: true) == nil)
        #expect(!sut.applyGroup(.done, groupId: f.groupId))
        var applied: [UUID] = [], cycled: [UUID] = []
        #expect(sut.applySelected(.done, workspaceApply: { _, workspaces in applied = workspaces.map(\.id) }))
        #expect(sut.cycleSelected(workspaceCycle: { cycled.append($0.id) }))
        #expect(applied == [f.anchor.id] && cycled == [f.anchor.id])
        #expect(f.manager.workspaceGroups == before)
        var plain = before[0]
        sut.writer.applyColor("#334455", to: &plain)
        #expect(plain.customColor == "#334455" && plain.statusId == nil)
    }

    @Test(arguments: [false, true])
    func emptyListCycleReturnsFalseWithoutConsumingAnAction(_ member: Bool) {
        let f = fixture()
        if member { f.manager.selectedTabId = f.member.id }
        let before = f.manager.workspaceGroups
        let sut = WorkspaceGroupStatusUIActions(tabManager: f.manager,
            writer: .init(list: .init(entries: [], source: .file), resolveColor: { $0 }), controlsEnabled: true)
        var calls = 0
        #expect(!sut.cycleSelected(workspaceCycle: { _ in calls += 1 }))
        #expect(calls == 0 && f.manager.workspaceGroups == before)
    }

    @Test func paletteBeepsWhenItsCurrentGroupPickIsRefused() throws {
        let f = fixture()
        try withApp(f) { _ in
            var registry = CommandPaletteHandlerRegistry(), beeps = 0, fallback = 0
            let stale = WorkspaceStatusList(entries: [.init(id: "stale", name: "Stale")], source: .file)
            WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: f.manager, list: stale,
                controlsEnabled: true, apply: { _, _ in fallback += 1 }, beep: { beeps += 1 })
            let handler = try #require(registry.handler(for: "palette.workspaceStatus.stale"))
            handler()
            #expect(beeps == 1 && fallback == 0)
            #expect(f.manager.workspaceGroups[0].statusId == nil)
        }
    }
    @Test func appKitGroupStatusMenuHasItsDividerAndDispatchesPicks() throws {
        let f = fixture(); let value = try #require(menu(f)); var applied: [WorkspaceStatusPickAction] = []
        let menu = value.makeAppKit(apply: { applied.append($0) }, isDark: false)
        #expect(menu.items.count == 5)
        let first = try #require(menu.items.first)
        #expect(first.title == String(localized: "workspaceGroup.status.none", defaultValue: "None"))
        #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
        for item in menu.items where !item.isSeparatorItem {
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
        #expect(applied == [.hide, .status(id: "done"), .status(id: "doing"), .status(id: "todo")])
        #expect(menu.items.dropFirst(2).allSatisfy { $0.image != nil })
    }
    @Test func groupPopoverStartsWithNoneAndHasNoAutomaticPinFootnote() throws {
        let f = fixture(); let model = try #require(menu(f)).popoverModel
        let lanes = try #require(model.lanesOverride)
        #expect(lanes.map(\.action) == [.hide, .status(id: "done"), .status(id: "doing"), .status(id: "todo")])
        #expect(lanes.first?.isNone == true)
        #expect(model.activeOverride == nil)
    }

    private func headerModel(_ f: Fixture) -> SidebarGroupHeaderRowModel {
        var model = SidebarGroupHeaderRowModel(
            groupId: f.groupId, anchorWorkspaceId: f.anchor.id, name: "Group", iconSymbol: "folder",
            tintHex: "#00C65F", customColorHex: "#00C65F", isCollapsed: false, isPinned: false,
            isAnchorActive: false, isMultiSelected: false, multiSelectionBackgroundStyle: .clear,
            memberCount: 2, anchorUnreadCount: 0, canMarkRead: false, canMarkUnread: false,
            hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: false,
            shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0,
            fontScale: 1, globalFontMagnificationPercent: 100, cwdContextMenuItems: [], rowSpacing: 2,
            isFirstRow: true, isBeingDragged: false, topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false, colorSchemeIsDark: false
        )
        model.groupStatusGlyph = .init(status: .working, name: "Doing", glyph: .shape(.half), colorHex: "#00C65F")
        model.groupStatusMenu = menu(f)
        return model
    }
    private func headerActions() -> SidebarGroupHeaderRowActions {
        SidebarGroupHeaderRowActions(onToggleCollapsed: {}, onFocusAnchor: { _ in }, onTapPlus: {},
            onRunResolvedItem: { _ in }, onRename: {}, onSetColor: { _ in }, onPromptCustomColor: {},
            onTogglePinned: {}, onMarkRead: {}, onMarkUnread: {}, onClearLatestNotifications: {},
            onMarkAllRead: {}, onMarkAllUnread: {}, onUngroup: {}, onDelete: {}, onEditConfig: {}, onOpenDocs: {})
    }
    private func contextMenu(_ cell: SidebarGroupHeaderTableCellView) throws -> NSMenu {
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 4, y: 4),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try #require(cell.menu(for: event))
    }
    @Test func retainedHeaderReadsCurrentStatusMenuAndGateWhenOpened() throws {
        let f = fixture(); let cell = SidebarGroupHeaderTableCellView(); var enabled = true
        var actions = headerActions(); actions.statusMenu = { self.menu(f, enabled: enabled) }
        cell.configure(model: headerModel(f), actions: actions, isPointerHovering: false, contextMenuDidOpen: {}, contextMenuDidClose: {})
        let title = String(localized: "contextMenu.workspaceStatus", defaultValue: "Status")
        #expect(try contextMenu(cell).items.contains { $0.title == title })
        enabled = false
        #expect(try !contextMenu(cell).items.contains { $0.title == title })
    }
    @Test func headerGlyphOpensThePopoverWithoutSelectingItsAnchor() throws {
        let f = fixture(); let cell = SidebarGroupHeaderTableCellView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cell
        window.orderFront(nil)
        defer { cell.groupStatusPopover.close(); window.close() }
        cell.configure(model: headerModel(f), actions: headerActions(), isPointerHovering: false, contextMenuDidOpen: {}, contextMenuDidClose: {})
        cell.layoutSubtreeIfNeeded()
        #expect(!cell.groupStatusPopover.button.isHidden)
        #expect(cell.groupStatusPopover.button.frame == cell.iconFrameForTesting)
        #expect(cell.selectionPreviewShouldIgnore(cell.groupStatusPopover.button))
        cell.groupStatusPopover.button.performClick(nil)
        #expect(cell.groupStatusPopover.isShown)
    }
}
