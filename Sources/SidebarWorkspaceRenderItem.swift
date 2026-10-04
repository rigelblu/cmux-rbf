import AppKit
import CmuxFoundation
import CmuxWorkspaces
import CmuxSettings
import Foundation
import SwiftUI

/// Stable value identity for one drawable item in the workspace sidebar.
///
/// Keep live `Workspace` / `WorkspaceGroup` references out of this value. A
/// `LazyVStack` copies and diffs its `ForEach` data while placing rows; carrying
/// the models through that path made scrolling copy the live sidebar graph and
/// blurred the ownership boundary between layout data and observed state.
/// Models are resolved from the parent-owned render context only when SwiftUI
/// asks to realize a row.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID, anchorWorkspaceId: UUID)
    case colorSectionHeader(section: SidebarWorkspaceColorSection)
    case workspace(workspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .colorSectionHeader(let section):
            return .colorSection(section.id)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        }
    }

    /// `nil` only for a color-section header with no members — unreachable
    /// through `SidebarWorkspaceColorSectionProjection.project`, but
    /// `SidebarWorkspaceColorSection`'s public initializer doesn't enforce
    /// it, so this stays safe rather than trapping on `memberWorkspaceIds[0]`.
    var rowWorkspaceId: UUID? {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .colorSectionHeader(let section):
            return section.memberWorkspaceIds.first
        case .workspace(let workspaceId):
            return workspaceId
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup]? = nil,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty || !groupsById.isEmpty else { return [] }
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: groupsById)
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            // Render and row configuration must agree on whether this tab is
            // actually grouped. A stale group id (or a group whose live anchor
            // disappeared) is a root row, even if it sits between members of a
            // valid group in the persisted tab order.
            let groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        items.append(.groupHeader(
                            groupId: group.id,
                            anchorWorkspaceId: group.anchorWorkspaceId
                        ))
                        emittedHeaders.insert(groupId)
                        collapsedByGroupId[groupId] = group.isCollapsed
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = collapsedByGroupId[groupId] ?? false
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.liveAnchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(workspaceId: tab.id))
            }
        }

        // Empty pinned groups have no tab row from which a header can be
        // discovered. Emit them as first-class header-only rows, keeping the
        // model's group order within each pin tier. Empty unpinned groups are
        // placed after live rows; they are uncommon (normal close paths remove
        // them) but remain renderable until an explicit mutation removes them.
        let ordered = orderedGroups
            ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let memberGroupIds = Set(effectiveMembershipByWorkspaceId.values.compactMap { $0 })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        // Only durable empty groups belong in the header-only projection. A
        // nonempty group whose anchor went stale is intentionally absent from
        // the render tree; treating it as empty would create a ghost header.
        let emptyGroups = ordered.filter {
            $0.isEmpty && !memberGroupIds.contains($0.id)
        }
        guard !emptyGroups.isEmpty else { return items }

        var emptyBeforeGroup: [UUID: [WorkspaceGroup]] = [:]
        var trailingPinned: [WorkspaceGroup] = []
        var trailingUnpinned: [WorkspaceGroup] = []
        var nextLivePinnedGroup: WorkspaceGroup?
        var nextLiveUnpinnedGroup: WorkspaceGroup?
        var nextLiveSameTierByIndex: [WorkspaceGroup?] = Array(
            repeating: nil,
            count: ordered.count
        )
        for index in ordered.indices.reversed() {
            let group = ordered[index]
            nextLiveSameTierByIndex[index] = group.isPinned
                ? nextLivePinnedGroup
                : nextLiveUnpinnedGroup
            guard memberGroupIds.contains(group.id) else { continue }
            if group.isPinned {
                nextLivePinnedGroup = group
            } else {
                nextLiveUnpinnedGroup = group
            }
        }
        for (index, group) in ordered.enumerated() where !memberGroupIds.contains(group.id) {
            // Preserve the group's authoritative slot within its pin tier.
            // Crossing tiers would violate the sidebar's pinned-first
            // invariant, so only a later live group in the same tier is a
            // valid insertion anchor; otherwise defer to that tier boundary.
            let nextLiveSameTierGroup = nextLiveSameTierByIndex[index]
            if let nextLiveSameTierGroup {
                emptyBeforeGroup[nextLiveSameTierGroup.id, default: []].append(group)
            } else if group.isPinned {
                trailingPinned.append(group)
            } else {
                trailingUnpinned.append(group)
            }
        }

        var rendered: [SidebarWorkspaceRenderItem] = []
        rendered.reserveCapacity(items.count + emptyGroups.count)
        for item in items {
            if case .groupHeader(let groupId, _) = item,
               let preceding = emptyBeforeGroup[groupId] {
                rendered.append(contentsOf: preceding.map {
                    .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
                })
            }
            rendered.append(item)
        }
        if !trailingPinned.isEmpty {
            let firstUnpinnedIndex = rendered.firstIndex { item in
                switch item {
                case .groupHeader(let groupId, _):
                    return groupsById[groupId]?.isPinned == false
                case .colorSectionHeader(let section):
                    return section.id.pinTier == .unpinned
                case .workspace(let workspaceId):
                    guard let workspace = tabsById[workspaceId] else {
                        return false
                    }
                    if let groupId = effectiveMembershipByWorkspaceId[workspace.id] ?? nil,
                       let group = groupsById[groupId] {
                        return !group.isPinned
                    }
                    return !workspace.isPinned
                }
            } ?? rendered.count
            rendered.insert(contentsOf: trailingPinned.map {
                .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
            }, at: firstUnpinnedIndex)
        }
        rendered.append(contentsOf: trailingUnpinned.map {
            .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
        })
        return rendered
    }

    /// Workspace ids represented by ordinary rows, in their rendered order.
    ///
    /// Group headers represent their anchor workspace for interaction, but are
    /// containers rather than numbered workspace rows.
    static func numberedWorkspaceIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
    }

    /// Row ids valid as drag/reorder targets: every workspace row, plus each
    /// real group's anchor (its header stands in for it as a target). Color
    /// section headers are excluded — they duplicate their first member's id
    /// and accept no drop of their own (`#cm-56`).
    static func interactiveRowIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            if case .colorSectionHeader = item { return nil }
            return item.rowWorkspaceId
        }
    }

    static func numberedWorkspaceIndexById(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(renderItems.count)
        for item in renderItems {
            guard case .workspace(let workspaceId) = item else { continue }
            result[workspaceId] = result.count
        }
        return result
    }

    static func numberedWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        numberedWorkspaceIds(from: renderItems(tabs: tabs, groupsById: groupsById))
    }

    static func memberWorkspaceIdsByGroupId(tabs: [Workspace]) -> [UUID: [UUID]] {
        memberWorkspaceIdsByGroupId(tabs: tabs, groupsById: nil)
    }

    /// Returns the group membership that is safe for sidebar rendering.
    ///
    /// A workspace may carry a stale group id after a restore or an
    /// in-flight anchor promotion. Only groups with a live anchor (or an
    /// explicitly empty durable anchor) are renderable; all other references
    /// become root-level rows. A live anchor also wins when its workspace's
    /// copied `groupId` is temporarily nil, keeping the header and member rows
    /// on one authoritative group run.
    static func effectiveGroupIdByWorkspaceId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID: UUID?] {
        let liveWorkspaceIds = Set(tabs.map(\.id))
        let renderableGroupIds = Set(groupsById.values.compactMap { group in
            if group.isEmpty { return group.id }
            guard let liveAnchorId = group.liveAnchorWorkspaceId,
                  liveWorkspaceIds.contains(liveAnchorId) else {
                return nil
            }
            return group.id
        })
        let groupIdByLiveAnchor = groupsById.values
            .filter { renderableGroupIds.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .reduce(into: [UUID: UUID]()) { result, group in
                guard let liveAnchorId = group.liveAnchorWorkspaceId,
                      result[liveAnchorId] == nil else { return }
                result[liveAnchorId] = group.id
            }
        return Dictionary(uniqueKeysWithValues: tabs.map { tab in
            let effectiveGroupId = groupIdByLiveAnchor[tab.id]
                ?? tab.groupId.flatMap { renderableGroupIds.contains($0) ? $0 : nil }
            return (tab.id, effectiveGroupId)
        })
    }

    /// Builds the member index using effective, renderable group membership.
    static func memberWorkspaceIdsByGroupId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]?,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? groupsById.map { effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: $0) }
        for tab in tabs {
            let groupId: UUID?
            if let effectiveMembershipByWorkspaceId {
                groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil
            } else {
                groupId = tab.groupId
            }
            if let groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}

/// Which drops a workspace inside a generated color section may accept.
///
/// Extracted as a pure rule because the view-level wrapper that used to hold
/// it could not be tested, and an untested wrapper is exactly how `#cm-56`
/// shipped a too-broad refusal once already.
enum SidebarWorkspaceColorSectionDropPolicy {
    /// Whether a color-section member's drag may proceed on `action` without
    /// consulting the same-section rule.
    ///
    /// True only for a drop into a real workspace group. That move is already
    /// reachable from the context menu's **Move to Group**, and one behavior
    /// may not disagree across entrypoints — joining a group sets `groupId`,
    /// which makes the workspace ineligible for any color section, so it
    /// leaves its section exactly as the menu would take it, keeping its color.
    /// Every other action falls through to the same-section rule, which is
    /// what keeps a cross-color, standalone-row, or cross-tier drop refused.
    static func allowsDropOutOfSection(action: SidebarWorkspaceReorderDropAction) -> Bool {
        guard case .reorder(_, _, let explicitGroupId) = action else { return false }
        return explicitGroupId != nil
    }

    /// Whether a row sits *inside* a header and so carries the leading indent.
    ///
    /// A real group and a generated color section are different things, but to
    /// the eye both are containers, and a member of either should read as
    /// contained. Both renderers delegate here so the inset cannot drift
    /// between them.
    static func indentsUnderHeader(isGrouped: Bool, isColorSectionMember: Bool) -> Bool {
        isGrouped || isColorSectionMember
    }
}

/// Immutable workspace facts consumed by the color-section projection.
struct SidebarWorkspaceColorSectionWorkspaceSnapshot: Equatable {
    let id: UUID
    let groupId: UUID?
    let isPinned: Bool
    let customColor: String?
}

/// Stable identity for one generated color section.
struct SidebarWorkspaceColorSectionID: Hashable {
    enum PinTier: UInt8, Hashable {
        case pinned
        case unpinned
    }

    let normalizedHex: String
    let pinTier: PinTier
}

/// Value-only metadata shared by both sidebar renderers.
struct SidebarWorkspaceColorSection: Equatable {
    let id: SidebarWorkspaceColorSectionID
    let title: String
    let memberWorkspaceIds: [UUID]
    let isCollapsed: Bool
}

/// The color-section header band resolved from immutable appearance inputs.
///
/// Kept as a value so this header shares one presentation contract with the
/// `#cm-49` real-group header band, and tests can compare it directly against
/// `SidebarGroupHeaderBandPalette`. A color section has no anchor or multi-select
/// state, so its band always rests at `restingBandOpacity` — it never rises to
/// `activeBandOpacity` the way a real group's does when its anchor is active.
struct SidebarWorkspaceColorSectionHeaderBand: Equatable {
    let bandColor: NSColor
    let bandOpacity: CGFloat
    let primaryTextColor: NSColor

    static func resolve(
        normalizedHex: String,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> Self {
        let palette = SidebarGroupHeaderBandPalette(
            tintHex: normalizedHex,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            renderedAppearance: .init(
                colorScheme: colorScheme,
                contrast: contrast
            )
        )
        return Self(
            bandColor: palette.bandColor,
            bandOpacity: palette.bandOpacity,
            primaryTextColor: palette.primaryTextColor
        )
    }
}

struct SidebarWorkspaceColorSectionHeader: View, Equatable {
    let section: SidebarWorkspaceColorSection
    let colorScheme: ColorScheme
    let onToggle: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let band = headerBand
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
                Circle()
                    .fill(sectionColor)
                    .frame(width: 8, height: 8)
                Text(renderedTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: band.primaryTextColor))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .contentShape(Rectangle())
            .background(
                Color(nsColor: band.bandColor)
                    .opacity(band.bandOpacity)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sectionColor: Color {
        WorkspaceTabColorSettings.displayColor(
            hex: section.id.normalizedHex,
            colorScheme: colorScheme
        ) ?? .secondary
    }

    var headerBand: SidebarWorkspaceColorSectionHeaderBand {
        .resolve(
            normalizedHex: section.id.normalizedHex,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
    }

    /// The title consumed by both sidebar renderers and accessibility.
    var renderedTitle: String {
        section.title
    }

    var accessibilityLabel: String {
        let state = section.isCollapsed
            ? String(localized: "sidebar.colorSection.collapsed", defaultValue: "collapsed")
            : String(localized: "sidebar.colorSection.expanded", defaultValue: "expanded")
        return String(
            localized: "sidebar.colorSection.accessibility",
            defaultValue: "Color section, \(renderedTitle), \(section.memberWorkspaceIds.count) workspaces, \(state)"
        )
    }
}

/// Pure color-section analysis performed once above both sidebar renderers.
struct SidebarWorkspaceColorSectionProjection {
    struct Diagnostics: Equatable {
        let paletteEntryVisitCount: Int
        let workspaceVisitCount: Int
    }

    let sections: [SidebarWorkspaceColorSection]
    let sectionByWorkspaceId: [UUID: SidebarWorkspaceColorSection]
    let diagnostics: Diagnostics

    static func project(
        workspaces: [SidebarWorkspaceColorSectionWorkspaceSnapshot],
        paletteEntries: [WorkspaceColorPaletteEntry],
        collapsedHexes: Set<String>
    ) -> SidebarWorkspaceColorSectionProjection {
        var firstTitleByHex: [String: String] = [:]
        firstTitleByHex.reserveCapacity(paletteEntries.count)
        var paletteEntryVisitCount = 0
        for entry in paletteEntries {
            paletteEntryVisitCount += 1
            guard let hex = WorkspaceColorHex.normalized(entry.hex),
                  firstTitleByHex[hex] == nil else { continue }
            firstTitleByHex[hex] = entry.label ?? entry.customDisplayName ?? entry.name
        }

        var order: [SidebarWorkspaceColorSectionID] = []
        var membersByID: [SidebarWorkspaceColorSectionID: [UUID]] = [:]
        var workspaceVisitCount = 0
        order.reserveCapacity(min(workspaces.count, paletteEntries.count))
        for workspace in workspaces {
            workspaceVisitCount += 1
            guard workspace.groupId == nil,
                  let rawColor = workspace.customColor,
                  let hex = WorkspaceColorHex.normalized(rawColor) else { continue }
            let id = SidebarWorkspaceColorSectionID(
                normalizedHex: hex,
                pinTier: workspace.isPinned ? .pinned : .unpinned
            )
            if membersByID[id] == nil {
                order.append(id)
                membersByID[id] = []
            }
            membersByID[id, default: []].append(workspace.id)
        }

        let normalizedCollapsed = Set(collapsedHexes.compactMap(WorkspaceColorHex.normalized))
        let sections = order.map { id in
            SidebarWorkspaceColorSection(
                id: id,
                title: firstTitleByHex[id.normalizedHex]
                    ?? String(localized: "sidebar.colorSection.custom", defaultValue: "Custom (\(id.normalizedHex))"),
                memberWorkspaceIds: membersByID[id] ?? [],
                isCollapsed: normalizedCollapsed.contains(id.normalizedHex)
            )
        }
        var sectionByWorkspaceId: [UUID: SidebarWorkspaceColorSection] = [:]
        sectionByWorkspaceId.reserveCapacity(workspaces.count)
        for section in sections {
            for workspaceID in section.memberWorkspaceIds {
                sectionByWorkspaceId[workspaceID] = section
            }
        }
        return SidebarWorkspaceColorSectionProjection(
            sections: sections,
            sectionByWorkspaceId: sectionByWorkspaceId,
            diagnostics: Diagnostics(
                paletteEntryVisitCount: paletteEntryVisitCount,
                workspaceVisitCount: workspaceVisitCount
            )
        )
    }

    func applying(to baseItems: [SidebarWorkspaceRenderItem]) -> [SidebarWorkspaceRenderItem] {
        guard !sections.isEmpty else { return baseItems }
        var emitted: Set<SidebarWorkspaceColorSectionID> = []
        var result: [SidebarWorkspaceRenderItem] = []
        result.reserveCapacity(baseItems.count + sections.count)
        for item in baseItems {
            guard case .workspace(let workspaceID) = item,
                  let section = sectionByWorkspaceId[workspaceID] else {
                result.append(item)
                continue
            }
            if emitted.insert(section.id).inserted {
                result.append(.colorSectionHeader(section: section))
                if !section.isCollapsed {
                    result.append(contentsOf: section.memberWorkspaceIds.map {
                        .workspace(workspaceId: $0)
                    })
                }
            }
        }
        return result
    }
}
