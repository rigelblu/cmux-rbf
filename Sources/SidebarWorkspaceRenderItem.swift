import AppKit
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

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .colorSectionHeader(let section):
            return section.memberWorkspaceIds[0]
        case .workspace(let workspaceId):
            return workspaceId
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            let groupId = tab.groupId
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
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(workspaceId: tab.id))
            }
        }
        return items
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
        var result: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let groupId = tab.groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
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
                Text(section.title)
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

    var accessibilityLabel: String {
        let state = section.isCollapsed
            ? String(localized: "sidebar.colorSection.collapsed", defaultValue: "collapsed")
            : String(localized: "sidebar.colorSection.expanded", defaultValue: "expanded")
        return String(
            localized: "sidebar.colorSection.accessibility",
            defaultValue: "Color section, \(section.title), \(section.memberWorkspaceIds.count) workspaces, \(state)"
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
            firstTitleByHex[hex] = entry.displayName
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
