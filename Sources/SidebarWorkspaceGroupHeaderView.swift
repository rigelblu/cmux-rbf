import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebar
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View, Equatable {
    // Closures and delegate factories are excluded because they are recreated
    // by the parent on each evaluation. The scalar snapshots below are the
    // header's render and behavior inputs under the LazyVStack.
    nonisolated static func == (lhs: SidebarWorkspaceGroupHeaderView, rhs: SidebarWorkspaceGroupHeaderView) -> Bool {
        lhs.groupId == rhs.groupId &&
            lhs.anchorWorkspaceId == rhs.anchorWorkspaceId &&
            lhs.name == rhs.name &&
            lhs.iconSymbol == rhs.iconSymbol &&
            lhs.tintHex == rhs.tintHex &&
            lhs.customColorHex == rhs.customColorHex &&
            lhs.isCollapsed == rhs.isCollapsed &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isAnchorActive == rhs.isAnchorActive &&
            lhs.isMultiSelected == rhs.isMultiSelected &&
            lhs.multiSelectionBackgroundStyle == rhs.multiSelectionBackgroundStyle &&
            lhs.memberCount == rhs.memberCount &&
            lhs.anchorUnreadCount == rhs.anchorUnreadCount &&
            lhs.canMarkRead == rhs.canMarkRead &&
            lhs.canMarkUnread == rhs.canMarkUnread &&
            lhs.hasLatestNotifications == rhs.hasLatestNotifications &&
            lhs.canMarkAllRead == rhs.canMarkAllRead &&
            lhs.canMarkAllUnread == rhs.canMarkAllUnread &&
            lhs.shortcutDigit == rhs.shortcutDigit &&
            lhs.shortcutModifierSymbol == rhs.shortcutModifierSymbol &&
            lhs.showsShortcutHint == rhs.showsShortcutHint &&
            lhs.isPointerHovering == rhs.isPointerHovering &&
            lhs.shortcutHintXOffset == rhs.shortcutHintXOffset &&
            lhs.shortcutHintYOffset == rhs.shortcutHintYOffset &&
            lhs.fontScale == rhs.fontScale &&
            lhs.cwdContextMenuItems == rhs.cwdContextMenuItems &&
            lhs.newWorkspacePlacement == rhs.newWorkspacePlacement &&
            lhs.rowSpacing == rhs.rowSpacing &&
            lhs.isFirstRow == rhs.isFirstRow &&
            lhs.isBeingDragged == rhs.isBeingDragged &&
            lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
            lhs.bottomDropIndicatorVisible == rhs.bottomDropIndicatorVisible &&
            lhs.depth == rhs.depth &&
            lhs.hasOwnWorkspace == rhs.hasOwnWorkspace &&
            lhs.isFoldedOverSelection == rhs.isFoldedOverSelection &&
            lhs.moveMenu == rhs.moveMenu &&
            lhs.holdsGroups == rhs.holdsGroups &&
            lhs.dropLineLevel == rhs.dropLineLevel &&
            lhs.listWidth == rhs.listWidth
    }

    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    /// What the band paints: `customColor ?? cwdConfig.color` (`#cm-49`).
    let tintHex: String?
    /// The group's own colour override, so the colour menu's checkmark means
    /// *you picked this* rather than *something resolved this for you*.
    let customColorHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let isMultiSelected: Bool
    let multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let isPointerHovering: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    /// How many groups hold this header; 0 at the top level and in a window with no nested group (#cm-106).
    var depth: Int = 0
    /// See `SidebarHeaderOnlyLook` (#cm-106).
    var hasOwnWorkspace: Bool = true
    var isFoldedOverSelection: Bool = false
    /// What `Move Group to` offers, built above the lazy boundary; the body never reads the model (#cm-106).
    var moveMenu: WorkspaceGroupMoveMenu? = nil
    var holdsGroups: Bool = false
    /// The level a reorder drop lands at, on a header that draws a drop line (#cm-106).
    var dropLineLevel: Int? = nil
    /// The list's width, for the cap on the indent (#cm-106).
    var listWidth: CGFloat? = nil
    /// Shared actions for SwiftUI and AppKit group headers.
    let actions: SidebarGroupHeaderRowActions
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void

    @State private var contextMenuVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

#if DEBUG
    // Plain-value environment probe set only by SidebarLazyLayoutScaleTests;
    // default no-op. See SidebarLazyContractProbe.
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    /// How far the drop line starts from the left edge of the whole header view: the landing level's indent. The
    /// header's own indent padding is applied before the line overlays (`.padding(.leading, ...)` above), so the
    /// overlay already spans that padding and the line takes the landing indent as it is, not less the header's own.
    /// Nil in a window with no nested group, where the lines are drawn as before (#cm-106).
    private var dropLineLeadingInset: CGFloat? {
        guard let level = dropLineLevel else { return nil }
        return SidebarNestedDropLine.inset(level: level, availableWidth: listWidth)
    }

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
    }

    /// The dot's colour (#cm-106): the group's tint by the color group header's function, else secondary.
    private var dotColor: Color {
        SidebarHeaderOnlyLook.dotTint(tintHex: tintHex, colorScheme: colorScheme).map { Color(nsColor: $0) } ?? .secondary
    }

    /// The name's colour: the accent tint while a folded header holds the selected workspace, else the band's own (#cm-106).
    private var nameColor: Color {
        if isFoldedOverSelection { return .accentColor }
        return Color(nsColor: bandPalette.primaryTextColor)
    }

    private var displayedIconSymbol: String {
        RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: iconSymbol, configured: nil)
    }

    private var shortcutHintPillText: String? {
        guard showsShortcutHint,
              let shortcutDigit,
              let shortcutModifierSymbol else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    /// `Move Group to`: `Top Level`, then every group this one may go into, the current place ticked. A SwiftUI menu has
    /// no indent, so the title is padded by depth. The destinations come with the header's snapshot, built on every pass
    /// of the sidebar (`VerticalTabsSidebar+WorkspaceGroups.swift`); the AppKit header reads them when the menu opens
    /// (#cm-106).
    @ViewBuilder
    private var moveGroupMenu: some View {
        if let moveMenu {
            Menu(String(localized: "workspaceGroup.contextMenu.moveTo", defaultValue: "Move Group to")) {
                Button {
                    actions.onMoveGroup(nil)
                } label: {
                    if moveMenu.topLevelIsCurrent {
                        Label(String(localized: "workspaceGroup.contextMenu.moveTo.topLevel", defaultValue: "Top Level"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "workspaceGroup.contextMenu.moveTo.topLevel", defaultValue: "Top Level"))
                    }
                }
                Divider()
                ForEach(moveMenu.destinations) { destination in
                    Button {
                        actions.onMoveGroup(destination.id)
                    } label: {
                        let title = String(repeating: "\u{2003}", count: destination.depth) + destination.name
                        if destination.isCurrent {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        }
    }

    private var pinnedGroupTooltip: String {
        String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
    }

    /// The band behind this header, resolved from the one shared source both
    /// renderers consume. Pure over the scalar snapshot fields, so it is legal
    /// below the `LazyVStack` boundary.
    private var bandPalette: SidebarGroupHeaderBandPalette {
        SidebarGroupHeaderBandPalette(
            tintHex: tintHex,
            isAnchorActive: isAnchorActive,
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            renderedAppearance: .init(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast
            )
        )
    }

    private var multiSelectionBackgroundColor: Color {
        guard let color = multiSelectionBackgroundStyle.color else {
            return .clear
        }
        return Color(nsColor: color).opacity(multiSelectionBackgroundStyle.opacity)
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.groupHeaderRowBody?() }()
#endif
        HStack(spacing: 4) {
            if isPinned {
                CmuxSystemSymbolImage(
                    magnified: "pin.fill",
                    pointSize: metrics.pinnedIconFontSize,
                    weight: .semibold,
                    tint: .secondary
                )
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .safeHelp(pinnedGroupTooltip)
                .accessibilityLabel(Text(pinnedGroupTooltip))
            }
            CmuxSystemSymbolImage(
                systemName: isCollapsed ? "chevron.right" : "chevron.down",
                pointSize: metrics.chevronFontSize,
                weight: .semibold,
                tint: .secondary,
                appliesGlobalFontMagnification: true)
                .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
                .contentShape(Rectangle())
                .onTapGesture { actions.onToggleCollapsed() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    Text(
                        isCollapsed
                            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
                    )
                )

            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: displayedIconSymbol,
                    pointSize: metrics.iconFontSize,
                    weight: .semibold,
                    tint: iconColor,
                    appliesGlobalFontMagnification: true)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .accessibilityHidden(true)
                    // (#cm-106) a header with no workspace draws a dot where the icon was; the icon keeps its frame
                    .opacity(hasOwnWorkspace ? 1 : 0)
                    .overlay {
                        if !hasOwnWorkspace {
                            Circle()
                                .fill(dotColor)
                                .frame(width: SidebarHeaderOnlyLook.dotDiameter, height: SidebarHeaderOnlyLook.dotDiameter)
                        }
                    }
                Text(name)
                    .cmuxFont(size: metrics.nameFontSize, weight: .semibold)
                    .foregroundStyle(nameColor) // (#cm-106)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if anchorUnreadCount > 0 {
                    Text("\(anchorUnreadCount)")
                        .cmuxFont(size: metrics.unreadFontSize, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            anchorUnreadCount
                        )))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                actions.onFocusAnchor(NSApp.currentEvent?.modifierFlags ?? [])
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(name))
            .accessibilityHint(Text(hasOwnWorkspace // (#cm-106) a click on a header with no workspace folds it
                ? String(
                    localized: "workspaceGroup.focusAnchor.a11y",
                    defaultValue: "Focus the group's anchor workspace"
                )
                : String(
                    localized: "workspaceGroup.noOwnWorkspace.hint.a11y",
                    defaultValue: "Fold or unfold the group"
                )))

            let plusVisible = isPointerHovering && !contextMenuVisible && !showsShortcutHint
            Button(action: actions.onTapPlus) {
                CmuxSystemSymbolImage(
                    systemName: "plus",
                    pointSize: metrics.plusFontSize,
                    weight: .medium,
                    tint: .secondary,
                    appliesGlobalFontMagnification: true)
                    .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New workspace in group"
            )))
            .contextMenu {
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                        defaultValue: "New Workspace in Group"
                    ),
                    action: actions.onTapPlus
                )
                .onAppear {
                    contextMenuVisible = true
                    onContextMenuAppear()
                }
                .onDisappear {
                    contextMenuVisible = false
                    onContextMenuDisappear()
                }
                if !cwdContextMenuItems.isEmpty {
                    Divider()
                    ForEach(cwdContextMenuItems) { item in
                        switch item {
                        case .separator:
                            Divider()
                        case .action(let action):
                            Button(action.title) {
                                actions.onRunResolvedItem(action)
                            }
                        }
                    }
                }
                Divider()
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.editConfig",
                        defaultValue: "Edit Group Config..."
                    ),
                    action: actions.onEditConfig
                )
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.openDocs",
                        defaultValue: "Open Workspace Groups Docs"
                    ),
                    action: actions.onOpenDocs
                )
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .contentShape(Rectangle())
        .background(
            Color(nsColor: bandPalette.bandColor)
                .opacity(bandPalette.bandOpacity)
        )
        .clipShape(RoundedRectangle(
            cornerRadius: isMultiSelected && !isAnchorActive ? 6 : 4,
            style: .continuous
        ))
        .sidebarNestedAccessibilityValue(SidebarNestedAccessibility.value(depth: depth, hasOwnWorkspace: hasOwnWorkspace)) // (#cm-106)
        .padding(.leading, SidebarNestedIndent.points(levels: depth, availableWidth: listWidth)) // (#cm-106) the band starts at the header's own indent
        .sidebarShortcutHintOverlay(
            text: shortcutHintPillText,
            emphasis: isAnchorActive ? 1.0 : 0.9,
            offsetX: shortcutHintXOffset,
            offsetY: shortcutHintYOffset
        )
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: isFirstRow,
                rowSpacing: rowSpacing,
                leadingInset: dropLineLeadingInset ?? 0 // (#cm-106)
            )
        }
        .overlay(alignment: .bottom) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: bottomDropIndicatorVisible,
                isFirstRow: false,
                rowSpacing: rowSpacing,
                isBottomEdge: true,
                leadingInset: dropLineLeadingInset ?? metrics.groupScopedBottomDropIndicatorLeadingInset // (#cm-106)
            )
        }
        .contextMenu {
            Button(
                String(
                    localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                    defaultValue: "New Workspace in Group"
                ),
                action: actions.onTapPlus
            )
            .onAppear {
                contextMenuVisible = true
                onContextMenuAppear()
            }
            .onDisappear {
                contextMenuVisible = false
                onContextMenuDisappear()
            }
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.rename",
                    defaultValue: "Rename Group..."
                ),
                action: actions.onRename
            )
            // Beside Rename, above Pin: a group's name and its colour are its
            // identity, and the pin is where it sits. Appending it near
            // Ungroup/Delete would bury an everyday action between two
            // destructive ones.
            Menu(
                String(
                    localized: "workspaceGroup.contextMenu.color",
                    defaultValue: "Group Color"
                )
            ) {
                // `customColorHex`, never `tintHex` — see the property's doc.
                WorkspaceColorMenuRows(
                    targetHexes: [customColorHex],
                    colorScheme: colorScheme,
                    apply: actions.onSetColor,
                    promptCustomColor: actions.onPromptCustomColor
                )
            }
            Button(
                isPinned
                    ? String(
                        localized: "workspaceGroup.contextMenu.unpin",
                        defaultValue: "Unpin Group"
                    )
                    : String(
                        localized: "workspaceGroup.contextMenu.pin",
                        defaultValue: "Pin Group"
                    ),
                action: actions.onTogglePinned
            )
            moveGroupMenu // (#cm-106)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markRead",
                    defaultValue: "Mark Group as Read"
                ),
                action: actions.onMarkRead
            )
            .disabled(!canMarkRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markUnread",
                    defaultValue: "Mark Group as Unread"
                ),
                action: actions.onMarkUnread
            )
            .disabled(!canMarkUnread)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.clearLatestNotifications",
                    defaultValue: "Clear Latest Notifications"
                ),
                action: actions.onClearLatestNotifications
            )
            .disabled(!hasLatestNotifications)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllRead",
                    defaultValue: "Mark All Workspaces in Group as Read"
                ),
                action: actions.onMarkAllRead
            )
            .disabled(!canMarkAllRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllUnread",
                    defaultValue: "Mark All Workspaces in Group as Unread"
                ),
                action: actions.onMarkAllUnread
            )
            .disabled(!canMarkAllUnread)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.editConfig",
                    defaultValue: "Edit Group Config..."
                ),
                action: actions.onEditConfig
            )
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.openDocs",
                    defaultValue: "Open Workspace Groups Docs"
                ),
                action: actions.onOpenDocs
            )
            Divider()
            if !isPinned || memberCount > 0 || holdsGroups { // (#cm-106)
                Button(
                    String(
                        localized: "workspaceGroup.contextMenu.ungroup",
                        defaultValue: "Ungroup Workspaces"
                    ),
                    action: actions.onUngroup
                )
            }
            Button(
                role: .destructive,
                action: actions.onDelete
            ) {
                Text(
                    String(
                        localized: "workspaceGroup.contextMenu.delete",
                        defaultValue: "Delete Group"
                    )
                )
            }
        }
    }
}
