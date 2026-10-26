import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxWorkspaces
import SwiftUI

/// How a drag that starts on a row in a status group is judged before the generic drop rules run.
enum StatusGroupInterimDrop { // (#cm-110.1)
    case notStatusRelated
    case refused
    case plan(SidebarWorkspaceReorderDropPlan)
}

/// The sidebar's render items once the status area is in, and the ⌘ numbering they leave unchanged. (#cm-110.1)
struct SidebarStatusRenderItemsResolution {
    let items: [SidebarWorkspaceRenderItem]
    /// Numbered from the items before any projection, so the area never changes a ⌘ number (`04:90`).
    let numberedWorkspaceIndexById: [UUID: Int]
    let workspacesSectionMemberIds: Set<UUID>
    let pinnedSectionMemberIds: Set<UUID> // (#cm-110.5)

    init(items: [SidebarWorkspaceRenderItem], numberedWorkspaceIndexById: [UUID: Int],
         workspacesSectionMemberIds: Set<UUID> = [], pinnedSectionMemberIds: Set<UUID> = []) {
        self.items = items
        self.numberedWorkspaceIndexById = numberedWorkspaceIndexById
        self.workspacesSectionMemberIds = workspacesSectionMemberIds
        self.pinnedSectionMemberIds = pinnedSectionMemberIds
    }
}

// All of cm-110.1's sidebar wiring that is more than a call site lives here, as functions with explicit
// types, so `ContentView.swift`'s body does not pay for type-checking it (measured: 4 min 34 s -> 21 min 20 s).
extension VerticalTabsSidebar { // (#cm-110.1)
    /// Rows in a status group sit under the `Statuses` header and the group's header.
    static let statusMemberDepth: Int = 2

    // MARK: Projection

    static func statusGroupProjectionItems(tabs: [Workspace], list: WorkspaceStatusList, groups: [WorkspaceGroup]) -> [WorkspaceStatusGroupProjectionItem] {
        let memberships = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: tabs,
            groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }))
        var items: [WorkspaceStatusGroupProjectionItem] = []
        items.reserveCapacity(tabs.count)
        for tab in tabs {
            items.append(statusGroupProjectionItem(tab, list: list,
                groupId: groups.isEmpty ? tab.groupId : (memberships[tab.id] ?? nil), isPinned: tab.isPinned))
        }
        return items
    }

    /// The status groups of the loose workspaces, or `nil` when no area shows: Workspace Todo Controls off (`04:91`,
    /// `09:434`: a list in the file then changes nothing), no list in use, or a list with no statuses.
    /// Builds the same immutable input for rendering and for a selection whose group context is already known.
    static func statusGroupProjectionItem(_ workspace: Workspace, list: WorkspaceStatusList,
        groupId: UUID?, isPinned: Bool) -> WorkspaceStatusGroupProjectionItem {
        .init(workspaceId: workspace.id, groupId: groupId, isPinned: isPinned,
            isStatusHidden: workspace.todoState.statusHidden,
            normalizedColorHex: workspace.customColor.flatMap(WorkspaceColorHex.normalized),
            resolution: workspace.statusResolution(list: list))
    }

    static func statusGroupProjection(
        items: [WorkspaceStatusGroupProjectionItem],
        list: WorkspaceStatusList,
        colorHexes: [String: String],
        controlsEnabled: Bool,
        storedOrder: [String]? = nil,
        workspaceGroups: [WorkspaceGroup]
    ) -> WorkspaceStatusGroupProjection? {
        guard controlsEnabled else { return nil }
        guard let loose = WorkspaceStatusGroupProjection.project(
            workspaces: items,
            list: list,
            resolvedHexByStatusId: colorHexes,
            storedOrder: storedOrder
        ) else { return nil }
        let grouped = WorkspaceGroupStatusProjection(groups: workspaceGroups,
            workspaces: items.map { .init(id: $0.workspaceId, groupId: $0.groupId, isPinned: $0.isPinned) }, list: list)
        return WorkspaceStatusGroupProjection(groups: loose.groups, workspaceGroups: workspaceGroups.isEmpty ? nil : grouped)
    }

    /// The projection of the app's own state: his list in use, the colors the app resolved, the controls setting.
    static func currentStatusGroupProjection(tabs: [Workspace], groups: [WorkspaceGroup], storedOrder: [String]? = nil) -> WorkspaceStatusGroupProjection? {
        let controlsEnabled: Bool = WorkspaceTodoFeature.isEnabled
        guard controlsEnabled else { return nil }
        let list: WorkspaceStatusList = AppDelegate.statusListInUse
        return statusGroupProjection(
            items: statusGroupProjectionItems(tabs: tabs, list: list, groups: groups),
            list: list,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            controlsEnabled: controlsEnabled,
            storedOrder: storedOrder,
            workspaceGroups: groups
        )
    }

    /// The nested groups the sidebar draws under a status group instead of inside their parent (#cm-110.3), read from the same
    /// projection the renderer uses, so the built-in list and Workspace Todo Controls off give none. Every layer that
    /// asks "is this group hidden by its parent's fold" reads this one answer (the row walk, the ⌘ numbers, the
    /// selection moves), never a stored status on its own.
    static func groupsShownUnderAStatus(tabs: [Workspace], groups: [WorkspaceGroup]) -> Set<UUID> {
        // A nested root needs a nested group with a stored status; the projection decides the rest. Saves the
        // projection's cost in every window that has none.
        guard groups.contains(where: { $0.parentGroupId != nil && $0.statusId != nil }) else { return [] }
        return currentStatusGroupProjection(tabs: tabs, groups: groups)?.workspaceGroups?.nestedRootGroupIds ?? []
    }

    /// The base items of the list, before the status area takes its rows: the nested walk draws a group shown under a
    /// status even when its parent is folded, so the status area can pick its rows from the walk. (#cm-110.3)
    static func baseRenderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup],
        effectiveMembership: [UUID: UUID?]? = nil,
        statusGroupProjection: WorkspaceStatusGroupProjection?
    ) -> [SidebarWorkspaceRenderItem] {
        SidebarWorkspaceRenderItem.renderItems(tabs: tabs, groupsById: groupsById, orderedGroups: orderedGroups,
            effectiveMembership: effectiveMembership,
            groupsShownUnderAStatus: statusGroupProjection?.workspaceGroups?.nestedRootGroupIds ?? [])
    }

    /// The workspaces a folded group's badge sums: everything inside it except the rows shown under a status, which
    /// show their own unread where they are (ruling (23), #cm-110.3). A group inside a projected root keeps all of its
    /// own, and Mark All Read and Delete Group still use every workspace inside.
    static func foldedGroupBadgeWorkspaceIds(group: WorkspaceGroup, memberWorkspaceIds: [UUID],
        projection: WorkspaceStatusGroupProjection?) -> [UUID] {
        guard let grouped = projection?.workspaceGroups, grouped.rootIdByGroupId[group.id] == nil else { return memberWorkspaceIds }
        return memberWorkspaceIds.filter { grouped.statusIdByWorkspaceId[$0] == nil }
    }

    /// Colors a status names have no color group among the unpinned rows; empty when no area shows.
    static func statusColorHexesWithoutColorGroup(
        for projection: WorkspaceStatusGroupProjection?,
        colorHexes: [String: String]
    ) -> Set<String> {
        guard projection != nil else { return [] }
        var hexes = Set<String>()
        for hex in colorHexes.values {
            if let normalized = WorkspaceColorHex.normalized(hex) { hexes.insert(normalized) }
        }
        return hexes
    }

    static func statusColorHexesWithoutColorGroup(for projection: WorkspaceStatusGroupProjection?) -> Set<String> {
        statusColorHexesWithoutColorGroup(
            for: projection,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:]
        )
    }

    /// The color groups of the loose rows: every status-group member is left out, and a color a status names has no
    /// color group among the unpinned rows. The render and the perform-time re-check both build it here.
    static func colorSectionProjection(
        workspaces: [SidebarWorkspaceColorSectionWorkspaceSnapshot],
        collapsedHexes: Set<String>,
        statusGroupProjection: WorkspaceStatusGroupProjection?,
        colorHexes: [String: String],
        paletteEntries: [WorkspaceColorPaletteEntry]
    ) -> SidebarWorkspaceColorSectionProjection {
        SidebarWorkspaceColorSectionProjection.project(
            workspaces: workspaces,
            paletteEntries: paletteEntries,
            collapsedHexes: collapsedHexes,
            excludedWorkspaceIds: statusGroupProjection?.allMemberWorkspaceIds ?? [],
            unpinnedExcludedHexes: statusColorHexesWithoutColorGroup(for: statusGroupProjection, colorHexes: colorHexes)
        )
    }

    static func colorSectionProjection(
        workspaces: [SidebarWorkspaceColorSectionWorkspaceSnapshot],
        collapsedHexes: Set<String>,
        statusGroupProjection: WorkspaceStatusGroupProjection?
    ) -> SidebarWorkspaceColorSectionProjection {
        colorSectionProjection(
            workspaces: workspaces,
            collapsedHexes: collapsedHexes,
            statusGroupProjection: statusGroupProjection,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            paletteEntries: WorkspaceTabColorSettings.labeledPaletteEntries()
        )
    }

    // MARK: Render items

    /// The items the list draws: the base items without the rows a status group holds, the color groups on them, and
    /// the `Statuses` area last.
    static func resolveRenderItems(
        colorSectionProjection: SidebarWorkspaceColorSectionProjection,
        baseItems: [SidebarWorkspaceRenderItem],
        statusGroupProjection: WorkspaceStatusGroupProjection?,
        folds: WorkspaceStatusGroupsState = WorkspaceStatusGroupsState(),
        tabs: [Workspace] = [], groups: [WorkspaceGroup]
    ) -> SidebarStatusRenderItemsResolution {
        SidebarWorkspaceGroupStatusRenderItems().resolve(colorSections: colorSectionProjection, base: baseItems,
            projection: statusGroupProjection, folds: folds, tabs: tabs, groups: groups)
    }

    /// A row's indent level. The nested-group depths stay the only thing in `rowDepthById`, because an empty map
    /// is how the drop lines know a window holds no nested group (`SidebarNestedDropLine.level`); a row in a status
    /// group takes its depth from here instead. A row under the `Pinned` or `Workspaces` header sits `sectionIndent`
    /// levels further in (#cm-110.12); `heldLevels` is the one step a member of a group or color group already has in a
    /// window whose depth map is empty. With no section header both leave a row's depth as it was.
    static func rowDepth(
        of workspaceId: UUID,
        rowDepthById: [UUID: Int],
        statusGroupProjection: WorkspaceStatusGroupProjection?,
        sectionIndent: Int = 0, // (#cm-110.12)
        heldLevels: Int = 0 // (#cm-110.12)
    ) -> Int {
        if let depth = statusGroupProjection?.workspaceGroups?.depthById[workspaceId] { return depth }
        if let depth = rowDepthById[workspaceId] { return depth + sectionIndent } // (#cm-110.12)
        if statusGroupProjection?.contains(workspaceId: workspaceId) == true { return statusMemberDepth }
        return sectionIndent > 0 ? heldLevels + sectionIndent : 0 // (#cm-110.12)
    }

    /// A group header's display depth in this list: its group depth, plus the `Pinned` or `Workspaces` level it sits under (#cm-110.12).
    /// Both header builders (the AppKit model and the SwiftUI snapshot) take it from here.
    static func groupHeaderDepth(of groupId: UUID, renderContext: WorkspaceListRenderContext) -> Int { // (#cm-110.12)
        rowDepth(of: groupId, rowDepthById: renderContext.rowDepthById, statusGroupProjection: renderContext.statusGroupProjection,
            sectionIndent: renderContext.sectionIndentLevels(of: .group(groupId)))
    }

    /// The level a drop line lands at in this list, for the workspace drags, the tab landings and the debug drop alike (#cm-110.12).
    static func dropLineLevel(for plan: SidebarWorkspaceReorderDropPlan, renderContext: WorkspaceListRenderContext) -> Int? { // (#cm-110.12)
        workspaceProjectedStatusDropLineLevel(for: plan, depthById: renderContext.rowDepthById,
            projection: renderContext.statusGroupProjection, sectionIndent: renderContext.sectionIndent)
    }

    // MARK: Drag

    /// Interim drag rule (Piece 1): a row in a status group only moves inside its own group, and nothing
    /// from outside drops on a status group's rows. Piece 4 replaces it.
    static func statusGroupInterimDrop(
        draggedTabId: UUID,
        basePlan: SidebarWorkspaceReorderDropPlan,
        projection: WorkspaceStatusGroupProjection?,
        permitsGroupEscape: Bool = false
    ) -> StatusGroupInterimDrop {
        guard let projection else { return .notStatusRelated }
        let draggedGroup: WorkspaceStatusGroup? = projection.groups.first { $0.memberWorkspaceIds.contains(draggedTabId) }
        if let draggedGroup {
            if permitsGroupEscape, SidebarStatusGroupDropRules().permitsLeavingStatusGroup(action: basePlan.action) {
                return .plan(basePlan)
            }
            guard let indicator = basePlan.indicator,
                  let targetWorkspaceId = indicator.tabId,
                  draggedGroup.memberWorkspaceIds.contains(targetWorkspaceId) else {
                return .refused
            }
            return .plan(
                SidebarWorkspaceReorderDropPlan(
                    draggedWorkspaceId: draggedTabId,
                    indicator: indicator,
                    indicatorScope: .raw,
                    action: .statusGroupMove(
                        statusId: draggedGroup.statusId,
                        targetWorkspaceId: targetWorkspaceId,
                        insertBefore: indicator.edge == .top,
                        memberWorkspaceIds: draggedGroup.memberWorkspaceIds
                    )
                )
            )
        }
        if let targetWorkspaceId = basePlan.indicator?.tabId, projection.contains(workspaceId: targetWorkspaceId) {
            return .refused
        }
        return .notStatusRelated
    }

    /// Whether a planned `.statusGroupMove` still holds against a status projection built at perform time.
    static func statusGroupMoveHolds(
        freshProjection: WorkspaceStatusGroupProjection?,
        statusId: String,
        memberWorkspaceIds: [UUID],
        draggedWorkspaceId: UUID,
        targetWorkspaceId: UUID
    ) -> Bool {
        guard let freshGroup = freshProjection?.group(for: statusId) else { return false }
        return freshGroup.memberWorkspaceIds == memberWorkspaceIds
            && freshGroup.memberWorkspaceIds.contains(draggedWorkspaceId)
            && freshGroup.memberWorkspaceIds.contains(targetWorkspaceId)
    }

    /// Performs `.statusGroupMove` after re-checking the members against a status projection built at perform time.
    @MainActor
    static func performStatusGroupMove(
        plan: SidebarWorkspaceReorderDropPlan,
        statusId: String,
        targetWorkspaceId: UUID,
        insertBefore: Bool,
        memberWorkspaceIds: [UUID],
        freshProjection: WorkspaceStatusGroupProjection?,
        tabManager: TabManager
    ) -> Bool {
        guard statusGroupMoveHolds(
            freshProjection: freshProjection,
            statusId: statusId,
            memberWorkspaceIds: memberWorkspaceIds,
            draggedWorkspaceId: plan.draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else { return false }
        return tabManager.reorderWorkspaceWithinColorSection(
            tabId: plan.draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            insertBefore: insertBefore,
            memberWorkspaceIds: memberWorkspaceIds
        )
    }

    // MARK: Headers

    /// Shared header construction; tests exercise the same unread and action wiring as the sidebar.
    static func statusHeaderConfiguration(
        kind: SidebarStatusHeaderKind,
        presentation: SidebarStatusGroupPresentation?,
        memberCount: Int,
        memberIds: Set<UUID>,
        folds: WorkspaceStatusGroupsState,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        onToggle: @escaping @MainActor () -> Void,
        isBeingDragged: Bool = false,
        onFocusAnchor: @escaping (NSEvent.ModifierFlags) -> Void = { _ in }
    ) -> SidebarWorkspaceTableRowConfiguration {
        let collapsed: Bool
        switch kind {
        case .statusesArea: collapsed = folds.areaCollapsed
        case .workspacesArea: collapsed = folds.workspacesCollapsed == true
        case .pinnedArea: collapsed = folds.pinnedCollapsed == true // (#cm-110.5)
        case .statusGroup(let id): collapsed = folds.collapsedStatusIds.contains(id)
        }
        let model = statusHeaderModel(
            kind: kind, presentation: presentation, memberCount: memberCount,
            unreadCount: 0, isCollapsed: collapsed, environment: environment, isBeingDragged: isBeingDragged
        )
        var configuration = SidebarWorkspaceTableRowConfiguration(
            statusHeaderModel: model, statusHeaderKind: kind,
            actions: statusHeaderActions(onFocusAnchor: onFocusAnchor),
            colorSectionToggle: onToggle,
            environment: environment, unreadDependencyWorkspaceIds: memberIds,
            unreadRebuild: { snapshot in
                var fresh = model
                fresh.anchorUnreadCount = collapsed
                    ? memberIds.reduce(0) { $0 + snapshot.unreadCount(forWorkspaceId: $1) } : 0
                return fresh
            }
        )
        // A header stands for no workspace, unless it is folded: then it stands for the members it hides. // (#cm-110.5)
        configuration.dropTabIds = collapsed ? Array(memberIds) : [] // (#cm-110.5)
        return configuration
    }

    /// What each status group's header shows, by status id. The parent builds it once per pass, so no row reads the
    /// status store.
    static func statusGroupPresentations(
        projection: WorkspaceStatusGroupProjection?,
        list: WorkspaceStatusList,
        colorHexes: [String: String]
    ) -> [String: SidebarStatusGroupPresentation] {
        var presentations: [String: SidebarStatusGroupPresentation] = [:]
        for group in projection?.groups ?? [] {
            presentations[group.statusId] = SidebarStatusGroupPresentation.resolve(
                statusId: group.statusId,
                list: list,
                colorHexes: colorHexes
            )
        }
        return presentations
    }

    static func statusGroupPresentations(projection: WorkspaceStatusGroupProjection?) -> [String: SidebarStatusGroupPresentation] {
        guard projection != nil else { return [:] }
        return statusGroupPresentations(
            projection: projection,
            list: AppDelegate.statusListInUse,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:]
        )
    }

    // SwiftUI list rows receive values and an action captured above the lazy boundary.
    static func sidebarStatusesAreaHeaderRow(
        renderContext: WorkspaceListRenderContext,
        unreadSnapshot: SidebarUnreadSnapshot,
        onToggle: @escaping @MainActor () -> Void
    ) -> SidebarStatusesAreaSwiftUIHeader {
        let folds = renderContext.statusGroupFolds
        let memberIds = renderContext.statusGroupProjection?.allDisplayMemberWorkspaceIds ?? []
        return SidebarStatusesAreaSwiftUIHeader(
            groupCount: renderContext.statusGroupProjection?.groups.count ?? 0,
            isCollapsed: folds.areaCollapsed,
            unreadCount: folds.areaCollapsed ? memberIds.reduce(0) { $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1) } : 0,
            onToggle: onToggle
        )
    }

    static func sidebarStatusGroupHeaderRow(
        statusId: String,
        projection: WorkspaceStatusGroupProjection?,
        presentations: [String: SidebarStatusGroupPresentation],
        listWidth: CGFloat?,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        folds: WorkspaceStatusGroupsState = WorkspaceStatusGroupsState(),
        unreadSnapshot: SidebarUnreadSnapshot = SidebarUnreadSnapshot(),
        onToggle: @escaping @MainActor () -> Void = {}
    ) -> SidebarStatusGroupSwiftUIHeader? {
        guard let group = projection?.group(for: statusId),
              let presentation = presentations[statusId] else { return nil }
        let collapsed = folds.collapsedStatusIds.contains(statusId)
        let memberIds = projection?.displayMemberWorkspaceIds(for: group.statusId) ?? []
        let unreadCount = collapsed
            ? memberIds.reduce(0) { $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1) } : 0
        let model = Self.statusHeaderModel(
            kind: .statusGroup(statusId), presentation: presentation,
            memberCount: memberIds.count, unreadCount: unreadCount,
            isCollapsed: collapsed, environment: environment
        )
        return SidebarStatusGroupSwiftUIHeader(
            statusId: statusId, presentation: presentation,
            memberCount: memberIds.count, isCollapsed: collapsed,
            listWidth: listWidth, colorScheme: environment.colorScheme,
            fontScale: model.fontScale,
            globalFontMagnificationPercent: model.globalFontMagnificationPercent,
            unreadCount: unreadCount, onToggle: onToggle
        )
    }

    /// The header row's model: what the AppKit cell draws.
    static func statusHeaderModel(
        kind: SidebarStatusHeaderKind,
        presentation: SidebarStatusGroupPresentation?,
        memberCount: Int,
        unreadCount: Int,
        isCollapsed: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        isBeingDragged: Bool = false
    ) -> SidebarGroupHeaderRowModel {
        let identity: UUID
        let name: String
        let depth: Int
        let holdsGroups: Bool
        switch kind {
        case .statusesArea:
            identity = SidebarStatusHeaderIdentity.statusesAreaUUID
            name = SidebarStatusHeaderText.statusesAreaTitle
            depth = 0
            holdsGroups = true
        case .workspacesArea:
            identity = SidebarStatusHeaderIdentity.workspacesAreaUUID
            name = SidebarStatusHeaderText.workspacesAreaTitle
            depth = 0
            holdsGroups = true
        case .pinnedArea: // (#cm-110.5)
            identity = SidebarStatusHeaderIdentity.pinnedAreaUUID
            name = SidebarStatusHeaderText.pinnedAreaTitle
            depth = 0
            holdsGroups = true
        case .statusGroup(let statusId):
            identity = SidebarStatusHeaderIdentity.uuid(forStatusId: statusId)
            name = presentation?.name ?? statusId
            depth = 1
            holdsGroups = false
        }
        var model = SidebarGroupHeaderRowModel(
            groupId: identity,
            anchorWorkspaceId: identity,
            name: name,
            iconSymbol: "",
            tintHex: presentation?.tintHex,
            customColorHex: nil,
            isCollapsed: isCollapsed,
            isPinned: false,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: memberCount,
            anchorUnreadCount: unreadCount,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: CGFloat(environment.globalFontMagnificationPercent) / 100,
            globalFontMagnificationPercent: environment.globalFontMagnificationPercent,
            cwdContextMenuItems: [],
            rowSpacing: 0,
            isFirstRow: false,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            colorSchemeIsDark: environment.colorScheme == .dark,
            depth: depth,
            hasOwnWorkspace: false,
            isFoldedOverSelection: false,
            holdsGroups: holdsGroups,
            statusHeaderKind: kind,
            statusGlyph: presentation?.glyph
        )
        model.statusBehavesAs = presentation?.behavesAs ?? .working
        return model
    }

    /// Status headers keep workspace-only actions disabled; the row configuration supplies the shared fold toggle.
    static func statusHeaderActions(
        onFocusAnchor: @escaping (NSEvent.ModifierFlags) -> Void = { _ in }
    ) -> SidebarGroupHeaderRowActions {
        SidebarGroupHeaderRowActions(
            onToggleCollapsed: {},
            onFocusAnchor: onFocusAnchor,
            onTapPlus: {},
            onRunResolvedItem: { _ in },
            onRename: {},
            onSetColor: { _ in },
            onPromptCustomColor: {},
            onTogglePinned: {},
            onMarkRead: {},
            onMarkUnread: {},
            onClearLatestNotifications: {},
            onMarkAllRead: {},
            onMarkAllUnread: {},
            onUngroup: {},
            onDelete: {},
            onEditConfig: {},
            onOpenDocs: {}
        )
    }

    func sidebarStatusesAreaTableConfiguration(
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let toggle = makeStatusHeaderToggleAction()
        return Self.statusHeaderConfiguration(
            kind: .statusesArea, presentation: nil,
            memberCount: renderContext.statusGroupProjection?.groups.count ?? 0,
            memberIds: renderContext.statusGroupProjection?.allDisplayMemberWorkspaceIds ?? [],
            folds: renderContext.statusGroupFolds, environment: renderContext.environment,
            onToggle: { toggle(.statusesArea) },
            isBeingDragged: dragState.draggedTabId == SidebarStatusHeaderIdentity.statusesAreaUUID
        )
    }

    func sidebarStatusGroupTableConfiguration(
        statusId: String,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration? {
        guard let group = renderContext.statusGroupProjection?.group(for: statusId),
              let presentation = renderContext.statusGroupPresentationById[statusId] else { return nil }
        let toggle = makeStatusHeaderToggleAction()
        let memberIds = renderContext.statusGroupProjection?.displayMemberWorkspaceIds(for: group.statusId) ?? []
        return Self.statusHeaderConfiguration(
            kind: .statusGroup(statusId), presentation: presentation,
            memberCount: memberIds.count, memberIds: memberIds,
            folds: renderContext.statusGroupFolds, environment: renderContext.environment,
            onToggle: { toggle(.statusGroup(statusId)) },
            isBeingDragged: dragState.draggedTabId == SidebarStatusHeaderIdentity.uuid(forStatusId: statusId)
        )
    }

    /// Capture the store above the lazy list boundary. Rows hold only this action and immutable values.
    func makeStatusHeaderToggleAction() -> @MainActor (SidebarStatusHeaderKind) -> Void {
        let state = sidebarState
        let manager = tabManager
        return { kind in
            state.prepareWorkspaceSections(tabManager: manager)
            switch kind {
            case .statusesArea: state.toggleStatusesArea()
            case .workspacesArea: state.toggleWorkspacesArea()
            case .pinnedArea: state.togglePinnedArea()
            case .statusGroup(let id): state.toggleStatusGroup(id: id)
            }
        }
    }
}
