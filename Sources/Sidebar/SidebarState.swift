import CmuxWorkspaces
import CmuxSettings
import Combine
import CoreGraphics
import Foundation

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat
    /// Keyed by hex alone, not by `(hex, pinTier)`. Deliberate (`#cm-56`
    /// Decisions): the same hex can render one section in each pin tier, and
    /// they're meant to share one collapsed state — expanding either
    /// expands both. Not an oversight; don't key this on section id.
    @Published private(set) var collapsedColorSectionHexes: Set<String>
    private var visibilityWillChangeOwnerId: UUID?
    private var visibilityWillChange: ((Bool) -> Void)?

    init(
        isVisible: Bool = true,
        persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth),
        collapsedColorSectionHexes: Set<String> = []
    ) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
        self.collapsedColorSectionHexes = Set(
            collapsedColorSectionHexes.compactMap(WorkspaceColorHex.normalized)
        )
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard nextValue != isVisible else { return }
        visibilityWillChange?(nextValue)
        isVisible = nextValue
    }

    func toggleColorSection(hex: String) {
        guard let normalized = WorkspaceColorHex.normalized(hex) else { return }
        if collapsedColorSectionHexes.remove(normalized) == nil {
            collapsedColorSectionHexes.insert(normalized)
        }
    }

    @MainActor
    func expandColorSection(containing workspace: Workspace) {
        guard workspace.groupId == nil,
              let rawColor = workspace.customColor else { return }
        expandColorSection(hex: rawColor)
    }

    func expandColorSection(hex: String) {
        guard let normalized = WorkspaceColorHex.normalized(hex) else { return }
        collapsedColorSectionHexes.remove(normalized)
    }

    func restoreCollapsedColorSections(_ rawHexes: [String]?) {
        collapsedColorSectionHexes = Set((rawHexes ?? []).compactMap(WorkspaceColorHex.normalized))
    }

    func installVisibilityWillChangeHandler(
        ownerId: UUID,
        _ handler: @escaping (Bool) -> Void
    ) {
        visibilityWillChangeOwnerId = ownerId
        visibilityWillChange = handler
    }

    func removeVisibilityWillChangeHandler(ownerId: UUID) {
        guard visibilityWillChangeOwnerId == ownerId else { return }
        visibilityWillChangeOwnerId = nil
        visibilityWillChange = nil
    }
}

enum SidebarResizeInteraction {
    enum Edge {
        case leading
        case trailing

        private var hitWidthBeforeDivider: CGFloat {
            switch self {
            case .leading:
                return SidebarResizeInteraction.sidebarSideHitWidth
            case .trailing:
                return SidebarResizeInteraction.contentSideHitWidth
            }
        }

        func handleX(dividerX: CGFloat) -> CGFloat {
            dividerX - hitWidthBeforeDivider
        }

        func hitRange(dividerX: CGFloat) -> ClosedRange<CGFloat> {
            let minX = handleX(dividerX: dividerX)
            return minX...(minX + SidebarResizeInteraction.totalHitWidth)
        }
    }

    // Keep a generous drag target inside the sidebar itself, but keep overlap
    // into terminal/browser content small so edge text selection still wins.
    static let sidebarSideHitWidth: CGFloat = 6
    // 4 pt matches the 4 pt padding used in GhosttySurfaceScrollView drop zone overlays
    // (dropZoneOverlayFrame). This prevents column-0 text near the leading edge from
    // accidentally triggering the sidebar resize when interacting with leftmost content.
    static let contentSideHitWidth: CGFloat = 4

    static var totalHitWidth: CGFloat {
        sidebarSideHitWidth + contentSideHitWidth
    }
}

enum SidebarSelectedWorkspaceScrollPolicy {
    static func shouldScrollSelectedWorkspace<ID: Equatable>(
        selectedWorkspaceId: ID?,
        oldWorkspaceIds: [ID],
        newWorkspaceIds: [ID]
    ) -> Bool {
        guard let selectedWorkspaceId,
              let newIndex = newWorkspaceIds.firstIndex(of: selectedWorkspaceId) else {
            return false
        }

        guard let oldIndex = oldWorkspaceIds.firstIndex(of: selectedWorkspaceId) else {
            return true
        }

        guard oldWorkspaceIds.count == newWorkspaceIds.count else {
            return false
        }

        guard oldIndex != newIndex else {
            return false
        }

        return true
    }

    /// A member of a collapsed group has no sidebar row of its own, so its
    /// UUID is not a scrollable `.id` and `scrollTo` would no-op. Target the
    /// group header (which carries the anchor workspace id) so the scroll
    /// still lands where the workspace lives. Decided purely from model data,
    /// never from what the lazy layout happens to have realized.
    static func scrollTargetWorkspaceId(
        selectedWorkspaceId: UUID,
        group: WorkspaceGroup?
    ) -> UUID {
        guard let group, group.isCollapsed else { return selectedWorkspaceId }
        return group.anchorWorkspaceId
    }
}
