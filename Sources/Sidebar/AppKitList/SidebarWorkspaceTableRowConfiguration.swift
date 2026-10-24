import CmuxNotifications
import SwiftUI

struct SidebarWorkspaceTableContextMenuActions {
    let didOpen: () -> Void
    let didClose: () -> Void
}

/// Immutable description of one AppKit-owned sidebar row.
@MainActor
struct SidebarWorkspaceTableRowConfiguration {
    typealias ContentFactory = (
        _ isPointerHovering: Bool,
        _ contextMenuActions: SidebarWorkspaceTableContextMenuActions
    ) -> AnyView

    let id: SidebarWorkspaceRenderItemID
    let workspaceId: UUID
    let groupId: UUID?
    let isGroupHeader: Bool
    let isColorSectionHeader: Bool
    let statusHeaderKind: SidebarStatusHeaderKind? // (#cm-110.1)
    let isPinned: Bool
    let colorSectionToggle: (@MainActor () -> Void)?
    let makeContent: ContentFactory
    /// Present when this row renders through the pure-AppKit group header cell
    /// instead of a hosted SwiftUI cell.
    let appKitGroupHeaderModel: SidebarGroupHeaderRowModel?
    let appKitGroupHeaderActions: SidebarGroupHeaderRowActions?
    /// Present when this row renders through the pure-AppKit workspace cell.
    let appKitWorkspaceRowModel: SidebarWorkspaceRowModel?
    let appKitWorkspaceRowActions: SidebarAppKitRowActions?
    /// Live workspace reference + fresh-model factory for the per-row churn
    /// pump (metadata/branch/PR updates repaint one cell, no container render).
    let appKitWorkspaceRowWorkspace: Workspace?
    let appKitWorkspaceRowRebuild: (@MainActor () -> SidebarWorkspaceRowModel)?
    /// Workspace ids whose unread summaries affect this row, plus factories
    /// that repaint only the matching AppKit cell from the latest atomic
    /// unread snapshot. They are intentionally excluded from row equality.
    let appKitUnreadDependencyWorkspaceIds: Set<UUID>
    let appKitWorkspaceUnreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarWorkspaceRowModel)?
    let appKitGroupHeaderUnreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel)?

    private let environment: SidebarWorkspaceTableEnvironmentSnapshot
    private let equivalenceValue: Any
    private let isEquivalentValue: (Any) -> Bool
    private let isHeightEquivalentValue: (Any) -> Bool

    private init(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isColorSectionHeader: Bool = false,
        statusHeaderKind: SidebarStatusHeaderKind? = nil, // (#cm-110.1)
        isPinned: Bool,
        makeContent: @escaping ContentFactory,
        appKitGroupHeaderModel: SidebarGroupHeaderRowModel?,
        appKitWorkspaceRowModel: SidebarWorkspaceRowModel?,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Any,
        isEquivalentValue: @escaping (Any) -> Bool,
        isHeightEquivalentValue: ((Any) -> Bool)? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.isColorSectionHeader = isColorSectionHeader
        self.statusHeaderKind = statusHeaderKind // (#cm-110.1)
        self.isPinned = isPinned
        self.colorSectionToggle = nil
        self.makeContent = makeContent
        self.appKitGroupHeaderModel = appKitGroupHeaderModel
        self.appKitGroupHeaderActions = nil
        self.appKitWorkspaceRowModel = appKitWorkspaceRowModel
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.appKitUnreadDependencyWorkspaceIds = []
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = nil
        self.environment = environment
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = isEquivalentValue
        self.isHeightEquivalentValue = isHeightEquivalentValue ?? isEquivalentValue
    }

    init<Content: View & Equatable>(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isPinned: Bool,
        colorSectionToggle: (@MainActor () -> Void)? = nil,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Content,
        makeContent: @escaping ContentFactory
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.isColorSectionHeader = colorSectionToggle != nil
        self.statusHeaderKind = nil // (#cm-110.1)
        self.isPinned = isPinned
        self.colorSectionToggle = colorSectionToggle
        self.environment = environment
        self.makeContent = makeContent
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.appKitUnreadDependencyWorkspaceIds = []
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = nil
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = { value in
            guard let value = value as? Content else { return false }
            return value == equivalenceValue
        }
        self.isHeightEquivalentValue = self.isEquivalentValue
    }

    init(
        groupHeaderModel: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        unreadDependencyWorkspaceIds: Set<UUID> = [],
        unreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel)? = nil
    ) {
        self.id = .group(groupHeaderModel.groupId)
        self.workspaceId = groupHeaderModel.anchorWorkspaceId
        self.groupId = groupHeaderModel.groupId
        self.isGroupHeader = true
        self.isColorSectionHeader = false
        self.statusHeaderKind = nil // (#cm-110.1)
        self.isPinned = groupHeaderModel.isPinned
        self.colorSectionToggle = nil
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = groupHeaderModel
        self.appKitGroupHeaderActions = actions
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.appKitUnreadDependencyWorkspaceIds = unreadDependencyWorkspaceIds
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = unreadRebuild
        self.equivalenceValue = groupHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarGroupHeaderRowModel else { return false }
            return value == groupHeaderModel
        }
        self.isHeightEquivalentValue = self.isEquivalentValue
    }

    init(
        workspaceRowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        groupId: UUID?,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        workspace: Workspace? = nil,
        rebuild: (@MainActor () -> SidebarWorkspaceRowModel)? = nil,
        unreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarWorkspaceRowModel)? = nil
    ) {
        self.id = .workspace(workspaceRowModel.workspaceId)
        self.workspaceId = workspaceRowModel.workspaceId
        self.groupId = groupId
        self.isGroupHeader = false
        self.isColorSectionHeader = false
        self.statusHeaderKind = nil // (#cm-110.1)
        self.isPinned = isPinned
        self.colorSectionToggle = nil
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitWorkspaceRowModel = workspaceRowModel
        self.appKitWorkspaceRowActions = actions
        self.appKitWorkspaceRowWorkspace = workspace
        self.appKitWorkspaceRowRebuild = rebuild
        self.appKitUnreadDependencyWorkspaceIds = [workspaceRowModel.workspaceId]
        self.appKitWorkspaceUnreadRebuild = unreadRebuild
        self.appKitGroupHeaderUnreadRebuild = nil
        self.equivalenceValue = workspaceRowModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value == workspaceRowModel
        }
        self.isHeightEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value.hasHeightEquivalentContent(to: workspaceRowModel)
        }
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isEquivalentValue(other.equivalenceValue)
    }

    /// Content equality restricted to fields that can change the measured row
    /// height. The height cache keys on this: a close shifts `index` /
    /// `isFirstRow` for every row below it, and treating those rows as changed
    /// would both re-measure the whole tail and drop the content-matched
    /// entries the stale-width `height(for:)` fallback depends on.
    func hasEquivalentHeightContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isHeightEquivalentValue(other.equivalenceValue)
    }

    func applyingUnreadSnapshot(_ snapshot: SidebarUnreadSnapshot) -> Self {
        if let rebuild = appKitWorkspaceUnreadRebuild,
           let actions = appKitWorkspaceRowActions {
            let model = rebuild(snapshot)
            guard model != appKitWorkspaceRowModel else { return self }
            return Self(
                workspaceRowModel: model,
                actions: actions,
                groupId: groupId,
                isPinned: isPinned,
                environment: environment,
                workspace: appKitWorkspaceRowWorkspace,
                rebuild: appKitWorkspaceRowRebuild,
                unreadRebuild: rebuild
            )
        }
        if let rebuild = appKitGroupHeaderUnreadRebuild,
           let actions = appKitGroupHeaderActions {
            let model = rebuild(snapshot)
            guard model != appKitGroupHeaderModel else { return self }
            if let statusHeaderKind { // (#cm-110.1)
                return Self( // (#cm-110.1)
                    statusHeaderModel: model, // (#cm-110.1)
                    statusHeaderKind: statusHeaderKind, // (#cm-110.1)
                    actions: actions, // (#cm-110.1)
                    colorSectionToggle: colorSectionToggle, // (#cm-110.1)
                    environment: environment, // (#cm-110.1)
                    unreadDependencyWorkspaceIds: appKitUnreadDependencyWorkspaceIds, // (#cm-110.1)
                    unreadRebuild: rebuild // (#cm-110.1)
                ) // (#cm-110.1)
            } // (#cm-110.1)
            return Self(
                groupHeaderModel: model,
                actions: actions,
                environment: environment,
                unreadDependencyWorkspaceIds: appKitUnreadDependencyWorkspaceIds,
                unreadRebuild: rebuild
            )
        }
        return self
    }

    /// Keeps the immutable paint model while dropping every live action,
    /// workspace, and hosted-content capture during retained hidden display.
    func presentationSnapshot() -> Self {
        Self(
            id: id,
            workspaceId: workspaceId,
            groupId: groupId,
            isGroupHeader: isGroupHeader,
            isColorSectionHeader: isColorSectionHeader,
            statusHeaderKind: statusHeaderKind, // (#cm-110.1)
            isPinned: isPinned,
            makeContent: { _, _ in AnyView(EmptyView()) },
            appKitGroupHeaderModel: appKitGroupHeaderModel,
            appKitWorkspaceRowModel: appKitWorkspaceRowModel,
            environment: environment,
            equivalenceValue: id,
            isEquivalentValue: { [id] in ($0 as? SidebarWorkspaceRenderItemID) == id }
        )
    }

    var estimatedHeight: CGFloat {
        if isColorSectionHeader { return 26 }
        let fontScale = CGFloat(environment.globalFontMagnificationPercent) / 100
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        if isGroupHeader || statusHeaderKind != nil { // (#cm-110.1)
            return calculator.estimatedGroupHeaderHeight(fontScale: fontScale)
        }
        return calculator.estimatedWorkspaceHeight(
            fontScale: fontScale,
            titleLineCount: 1,
            auxiliaryLineCount: 0
        )
    }
}

// MARK: Status headers (#cm-110.1)

/// The row of a status header (the `Statuses` header or a status group's header): a group header's row with the status (#cm-110.1)
/// kind set. It has no group id and is not a group header or a color section header; its id and workspace id are made (#cm-110.1)
/// from the status. It sits here, as a pure addition, because the stored properties are private to this file. (#cm-110.1)
extension SidebarWorkspaceTableRowConfiguration { // (#cm-110.1)
    init( // (#cm-110.1)
        statusHeaderModel: SidebarGroupHeaderRowModel, // (#cm-110.1)
        statusHeaderKind: SidebarStatusHeaderKind, // (#cm-110.1)
        actions: SidebarGroupHeaderRowActions, // (#cm-110.1)
        colorSectionToggle: (@MainActor () -> Void)? = nil, // (#cm-110.1)
        environment: SidebarWorkspaceTableEnvironmentSnapshot, // (#cm-110.1)
        unreadDependencyWorkspaceIds: Set<UUID> = [], // (#cm-110.1)
        unreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel)? = nil // (#cm-110.1)
    ) { // (#cm-110.1)
        let syntheticUUID: UUID // (#cm-110.1)
        let rowId: SidebarWorkspaceRenderItemID // (#cm-110.1)
        switch statusHeaderKind { // (#cm-110.1)
        case .statusGroup(let statusId): // (#cm-110.1)
            syntheticUUID = SidebarStatusHeaderIdentity.uuid(forStatusId: statusId) // (#cm-110.1)
            rowId = .statusGroup(statusId) // (#cm-110.1)
        case .statusesArea: // (#cm-110.1)
            syntheticUUID = SidebarStatusHeaderIdentity.statusesAreaUUID // (#cm-110.1)
            rowId = .statusesArea() // (#cm-110.1)
        case .workspacesArea: // (#cm-110.4)
            syntheticUUID = SidebarStatusHeaderIdentity.workspacesAreaUUID // (#cm-110.4)
            rowId = .workspacesArea() // (#cm-110.4)
        } // (#cm-110.1)
        self.id = rowId // (#cm-110.1)
        self.workspaceId = syntheticUUID // (#cm-110.1)
        self.groupId = nil // (#cm-110.1)
        self.isGroupHeader = false // (#cm-110.1)
        self.isColorSectionHeader = false // (#cm-110.1)
        self.statusHeaderKind = statusHeaderKind // (#cm-110.1)
        self.isPinned = false // (#cm-110.1)
        self.colorSectionToggle = colorSectionToggle // (#cm-110.1)
        self.environment = environment // (#cm-110.1)
        self.makeContent = { _, _ in AnyView(EmptyView()) } // (#cm-110.1)
        self.appKitGroupHeaderModel = statusHeaderModel // (#cm-110.1)
        self.appKitGroupHeaderActions = actions.settingStatusHeaderToggle(colorSectionToggle) // (#cm-110.1)
        self.appKitWorkspaceRowModel = nil // (#cm-110.1)
        self.appKitWorkspaceRowActions = nil // (#cm-110.1)
        self.appKitWorkspaceRowWorkspace = nil // (#cm-110.1)
        self.appKitWorkspaceRowRebuild = nil // (#cm-110.1)
        self.appKitUnreadDependencyWorkspaceIds = unreadDependencyWorkspaceIds // (#cm-110.1)
        self.appKitWorkspaceUnreadRebuild = nil // (#cm-110.1)
        self.appKitGroupHeaderUnreadRebuild = unreadRebuild // (#cm-110.1)
        self.equivalenceValue = statusHeaderModel // (#cm-110.1)
        self.isEquivalentValue = { value in // (#cm-110.1)
            guard let value = value as? SidebarGroupHeaderRowModel else { return false } // (#cm-110.1)
            return value == statusHeaderModel // (#cm-110.1)
        } // (#cm-110.1)
        self.isHeightEquivalentValue = self.isEquivalentValue // (#cm-110.1)
    } // (#cm-110.1)
} // (#cm-110.1)
