import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

// Everything the `Statuses` header and a status group's header draw or say, in both sidebar renderers. (#cm-110.1)
// The AppKit cell (`SidebarGroupHeaderRowView`) and the two SwiftUI views below take these values and read no store.

/// The words of the two headers: accessibility labels, and the chevron's action. (#cm-110.1)
enum SidebarStatusHeaderText {
    static var statusesAreaTitle: String {
        String(localized: "sidebar.statusesArea.title", defaultValue: "Statuses")
    }

    static func stateWord(isCollapsed: Bool) -> String {
        isCollapsed
            ? String(localized: "sidebar.statusGroup.collapsed", defaultValue: "collapsed")
            : String(localized: "sidebar.statusGroup.expanded", defaultValue: "expanded")
    }

    /// "Status group, Parked, 2 workspaces, expanded". The count is a plural key, so every language gets its own forms.
    static func statusGroupLabel(name: String, memberCount: Int, isCollapsed: Bool) -> String {
        let countText = String(
            localized: "sidebar.statusGroup.workspaceCount",
            defaultValue: "\(memberCount) workspaces"
        )
        return String.localizedStringWithFormat(
            String(localized: "sidebar.statusGroup.accessibility", defaultValue: "Status group, %1$@, %2$@, %3$@"),
            name,
            countText,
            stateWord(isCollapsed: isCollapsed)
        )
    }

    /// "Statuses, 3 status groups, expanded".
    static func statusesAreaLabel(groupCount: Int, isCollapsed: Bool) -> String {
        let countText = String(
            localized: "sidebar.statusesArea.groupCount",
            defaultValue: "\(groupCount) status groups"
        )
        return String.localizedStringWithFormat(
            String(localized: "sidebar.statusesArea.accessibility", defaultValue: "Statuses, %1$@, %2$@"),
            countText,
            stateWord(isCollapsed: isCollapsed)
        )
    }

    /// What pressing the chevron does: "Collapse status group" while open, "Expand status group" while folded.
    static func chevronLabel(kind: SidebarStatusHeaderKind, isCollapsed: Bool) -> String {
        switch (kind, isCollapsed) {
        case (.statusesArea, true):
            return String(localized: "sidebar.statusesArea.chevron.expand", defaultValue: "Expand statuses area")
        case (.statusesArea, false):
            return String(localized: "sidebar.statusesArea.chevron.collapse", defaultValue: "Collapse statuses area")
        case (.statusGroup, true):
            return String(localized: "sidebar.statusGroup.chevron.expand", defaultValue: "Expand status group")
        case (.statusGroup, false):
            return String(localized: "sidebar.statusGroup.chevron.collapse", defaultValue: "Collapse status group")
        }
    }
}

/// What a status group's header shows about its status, read once by the parent and passed down as values. (#cm-110.1)
struct SidebarStatusGroupPresentation: Equatable {
    let name: String
    let tintHex: String?
    /// The shape or symbol his entry names, or `nil` to draw the glyph of `behavesAs`.
    let glyph: WorkspaceStatusGlyph?
    /// The cmux status his entry extends; a missing `glyph` draws this one's glyph.
    let behavesAs: WorkspaceTaskStatus

    static func resolve(
        statusId: String,
        list: WorkspaceStatusList,
        colorHexes: [String: String]
    ) -> Self {
        let entry: WorkspaceStatusEntry? = list.entries.first { $0.id == statusId }
        let cmuxStatus: WorkspaceTaskStatus? = WorkspaceTaskStatus(rawValue: statusId)
        let name: String
        if let entry {
            name = WorkspaceStatusPresentation.text(entry.label)
        } else {
            name = cmuxStatus?.displayName ?? statusId
        }
        return Self(
            name: name,
            tintHex: colorHexes[statusId],
            glyph: entry?.icon,
            behavesAs: entry?.behavesAs ?? cmuxStatus ?? .working
        )
    }
}

/// The glyph beside a status group's name: the row's own drawing (a shape, an SF Symbol or the pie), one image for
/// both renderers. (#cm-110.1)
enum SidebarStatusHeaderGlyphImage {
    @MainActor
    static func make(
        presentation: SidebarStatusGroupPresentation,
        fontScale: CGFloat,
        colorScheme: ColorScheme,
        nameColor: NSColor,
        tickColor: NSColor
    ) -> NSImage {
        let side: CGFloat = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale).iconFrame
        let glyphModel = SidebarRowTaskStatusGlyphButton.Model(
            status: presentation.behavesAs,
            hasOverride: false,
            usesMonochrome: false,
            fontScale: fontScale,
            colorScheme: colorScheme,
            name: presentation.name,
            icon: presentation.glyph,
            colorHex: presentation.tintHex
        )
        let symbolMask = WorkspaceStatusIconDrawing.symbolMask(for: presentation.glyph, fontScale: fontScale)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            SidebarRowTaskStatusGlyphButton.drawGlyph(
                model: glyphModel,
                symbolMask: symbolMask,
                color: nameColor.cgColor,
                tickColor: tickColor.cgColor,
                in: context,
                bounds: rect
            )
            return true
        }
    }
}

/// The `Statuses` header in the SwiftUI list: no band, a hairline above, a muted name. (#cm-110.1)
struct SidebarStatusesAreaSwiftUIHeader: View, Equatable {
    let groupCount: Int
    let isCollapsed: Bool
    var unreadCount: Int = 0
    var onToggle: @MainActor () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groupCount == rhs.groupCount && lhs.isCollapsed == rhs.isCollapsed && lhs.unreadCount == rhs.unreadCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
                .padding(.bottom, 4)
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
                Text(SidebarStatusHeaderText.statusesAreaTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if unreadCount > 0 {
                    statusUnreadBadge(count: unreadCount, fontScale: 1, globalFontMagnificationPercent: 100)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarStatusHeaderText.statusesAreaLabel(groupCount: groupCount, isCollapsed: isCollapsed))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }
}

/// A status group's header in the SwiftUI list. It takes values only, so no row below the list boundary reads the
/// status store. It draws what the AppKit header draws: the band, the glyph, the name in the band's name color, one
/// level of indent. (#cm-110.1)
struct SidebarStatusGroupSwiftUIHeader: View, Equatable {
    let statusId: String
    let presentation: SidebarStatusGroupPresentation
    let memberCount: Int
    let isCollapsed: Bool
    let listWidth: CGFloat?
    let colorScheme: ColorScheme
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int
    var unreadCount: Int = 0
    var onToggle: @MainActor () -> Void = {}

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.statusId == rhs.statusId && lhs.presentation == rhs.presentation && lhs.memberCount == rhs.memberCount
            && lhs.isCollapsed == rhs.isCollapsed && lhs.listWidth == rhs.listWidth && lhs.colorScheme == rhs.colorScheme
            && lhs.fontScale == rhs.fontScale
            && lhs.globalFontMagnificationPercent == rhs.globalFontMagnificationPercent
            && lhs.unreadCount == rhs.unreadCount
    }

    var body: some View {
        let palette = bandPalette
        HStack(spacing: 7) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: chevronFontPointSize, weight: .semibold))
                .frame(width: 10)
            Image(nsImage: glyphImage)
            Text(presentation.name)
                .font(.system(size: nameFontPointSize, weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.primaryTextColor))
                .lineLimit(1)
            if unreadCount > 0 {
                statusUnreadBadge(count: unreadCount, fontScale: fontScale,
                                  globalFontMagnificationPercent: globalFontMagnificationPercent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .background(Color(nsColor: palette.bandColor).opacity(palette.bandOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.leading, SidebarNestedIndent.points(levels: 1, availableWidth: listWidth))
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            SidebarStatusHeaderText.statusGroupLabel(name: presentation.name, memberCount: memberCount, isCollapsed: isCollapsed)
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }

    var chevronFontPointSize: CGFloat {
        GlobalFontMagnification.scaledSize(
            SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale).chevronFontSize,
            percent: globalFontMagnificationPercent
        )
    }

    var nameFontPointSize: CGFloat {
        GlobalFontMagnification.scaledSize(
            SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale).nameFontSize,
            percent: globalFontMagnificationPercent
        )
    }

    var glyphImage: NSImage {
        let palette = bandPalette
        return SidebarStatusHeaderGlyphImage.make(
            presentation: presentation, fontScale: fontScale, colorScheme: colorScheme,
            nameColor: palette.primaryTextColor, tickColor: palette.compositedBandColor
        )
    }

    /// The band, from the one source both renderers use; neutral when his status has no linked color.
    private var bandPalette: SidebarGroupHeaderBandPalette {
        SidebarGroupHeaderBandPalette(
            tintHex: presentation.tintHex,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            renderedAppearance: .init(colorScheme: colorScheme, contrast: colorSchemeContrast)
        )
    }
}

/// Same capsule metrics as workspace-group headers, with no store reference below the list boundary.
@MainActor
private func statusUnreadBadge(count: Int, fontScale: CGFloat, globalFontMagnificationPercent: Int) -> some View {
    let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    return Text("\(count)")
        .font(.system(size: GlobalFontMagnification.scaledSize(metrics.unreadFontSize,
                                                            percent: globalFontMagnificationPercent), weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, metrics.unreadHorizontalPadding)
        .padding(.vertical, metrics.unreadVerticalPadding)
        .background(Capsule().fill(Color.accentColor))
        .accessibilityLabel(Text(String.localizedStringWithFormat(
            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"), count
        )))
}
