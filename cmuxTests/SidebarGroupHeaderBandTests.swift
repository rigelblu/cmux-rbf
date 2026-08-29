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
            customColorHex: tintHex,
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

/// Behavior tests for the shared colour submenu (`#cm-60`).
///
/// `#cm-60` put the workspace colour submenu on the group header. The risk it
/// carries is not that the menu looks wrong — it is that the two copies drift,
/// or that the group's *resolved* tint reaches the menu instead of the colour
/// the user actually picked. Both are invisible in a screenshot.
@Suite
@MainActor
struct SidebarColorSubmenuTests {
    /// Titles of everything that is not a separator, in menu order.
    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private static func item(_ menu: NSMenu, titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    /// Fires a menu item the way AppKit does, so the stored closure runs.
    private static func click(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else { return }
        _ = target.perform(action, with: item)
    }

    private static let noColorTitle = String(
        localized: "contextMenu.noColor", defaultValue: "No Color"
    )
    private static let customColorTitle = String(
        localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"
    )

    /// The one decision a test can pin: the checkmark means *you picked this*.
    ///
    /// A group's band paints `customColor ?? cwdConfig.color`, so both header views
    /// carry a resolved `tintHex`. Feeding that to the submenu instead of the override
    /// would tick a palette row on a group that merely inherited a cwd colour, and
    /// leave **No Color** looking inert on the one group where it is the truthful
    /// state. This asserts the submenu reads what it is given, so the call sites
    /// passing `customColorHex` are the whole contract.
    @Test
    func noColorIsCheckedForAnUncolouredTargetAndClearForAColouredOne() {
        let uncoloured = SidebarColorSubmenu.make(
            targetHexes: [nil], apply: { _ in }, promptCustomColor: {}
        )
        let coloured = SidebarColorSubmenu.make(
            targetHexes: ["#1565C0"], apply: { _ in }, promptCustomColor: {}
        )

        let uncolouredRow = Self.item(uncoloured, titled: Self.noColorTitle)
        let colouredRow = Self.item(coloured, titled: Self.noColorTitle)

        #expect(uncolouredRow?.state == .on)
        #expect(colouredRow?.state == .off)
    }

    /// The group menu and the workspace menu must keep drawing the same rows.
    ///
    /// They share `colorMenuCandidates` for the *data*; `#cm-60` made them share the
    /// *drawing* too, because copying it would have left four renderers of one model
    /// across the two sidebar implementations. This fails the moment one grows a row
    /// the other does not, which is how a palette change reaches one menu only.
    @Test
    func submenuRowsMatchTheSharedCandidateModelExactly() {
        let targetHexes: [String?] = [nil]
        let menu = SidebarColorSubmenu.make(
            targetHexes: targetHexes, apply: { _ in }, promptCustomColor: {}
        )

        var expected: [String] = []
        for candidate in WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: targetHexes) {
            switch candidate.kind {
            case .noColor:
                expected.append(Self.noColorTitle)
                expected.append(Self.customColorTitle)
            case let .paletteEntry(entry):
                expected.append(entry.displayName)
            case let .unlisted(hex):
                expected.append(String(
                    format: String(localized: "contextMenu.unlistedColor", defaultValue: "Custom (%@)"),
                    hex
                ))
            case .editLabels:
                expected.append(String(
                    localized: "contextMenu.editColorLabels", defaultValue: "Edit Color Labels…"
                ))
            }
        }

        #expect(Self.titles(menu) == expected)
        // The palette is the user's, so an empty expectation would pass vacuously.
        #expect(expected.count > 2)
    }

    /// **No Color** must clear, not write an empty string.
    ///
    /// `setWorkspaceGroupColor(groupId:hex:)` takes `String?` and treats `nil` as
    /// "no override"; `""` would store an unparseable colour, which `#cm-49`'s band
    /// renders as neutral — visually identical, and wrong in the model and on disk.
    @Test
    func noColorAppliesNilWhilePaletteRowsApplyTheirHex() {
        var applied: [String?] = []
        let menu = SidebarColorSubmenu.make(
            targetHexes: [nil], apply: { applied.append($0) }, promptCustomColor: {}
        )

        guard let noColor = Self.item(menu, titled: Self.noColorTitle) else {
            Issue.record("No Color row missing")
            return
        }
        Self.click(noColor)

        // Resolve the row's own hex from the shared candidate model, so the
        // assertion below is "this row applies ITS colour" rather than the far
        // weaker "it applies some colour". A mutation that made every palette
        // row apply one fixed hex survived the non-nil form of this check.
        let entries = WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: [nil])
            .compactMap { candidate -> (title: String, hex: String)? in
                if case let .paletteEntry(entry) = candidate.kind {
                    return (entry.displayName, entry.hex)
                }
                return nil
            }
        guard let expected = entries.first else {
            Issue.record("palette has no entries to click")
            return
        }
        guard let paletteRow = Self.item(menu, titled: expected.title) else {
            Issue.record("palette row \(expected.title) missing from the submenu")
            return
        }
        Self.click(paletteRow)

        #expect(applied.count == 2)
        #expect(applied.first ?? "unset" == nil)
        #expect(applied.last.flatMap { $0 } == expected.hex)
    }
}

/// The group header's own context menu (`#cm-60`), through the real cell.
///
/// `SidebarColorSubmenuTests` pins the submenu builder. These pin the two things
/// only the *call site* can get wrong, and both are invisible in a screenshot:
/// shipping the item into one sidebar renderer and not the other, and handing the
/// menu the group's resolved tint instead of the colour the user picked.
@Suite
@MainActor
struct SidebarGroupHeaderColorMenuTests {
    private static let groupColorTitle = String(
        localized: "workspaceGroup.contextMenu.color", defaultValue: "Group Color"
    )
    private static let renameTitle = String(
        localized: "workspaceGroup.contextMenu.rename", defaultValue: "Rename Group..."
    )
    private static let noColorTitle = String(
        localized: "contextMenu.noColor", defaultValue: "No Color"
    )

    private static func model(
        tintHex: String?,
        customColorHex: String?
    ) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            name: "Group",
            iconSymbol: "folder",
            tintHex: tintHex,
            customColorHex: customColorHex,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 2,
            anchorUnreadCount: 0,
            canMarkRead: false,
            canMarkUnread: true,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: true,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            globalFontMagnificationPercent: 100,
            cwdContextMenuItems: [],
            rowSpacing: 2,
            isFirstRow: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false
        )
    }

    private static func actions(
        onSetColor: @escaping (String?) -> Void = { _ in }
    ) -> SidebarGroupHeaderRowActions {
        SidebarGroupHeaderRowActions(
            onToggleCollapsed: {},
            onFocusAnchor: { _ in },
            onTapPlus: {},
            onRunResolvedItem: { _ in },
            onRename: {},
            onSetColor: onSetColor,
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

    /// The header menu the cell would show on a right-click away from the plus button.
    private static func headerMenu(
        tintHex: String?,
        customColorHex: String?,
        onSetColor: @escaping (String?) -> Void = { _ in }
    ) throws -> NSMenu {
        let cell = SidebarGroupHeaderTableCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        cell.layoutSubtreeIfNeeded()
        cell.configure(
            model: model(tintHex: tintHex, customColorHex: customColorHex),
            actions: actions(onSetColor: onSetColor),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        // Far from the trailing plus button, so this is the header menu and not
        // the plus button's own.
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 4, y: 4),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        return try #require(cell.menu(for: event))
    }

    /// The item exists at all, in the AppKit renderer — the one Tom actually sees.
    ///
    /// `CmuxFeatureFlags.appKitSidebarListDefault` is `true`, so this list is the
    /// default. Its SwiftUI twin carries the same item; nothing but a human opening
    /// both menus proves that half, which is why the dogfood scenario exists.
    @Test
    func groupHeaderMenuOffersGroupColorRightAfterRename() throws {
        let menu = try Self.headerMenu(tintHex: nil, customColorHex: nil)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        let renameIndex = try #require(titles.firstIndex(of: Self.renameTitle))
        let colorIndex = try #require(titles.firstIndex(of: Self.groupColorTitle))

        // Identity together: name, then colour, then where it sits.
        #expect(colorIndex == renameIndex + 1)
        #expect(menu.items.first { $0.title == Self.groupColorTitle }?.submenu != nil)
    }

    /// The checkmark means *you picked this*, not *something resolved this for you*.
    ///
    /// A group's band paints `customColor ?? cwdConfig.color`, so the cell carries a
    /// resolved `tintHex`. Handing that to the submenu instead of `customColorHex`
    /// would tick a palette row on a group whose colour came from `cmux.json`, and
    /// leave **No Color** looking inert on the one group where it is the truth.
    @Test
    func aConfigResolvedTintDoesNotTickAPaletteRowTheUserNeverPicked() throws {
        let menu = try Self.headerMenu(tintHex: "#1565C0", customColorHex: nil)
        let submenu = try #require(menu.items.first { $0.title == Self.groupColorTitle }?.submenu)

        let noColor = try #require(submenu.items.first { $0.title == Self.noColorTitle })
        #expect(noColor.state == .on)
        // Nothing else may claim to be the group's colour.
        let ticked = submenu.items.filter { $0.state == .on }.map(\.title)
        #expect(ticked == [Self.noColorTitle])
    }

    /// The group's own colour ticks, and only it.
    ///
    /// Name the ticked row, never just count it. The first version of this asserted
    /// `count <= 1`, which zero satisfies — so a build that ticked *nothing* passed a
    /// test called "the only ticked row". A cold scope review found it; it is the same
    /// vacuous shape as the M5 mutation escape earlier in this suite, and the mutation
    /// campaign missed it because M1 was caught by the neighbouring negative test and
    /// this one was never exercised on its own.
    @Test
    func theGroupsOwnColorIsTheOnlyTickedRow() throws {
        let hex = "#1565C0"
        let expectedTitle = try #require(
            WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: [hex])
                .compactMap { candidate -> String? in
                    guard case let .paletteEntry(entry) = candidate.kind else { return nil }
                    return entry.hex.caseInsensitiveCompare(hex) == .orderedSame
                        ? entry.displayName
                        : nil
                }
                .first,
            "no palette entry carries \(hex); the fixture hex must be a palette colour"
        )

        let menu = try Self.headerMenu(tintHex: hex, customColorHex: hex)
        let submenu = try #require(menu.items.first { $0.title == Self.groupColorTitle }?.submenu)

        let noColor = try #require(submenu.items.first { $0.title == Self.noColorTitle })
        #expect(noColor.state == .off)
        #expect(submenu.items.filter { $0.state == .on }.map(\.title) == [expectedTitle])
    }

    /// **No Color** clears the override rather than storing an empty string.
    @Test
    func choosingNoColorClearsTheOverride() throws {
        var applied: [String?] = []
        let menu = try Self.headerMenu(
            tintHex: "#1565C0",
            customColorHex: "#1565C0",
            onSetColor: { applied.append($0) }
        )
        let submenu = try #require(menu.items.first { $0.title == Self.groupColorTitle }?.submenu)
        let noColor = try #require(submenu.items.first { $0.title == Self.noColorTitle })

        let action = try #require(noColor.action)
        let target = try #require(noColor.target as? NSObject)
        _ = target.perform(action, with: noColor)

        #expect(applied.count == 1)
        #expect(applied.first ?? "unset" == nil)
    }
}
