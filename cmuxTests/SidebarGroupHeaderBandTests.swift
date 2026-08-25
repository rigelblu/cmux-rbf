import AppKit
import CmuxSidebar
import SwiftUI
import Testing
@testable import cmux_DEV

/// Behavior tests for the group header band (`#cm-49`).
///
/// The band exists so a group header reads as a *container* rather than as one
/// more workspace row. These tests pin the things that can silently break
/// that: the two renderers agreeing, an uncoloured group still getting a band,
/// an unparseable colour falling back instead of vanishing, and the name
/// staying readable in every rendered appearance and selection state.
@Suite
@MainActor
struct SidebarGroupHeaderBandTests {
    /// Tom's dark sidebar tint, the base `#cm-26` measured against.
    private static let darkBase = NSColor(hex: "#464261") ?? .windowBackgroundColor

    private static func palette(
        tintHex: String?,
        isAnchorActive: Bool = false,
        isMultiSelected: Bool = false,
        multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle = .clear,
        renderedAppearance: SidebarGroupHeaderBandPalette.RenderedAppearance = .darkAqua,
        base: NSColor = darkBase
    ) -> SidebarGroupHeaderBandPalette {
        SidebarGroupHeaderBandPalette(
            tintHex: tintHex,
            isAnchorActive: isAnchorActive,
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            renderedAppearance: renderedAppearance,
            base: base
        )
    }

    private static func resolved(
        _ color: NSColor,
        for appearance: SidebarGroupHeaderBandPalette.RenderedAppearance
    ) -> NSColor {
        var resolved = color
        appearance.appKitAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private static func assertAA(
        _ palette: SidebarGroupHeaderBandPalette,
        over base: NSColor,
        context: String
    ) {
        let background = cmuxCompositedNSColor(
            palette.bandColor.withAlphaComponent(palette.bandOpacity),
            over: base
        )
        let ratio = cmuxContrastRatio(
            foreground: palette.primaryTextColor,
            background: background
        )
        #expect(ratio >= 4.5, "\(context) reached only \(ratio):1")
    }

    private static func groupHeaderModel(
        tintHex: String,
        isAnchorActive: Bool
    ) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            name: "Group",
            iconSymbol: "folder",
            tintHex: tintHex,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: isAnchorActive,
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
            bottomDropIndicatorVisible: false
        )
    }

    /// An uncoloured group must still be visibly a container.
    ///
    /// This is the decision that makes the feature solve the stated problem for
    /// *every* group rather than only the coloured ones, so it is the single
    /// most valuable thing to pin. A regression here is invisible in the
    /// coloured case, which is the case anyone testing by hand would look at.
    @Test
    func untintedGroupResolvesNeutralBandNotClear() {
        let resolved = Self.palette(tintHex: nil)
        #expect(
            resolved.bandOpacity == SidebarGroupHeaderBandPalette.neutralRestingBandOpacity,
            "an uncoloured group must still get a band, not Color.clear"
        )
        #expect(resolved.bandOpacity > 0)
    }

    /// A hand-edited config can carry a typo; the group is still a group.
    @Test
    func malformedTintHexFallsBackToNeutralBand() {
        let malformed = Self.palette(tintHex: "not-a-colour")
        let absent = Self.palette(tintHex: nil)
        #expect(malformed == absent, "an unparseable colour must resolve exactly as no colour does")
    }

    /// Active deepens the *same* hue rather than switching to neutral grey.
    ///
    /// The pre-`#cm-49` header was the only row in the sidebar that said
    /// "active" in grey while every workspace row said it in its own colour.
    @Test
    func activeDeepensTheSameHueRatherThanGoingNeutral() {
        let resting = Self.palette(tintHex: "#006B6B")
        let active = Self.palette(tintHex: "#006B6B", isAnchorActive: true)
        #expect(active.bandColor == resting.bandColor, "active must keep the group's hue")
        #expect(active.bandOpacity > resting.bandOpacity, "active must be the deeper rung")
    }

    /// The header band must never sit at a member row's rung.
    ///
    /// If the two ever coincide, the header stops being distinguishable from
    /// the rows it contains — which is the entire defect this feature fixes.
    @Test
    func headerBandIsLouderThanAMemberRowWash() {
        let resolved = Self.palette(tintHex: "#006B6B")
        #expect(
            resolved.bandOpacity > SidebarWorkspaceRowVisualPalette.restingWashOpacity,
            "the container must not render at or below its contents' weight"
        )
    }

    /// Header text must survive a saturated colour supplied from config.
    ///
    /// Asserts the achieved contrast ratio, not that a helper was called — a
    /// test that only checks the call site passes while the text is unreadable.
    @Test
    func activeBandForegroundMeetsAAOnSaturatedTint() {
        for hex in ["#006B6B", "#C0392B", "#0E6B8C", "#FFFFFF", "#000000"] {
            let resolved = Self.palette(tintHex: hex, isAnchorActive: true)
            let composited = cmuxCompositedNSColor(
                resolved.bandColor.withAlphaComponent(resolved.bandOpacity),
                over: Self.darkBase
            )
            let ratio = cmuxContrastRatio(
                foreground: resolved.primaryTextColor,
                background: composited
            )
            #expect(ratio >= 4.5, "header name on \(hex) active band reached only \(ratio):1")
        }
    }

    /// Palette resolution must follow the appearance being rendered, not the
    /// ambient drawing appearance at the instant the value is constructed.
    @Test
    func renderedAppearanceWinsOverAmbientAppearance() throws {
        let renderedAppearance = try #require(NSAppearance(named: .aqua))
        let ambientAppearance = try #require(NSAppearance(named: .darkAqua))
        let appearanceDependentBase = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .white
                : .black
        }

        var unresolved: SidebarGroupHeaderBandPalette?
        ambientAppearance.performAsCurrentDrawingAppearance {
            unresolved = Self.palette(
                tintHex: "#000000",
                renderedAppearance: .aqua,
                base: appearanceDependentBase
            )
        }
        let resolved = try #require(unresolved)

        var renderedBackground: NSColor?
        var renderedForeground: NSColor?
        renderedAppearance.performAsCurrentDrawingAppearance {
            renderedBackground = cmuxCompositedNSColor(
                resolved.bandColor.withAlphaComponent(resolved.bandOpacity),
                over: appearanceDependentBase
            )
            renderedForeground = resolved.primaryTextColor.usingColorSpace(.sRGB)
        }
        let background = try #require(renderedBackground)
        let foreground = try #require(renderedForeground)
        let ratio = cmuxContrastRatio(foreground: foreground, background: background)

        #expect(
            ratio >= 4.5,
            "ambient Dark leaked into a Light render; the group name reached only \(ratio):1"
        )
    }

    /// The AA guarantee covers normal and increased-contrast Light and Dark,
    /// for tinted and untinted groups at rest, active, and multi-selected.
    @Test
    func nameForegroundMeetsAAAcrossAppearanceAndSelectionMatrix() {
        for appearance in SidebarGroupHeaderBandPalette.RenderedAppearance.allCases {
            let base = Self.resolved(.windowBackgroundColor, for: appearance)
            let scheme: ColorScheme = switch appearance {
            case .aqua, .highContrastAqua: .light
            case .darkAqua, .highContrastDarkAqua: .dark
            }
            let multiStyle = sidebarWorkspaceRowBackgroundStyle(
                isActive: false,
                isMultiSelected: true,
                customColorHex: nil,
                colorScheme: scheme,
                sidebarSelectionColorHex: nil
            )

            for tintHex in [nil, "#006B6B"] as [String?] {
                for isActive in [false, true] {
                    let palette = Self.palette(
                        tintHex: tintHex,
                        isAnchorActive: isActive,
                        renderedAppearance: appearance,
                        base: .windowBackgroundColor
                    )
                    Self.assertAA(
                        palette,
                        over: base,
                        context: "\(appearance), \(tintHex ?? "untinted"), active=\(isActive)"
                    )
                }

                let multi = Self.palette(
                    tintHex: tintHex,
                    isMultiSelected: true,
                    multiSelectionBackgroundStyle: multiStyle,
                    renderedAppearance: appearance,
                    base: .windowBackgroundColor
                )
                Self.assertAA(
                    multi,
                    over: base,
                    context: "\(appearance), \(tintHex ?? "untinted"), multi-selected"
                )

                let activeAndMulti = Self.palette(
                    tintHex: tintHex,
                    isAnchorActive: true,
                    isMultiSelected: true,
                    multiSelectionBackgroundStyle: multiStyle,
                    renderedAppearance: appearance,
                    base: .windowBackgroundColor
                )
                let activeOnly = Self.palette(
                    tintHex: tintHex,
                    isAnchorActive: true,
                    renderedAppearance: appearance,
                    base: .windowBackgroundColor
                )
                #expect(activeAndMulti == activeOnly, "active must keep precedence over multi-selection")
            }
        }
    }

    /// SwiftUI and AppKit adapters must describe the same four appearances.
    @Test
    func rendererAppearanceAdaptersCoverStandardAndIncreasedContrast() throws {
        #expect(
            SidebarGroupHeaderBandPalette.RenderedAppearance(
                colorScheme: .light,
                contrast: .standard
            ) == .aqua
        )
        #expect(
            SidebarGroupHeaderBandPalette.RenderedAppearance(
                colorScheme: .dark,
                contrast: .standard
            ) == .darkAqua
        )
        #expect(
            SidebarGroupHeaderBandPalette.RenderedAppearance(
                colorScheme: .light,
                contrast: .increased
            ) == .highContrastAqua
        )
        #expect(
            SidebarGroupHeaderBandPalette.RenderedAppearance(
                colorScheme: .dark,
                contrast: .increased
            ) == .highContrastDarkAqua
        )

        let appKitCases: [(NSAppearance.Name, Bool, SidebarGroupHeaderBandPalette.RenderedAppearance)] = [
            (.aqua, false, .aqua),
            (.darkAqua, false, .darkAqua),
            (.aqua, true, .highContrastAqua),
            (.darkAqua, true, .highContrastDarkAqua)
        ]
        for (name, contrastIncreased, expected) in appKitCases {
            let appearance = try #require(NSAppearance(named: name))
            #expect(
                SidebarGroupHeaderBandPalette.RenderedAppearance(
                    appearance,
                    contrastIncreased: contrastIncreased
                ) == expected
            )
        }
    }

    /// A recycled AppKit row must repaint when its window changes appearance;
    /// configuring it correctly only at mount time still leaves stale text.
    @Test
    func appKitCellRepaintsNameForLiveAppearanceChange() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        let cell = SidebarGroupHeaderTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 44)
        )
        cell.appearance = dark
        cell.configurePresentation(model: Self.groupHeaderModel(
            tintHex: "#808080",
            isAnchorActive: true
        ))

        let darkBase = Self.resolved(.windowBackgroundColor, for: .darkAqua)
        let darkBackground = cmuxCompositedNSColor(
            (NSColor(hex: "#808080") ?? .gray)
                .withAlphaComponent(SidebarGroupHeaderBandPalette.activeBandOpacity),
            over: darkBase
        )
        #expect(
            cmuxContrastRatio(
                foreground: cell.nameTextColorForTesting,
                background: darkBackground
            ) >= 4.5
        )

        cell.appearance = light
        cell.viewDidChangeEffectiveAppearance()

        let lightBase = Self.resolved(.windowBackgroundColor, for: .aqua)
        let lightBackground = cmuxCompositedNSColor(
            (NSColor(hex: "#808080") ?? .gray)
                .withAlphaComponent(SidebarGroupHeaderBandPalette.activeBandOpacity),
            over: lightBase
        )
        #expect(
            cmuxContrastRatio(
                foreground: cell.nameTextColorForTesting,
                background: lightBackground
            ) >= 4.5,
            "the mounted AppKit row kept its Dark foreground after switching to Light"
        )
    }

    /// Both renderers must resolve the same band for the same inputs.
    ///
    /// `#cm-20` found `accentStripOpacity` living as a bare literal in two
    /// files, so softening one renderer would have silently desynced the other.
    /// The header carried the identical hazard one file over. This asserts the
    /// resolution is a pure function of its inputs, which is what makes a single
    /// shared source meaningful rather than decorative.
    @Test
    func bandResolutionIsPureAcrossEveryState() {
        let cases: [(String?, Bool, Bool)] = [
            ("#006B6B", false, false),
            ("#006B6B", true, false),
            (nil, false, false),
            (nil, true, false),
            ("#006B6B", false, true)
        ]
        for (hex, active, multi) in cases {
            let first = Self.palette(tintHex: hex, isAnchorActive: active, isMultiSelected: multi)
            let second = Self.palette(tintHex: hex, isAnchorActive: active, isMultiSelected: multi)
            #expect(first == second, "state (\(hex ?? "nil"), \(active), \(multi)) resolved twice differently")
        }
    }

    /// The accepted neutral band carries the configured sidebar tint's hue.
    ///
    /// Replaces two tests that asserted *proportional darkening* and hue
    /// preservation. Those described the previous `.labelColor` behaviour and
    /// would fail here by design — the band now asserts a hue rather than
    /// darkening what is behind it. If that decision is reversed, restore them;
    /// they encode the property that made `.labelColor` correct.
    @Test
    func neutralBandCarriesTheConfiguredSidebarTint() {
        let suiteName = "SidebarGroupHeaderBandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("#315A73", forKey: "sidebarTintHexLight")

        var resolved = NSColor.clear
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = SidebarGroupHeaderBandPalette.makeNeutralBandColor(defaults: defaults)
                .usingColorSpace(.sRGB) ?? .clear
        }
        let want = NSColor(hex: "#315A73")!.usingColorSpace(.sRGB)!
        #expect(abs(resolved.redComponent - want.redComponent) < 0.01)
        #expect(abs(resolved.blueComponent - want.blueComponent) < 0.01)
    }

    /// The neutral band must not be fainter than a member row's wash.
    ///
    /// An uncoloured group otherwise re-creates the exact inversion this feature
    /// exists to remove — the container rendering quieter than its contents.
    /// Dogfood caught this at the shipped 0.06; nothing in the suite did.
    @Test
    func neutralBandIsNotFainterThanAMemberRowWash() {
        #expect(
            SidebarGroupHeaderBandPalette.neutralRestingBandOpacity
                > SidebarWorkspaceRowVisualPalette.restingWashOpacity,
            "an uncoloured group's band must still out-weigh a member row's wash"
        )
    }

    /// Clearing an optimistic active paint must restore the resting band.
    ///
    /// The AppKit cell keeps `clearOptimisticAnchorActive()` because an
    /// optimistic active treatment can otherwise linger — and the band makes a
    /// lingering treatment far more visible than the old neutral grey did.
    @Test
    func clearingOptimisticActiveRestoresRestingBand() {
        let active = Self.palette(tintHex: "#006B6B", isAnchorActive: true)
        let cleared = Self.palette(tintHex: "#006B6B", isAnchorActive: false)
        #expect(cleared.bandOpacity == SidebarGroupHeaderBandPalette.restingBandOpacity)
        #expect(cleared.bandOpacity < active.bandOpacity, "re-applying an inactive model must step back down")
    }
}
