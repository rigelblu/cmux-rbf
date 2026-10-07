import AppKit
import CmuxSidebar
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): a nested header's band starts at its own indent, and a header with no workspace of
// its own looks different. these pin what the code draws, not how it looks.
@MainActor
@Suite("Workspace group nesting, header look", .serialized)
struct WorkspaceGroupNestedLookTests {
    private func model(
        depth: Int = 0,
        hasOwnWorkspace: Bool = true,
        isFoldedOverSelection: Bool = false,
        iconSymbol: String = "folder.fill",
        tintHex: String? = nil,
        isDark: Bool = false
    ) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            name: "Group",
            iconSymbol: iconSymbol,
            tintHex: tintHex,
            customColorHex: nil,
            isCollapsed: isFoldedOverSelection,
            isPinned: false,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 1,
            anchorUnreadCount: 0,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            globalFontMagnificationPercent: 100,
            cwdContextMenuItems: [],
            rowSpacing: 2,
            isFirstRow: true,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            colorSchemeIsDark: isDark,
            depth: depth,
            hasOwnWorkspace: hasOwnWorkspace,
            isFoldedOverSelection: isFoldedOverSelection
        )
    }

    private func cell(_ model: SidebarGroupHeaderRowModel, width: CGFloat = 240) -> SidebarGroupHeaderTableCellView {
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        cell.appearance = NSAppearance(named: model.colorSchemeIsDark ? .darkAqua : .aqua)
        cell.configurePresentation(model: model)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    @Test func aTopLevelHeaderWearsTheFullWidthBandAndEachLevelStartsTheBandTwelvePointsFurtherIn() {
        let top = cell(model(depth: 0)).bandFrameForTesting
        let one = cell(model(depth: 1)).bandFrameForTesting
        let two = cell(model(depth: 2)).bandFrameForTesting
        #expect(one.minX == top.minX + 12)
        #expect(two.minX == top.minX + 24)
        // The band ends where the top-level band ends.
        #expect(one.maxX == top.maxX)
        #expect(two.maxX == top.maxX)
    }

    @Test func theBandIndentStopsAtFortyPercentOfTheWidth() {
        let narrow = cell(model(depth: 20), width: 120).bandFrameForTesting
        let flat = cell(model(depth: 0), width: 120).bandFrameForTesting
        #expect(narrow.minX == flat.minX + 48)
    }

    @Test func aHeaderWithNoWorkspaceOfItsOwnTakesTheBandsNameColourLikeOneWithAWorkspace() {
        for scheme in [ColorScheme.light, .dark] {
            let secondary = SidebarAppearanceColorResolver().resolvedColor(.secondaryLabelColor, for: scheme)
            for tint in [nil, "#3B82F6"] as [String?] {
                let own = cell(model(hasOwnWorkspace: true, tintHex: tint, isDark: scheme == .dark))
                let none = cell(model(hasOwnWorkspace: false, tintHex: tint, isDark: scheme == .dark))
                #expect(none.nameTextColorForTesting == own.nameTextColorForTesting)
                #expect(none.nameTextColorForTesting != secondary)
            }
        }
    }

    @Test func aFoldedHeaderOverTheSelectedWorkspaceTakesTheAccentTint() {
        let folded = cell(model(hasOwnWorkspace: false, isFoldedOverSelection: true))
        #expect(folded.nameTextColorForTesting == cmuxAccentNSColor(for: .light))
        let plain = cell(model(hasOwnWorkspace: false, isFoldedOverSelection: false))
        #expect(plain.nameTextColorForTesting != cmuxAccentNSColor(for: .light))
    }

    private let dotSize = NSSize(width: 8, height: 8)

    @Test func aHeaderWithNoWorkspaceDrawsAnEightPointDotInTheIconSlotAndOneWithAWorkspaceDoesNot() {
        let none = cell(model(hasOwnWorkspace: false))
        #expect(none.iconImageForTesting?.size == dotSize)
        #expect(none.iconImageForTesting?.isTemplate == true)
        let own = cell(model(hasOwnWorkspace: true))
        #expect(own.iconImageForTesting != nil)
        #expect(own.iconImageForTesting?.size != dotSize)
    }

    @Test func theDotTakesTheGroupsTintThroughTheColorGroupDotsFunctionInLightAndDark() {
        let hex = "#3B82F6"
        for scheme in [ColorScheme.light, .dark] {
            let none = cell(model(hasOwnWorkspace: false, tintHex: hex, isDark: scheme == .dark))
            let expected = WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: scheme)
            #expect(expected != nil)
            #expect(none.iconTintForTesting == expected)
        }
    }

    @Test func theDotIsSecondaryWhenTheGroupHasNoTintOrATintThatDoesNotParse() {
        for scheme in [ColorScheme.light, .dark] {
            let secondary = SidebarAppearanceColorResolver().resolvedColor(.secondaryLabelColor, for: scheme)
            for tint in [nil, "not-a-colour"] as [String?] {
                let none = cell(model(hasOwnWorkspace: false, tintHex: tint, isDark: scheme == .dark))
                #expect(none.iconImageForTesting?.size == dotSize)
                #expect(none.iconTintForTesting == secondary)
            }
        }
    }

    @Test func aUserSetIconIsReplacedByTheDotToo() {
        let none = cell(model(hasOwnWorkspace: false, iconSymbol: "star.fill"))
        #expect(none.iconImageForTesting?.size == dotSize)
        let own = cell(model(hasOwnWorkspace: true, iconSymbol: "star.fill"))
        #expect(own.iconImageForTesting?.size != dotSize)
    }

    // In Dark the dot's tint is brightened and the symbol's tint is raw, so a stale tint shows.
    private let darkHex = "#3B82F6"

    @Test func aReusedCellDrawsTheSymbolAgainWithItsOwnRawTintAfterTheDotInDark() {
        let own = model(hasOwnWorkspace: true, tintHex: darkHex, isDark: true)
        let none = model(hasOwnWorkspace: false, tintHex: darkHex, isDark: true)
        let raw = NSColor(hex: darkHex)
        let brightened = WorkspaceTabColorSettings.displayNSColor(hex: darkHex, colorScheme: .dark)
        #expect(raw != brightened)
        let fresh = cell(own)
        let reused = cell(none)
        #expect(reused.iconImageForTesting?.size == dotSize)
        #expect(reused.iconTintForTesting == brightened)
        reused.configurePresentation(model: own)
        reused.layoutSubtreeIfNeeded()
        #expect(reused.iconImageForTesting?.size == fresh.iconImageForTesting?.size)
        #expect(reused.iconImageForTesting?.size != dotSize)
        #expect(reused.iconTintForTesting == fresh.iconTintForTesting)
        #expect(reused.iconTintForTesting == raw)
    }

    @Test func aReusedCellDrawsTheBrightenedDotAfterTheSymbolInDark() {
        let own = model(hasOwnWorkspace: true, tintHex: darkHex, isDark: true)
        let none = model(hasOwnWorkspace: false, tintHex: darkHex, isDark: true)
        let raw = NSColor(hex: darkHex)
        let brightened = WorkspaceTabColorSettings.displayNSColor(hex: darkHex, colorScheme: .dark)
        #expect(raw != brightened)
        let fresh = cell(none)
        let reused = cell(own)
        #expect(reused.iconTintForTesting == raw)
        reused.configurePresentation(model: none)
        reused.layoutSubtreeIfNeeded()
        #expect(reused.iconImageForTesting?.size == dotSize)
        #expect(reused.iconTintForTesting == fresh.iconTintForTesting)
        #expect(reused.iconTintForTesting == brightened)
    }

    /// The colour the cell paints at a point in its icon frame, read from a bitmap of the drawn cell, in sRGB.
    private func drawnColor(_ cell: SidebarGroupHeaderTableCellView, dx: CGFloat) -> NSColor? {
        guard let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return nil }
        cell.cacheDisplay(in: cell.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / cell.bounds.width
        let frame = cell.iconFrameForTesting
        let x = Int(((frame.midX + dx) * scale).rounded(.down))
        let y = Int(((cell.bounds.height - frame.midY) * scale).rounded(.down))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func near(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.05) -> Bool { // the translucent secondary colour lands up to 0.04 off in one channel
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
            && abs(a.alphaComponent - b.alphaComponent) <= tolerance
    }

    /// `foreground` painted over `background`, both straight (not premultiplied) sRGB, as the bitmap reports them.
    private func over(_ foreground: NSColor, _ background: NSColor) -> NSColor? {
        guard let f = foreground.usingColorSpace(.sRGB), let b = background.usingColorSpace(.sRGB) else { return nil }
        let alpha = f.alphaComponent + b.alphaComponent * (1 - f.alphaComponent)
        guard alpha > 0 else { return nil }
        func mix(_ fc: CGFloat, _ bc: CGFloat) -> CGFloat {
            (fc * f.alphaComponent + bc * b.alphaComponent * (1 - f.alphaComponent)) / alpha
        }
        return NSColor(
            srgbRed: mix(f.redComponent, b.redComponent),
            green: mix(f.greenComponent, b.greenComponent),
            blue: mix(f.blueComponent, b.blueComponent),
            alpha: alpha
        )
    }

    @Test func theDotIsPaintedInTheTintAtTheIconCentreAndIsNarrowerThanTheIconFrame() {
        for scheme in [ColorScheme.light, .dark] {
            let isDark = scheme == .dark
            let secondary = SidebarAppearanceColorResolver().resolvedColor(.secondaryLabelColor, for: scheme)
            let tint = WorkspaceTabColorSettings.displayNSColor(hex: "#3B82F6", colorScheme: scheme)
            for (hex, dotColor) in [("#3B82F6", tint), (nil, secondary)] as [(String?, NSColor?)] {
                let header = cell(model(hasOwnWorkspace: false, tintHex: hex, isDark: isDark))
                let centre = drawnColor(header, dx: 0)
                // 6 pt right of the centre is inside the 14 pt icon frame but outside a dot 8 pt across: only the band.
                let beside = drawnColor(header, dx: 6)
                let expected = dotColor.flatMap { color in beside.flatMap { over(color, $0) } }
                let label = "\(scheme) tint \(hex ?? "none")"
                #expect(near(centre, expected), "\(label): centre \(String(describing: centre)), expected \(String(describing: expected))")
                #expect(!near(centre, beside), "\(label): centre \(String(describing: centre)) is the band \(String(describing: beside))")
            }
        }
    }

    @Test func theAnswerIsGivenInEveryWindowBecauseItHasNoWindowToAskAbout() {
        typealias Answer = SidebarHeaderOnlyLook.Answer
        // No workspace behind the name: the look, whatever the window holds. The Answer takes no window argument,
        // so a flat window's empty pinned header cannot be told apart from a nested one's.
        let header = Answer(hasLiveAnchor: false, isCollapsed: true, selectedWorkspaceIsInside: true)
        #expect(!header.hasOwnWorkspace && header.isFoldedOverSelection)
        #expect(!Answer(hasLiveAnchor: false, isCollapsed: false, selectedWorkspaceIsInside: true).isFoldedOverSelection)
        #expect(!Answer(hasLiveAnchor: false, isCollapsed: true, selectedWorkspaceIsInside: false).isFoldedOverSelection)
        // A group with a workspace of its own: a fold moves the selection to it, so no tint.
        let own = Answer(hasLiveAnchor: true, isCollapsed: true, selectedWorkspaceIsInside: true)
        #expect(own.hasOwnWorkspace && !own.isFoldedOverSelection)
    }
}
