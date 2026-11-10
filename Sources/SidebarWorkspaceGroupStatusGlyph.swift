import AppKit
import CmuxWorkspaces
import SwiftUI

/// A value captured above either sidebar's lazy boundary. Placement never decides a group's own glyph.
struct SidebarWorkspaceGroupStatusGlyph: Equatable, Hashable {
    let status: WorkspaceTaskStatus
    let name: String
    let glyph: WorkspaceStatusGlyph?
    let colorHex: String?

    static func resolve(
        group: WorkspaceGroup,
        list: WorkspaceStatusList,
        colorHexes: [String: String],
        controlsEnabled: Bool
    ) -> Self? {
        guard controlsEnabled, list.source != .cmux, let statusId = group.statusId else { return nil }
        let presentation = SidebarStatusGroupPresentation.resolve(statusId: statusId, list: list, colorHexes: colorHexes)
        return Self(status: presentation.behavesAs, name: presentation.name,
                    glyph: presentation.glyph, colorHex: presentation.tintHex)
    }

    @MainActor
    func colors(colorScheme: ColorScheme, band: SidebarGroupHeaderBandPalette) -> (fill: NSColor, tick: NSColor) {
        let model = SidebarRowTaskStatusGlyphButton.Model(
            status: status, hasOverride: true, usesMonochrome: false, fontScale: 1,
            colorScheme: colorScheme, name: name, icon: glyph, colorHex: colorHex
        )
        let base = SidebarRowTaskStatusGlyphButton.rawBaseColor(
            model: model, monochromeColor: .secondaryLabelColor, neutralColor: .secondaryLabelColor
        )
        return cmuxFlooredGlyphColors(base: base, colorScheme: colorScheme, background: band.compositedBandColor, drawnAlpha: 1)
    }

    /// Both renderers draw this image: one floor calculation, one geometry path, one fill/tick pair.
    @MainActor
    func image(fontScale: CGFloat, colorScheme: ColorScheme, band: SidebarGroupHeaderBandPalette) -> NSImage {
        let colors = colors(colorScheme: colorScheme, band: band)
        return SidebarStatusHeaderGlyphImage.make(
            presentation: SidebarStatusGroupPresentation(name: name, tintHex: colorHex, glyph: glyph, behavesAs: status),
            fontScale: fontScale, colorScheme: colorScheme, nameColor: colors.fill, tickColor: colors.tick
        )
    }
}

@MainActor
extension VerticalTabsSidebar {
    static func workspaceGroupStatusGlyph(for group: WorkspaceGroup) -> SidebarWorkspaceGroupStatusGlyph? {
        SidebarWorkspaceGroupStatusGlyph.resolve(
            group: group, list: AppDelegate.statusListInUse,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            controlsEnabled: WorkspaceTodoFeature.isEnabled
        )
    }
}

@MainActor
extension SidebarGroupHeaderTableCellView {
    func applyGroupStatusGlyph(_ model: SidebarGroupHeaderRowModel, palette: SidebarGroupHeaderBandPalette) {
        guard let glyph = model.groupStatusGlyph else { return }
        iconImageView.image = glyph.image(fontScale: model.indicatorScale, // (cm-128.16)
                                         colorScheme: model.colorSchemeIsDark ? .dark : .light, band: palette)
        iconImageView.contentTintColor = nil
    }
}
