import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

/// Window-side stand-in for the nested coordinator tests (#cm-106). Closing a workspace
/// removes it and runs the group fix-up the app's close path runs: the group it stood behind
/// promotes its next workspace, keeps its header when it holds groups, or is removed.
@MainActor
final class NestingGroupHost: WorkspaceGroupHosting {
    typealias Tab = NestingStubTab

    let model: WorkspacesModel<NestingStubTab>
    private(set) var orderChanges: [[UUID]] = []
    private(set) var closedWorkspaceIds: [UUID] = []
    private(set) var selectedWorkspaceIds: [UUID] = []
    private(set) var subtractedSidebarSelections: [(hidden: Set<UUID>, focused: UUID?)] = []
    /// Workspaces the host declines to close, to check that a delete counts only what really closed.
    var refusesToClose: Set<UUID> = []
    var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var localizedAutoGroupNameFormat: String { "Group %lld" }
    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement { .end }
    private var created = 0

    init(model: WorkspacesModel<NestingStubTab>) {
        self.model = model
    }

    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        orderChanges.append(movedWorkspaceIds)
    }

    func createGroupAnchorWorkspace(
        title: String,
        workingDirectory: String?,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> NestingStubTab? {
        newTab(select: select)
    }

    func createWorkspaceForGroup(
        title: String?,
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        initialBrowserURL: URL?,
        initialBrowserOmnibarVisible: Bool,
        initialBrowserTransparentBackground: Bool,
        inheritWorkingDirectory: Bool,
        select: Bool,
        applyCreationTitleAsCustomTitle: Bool
    ) -> NestingStubTab? {
        newTab(select: select)
    }

    private func newTab(select: Bool) -> NestingStubTab {
        created += 1
        let tab = NestingStubTab(id: UUID(), groupId: nil, isPinned: false)
        model.tabs.append(tab)
        if select { model.selectedTabId = tab.id }
        return tab
    }

    func closeWorkspaceForGroupDeletion(_ tab: NestingStubTab, recordHistory: Bool) {
        closedWorkspaceIds.append(tab.id)
        guard model.tabs.count > 1, !refusesToClose.contains(tab.id),
              let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        model.tabs.remove(at: index)
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: tab.id)
    }

    func selectWorkspace(_ tab: NestingStubTab) {
        selectedWorkspaceIds.append(tab.id)
        model.selectedTabId = tab.id
    }

    func collapseSidebarSelectionForGroupCreation(hiddenWorkspaceIds: Set<UUID>, anchorId: UUID) {
        sidebarSelectedWorkspaceIds = [anchorId]
    }

    func subtractSidebarSelection(hiddenWorkspaceIds: Set<UUID>, focusedWorkspaceId: UUID?) {
        subtractedSidebarSelections.append((hiddenWorkspaceIds, focusedWorkspaceId))
        sidebarSelectedWorkspaceIds.subtract(hiddenWorkspaceIds)
    }

    func normalizedGroupIconSymbol(_ symbol: String?) -> String? { symbol }

    func workspaceGroupNameDidChange() {}
}

/// A nested window with its two coordinators and host, built from a ``NestWindow``.
@MainActor
struct NestedWorld {
    let model: WorkspacesModel<NestingStubTab>
    let host: NestingGroupHost
    let groups: WorkspaceGroupCoordinator<NestingStubTab>
    let reorder: WorkspaceReorderCoordinator<NestingStubTab>

    init(_ window: NestWindow, selected: UUID? = nil) {
        model = upstreamModel(window)
        host = NestingGroupHost(model: model)
        groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        model.selectedTabId = selected
    }

    /// The window as stored now.
    var window: NestWindow { snapshot(model) }

    /// The six rules over the stored window; empty when they hold.
    func violations(_ lab: Labels) -> [String] { nestViolations(window, lab) }

    func compact(_ lab: Labels) -> String { cmuxCompact(window, lab) }
}

/// ``compact(_:_:layout:canonical:)`` reads a layout from a window; named apart so a type with a
/// member called `compact` can still reach it.
func cmuxCompact(_ window: NestWindow, _ lab: Labels) -> String {
    compact(window, lab)
}
