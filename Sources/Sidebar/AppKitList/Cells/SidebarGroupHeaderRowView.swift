import AppKit
import CmuxFoundation
import CmuxWorkspaces // (#cm-110.1)
import SwiftUI

/// Pure-AppKit group header cell for the sidebar workspace table.
///
/// Renders the collapsible group/folder header (pin, chevron, tinted icon,
/// name, unread capsule, hover-revealed plus button) without any SwiftUI
/// hosting so scroll, hover, and reconfigure stay off the AttributeGraph.
/// Layout is manual: subviews are created once and framed in `layout()`.
@MainActor
final class SidebarGroupHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarGroupHeaderTableCellView")

    private let backgroundView = NSView()
    private let hairlineView = NSView() // (#cm-110.1)
    private let pinImageView = NSImageView()
    private let chevronButton = SidebarHeaderGlyphButton()
    let iconImageView = NSImageView() // (#cm-110.2) shared group-status paint extension
    let groupStatusPopover = SidebarWorkspaceGroupStatusPopoverHost() // (#cm-110.2)
    private let nameField = NSTextField(labelWithString: "")
    // Direct-draw badge (shared with workspace rows): NSTextField's
    // intrinsic insets shift single digits off the circle's optical center.
    private let unreadBadgeView = SidebarRowUnreadBadgeView()
    private var unreadBadgeFont: NSFont = .systemFont(ofSize: 10, weight: .semibold)
    private let plusButton = SidebarHeaderGlyphButton()
    private let topDropIndicator = SidebarReorderIndicatorView()
    private let bottomDropIndicator = SidebarReorderIndicatorView()
    private let hintPill = SidebarShortcutHintPillView()

    private var model: SidebarGroupHeaderRowModel?
    private var actions: SidebarGroupHeaderRowActions?
    private var isPointerHovering = false
    private var contextMenuVisible = false
    private var contextMenuDidOpen: (() -> Void)?
    private var contextMenuDidClose: (() -> Void)?

    override var isFlipped: Bool { true }

    override func accessibilityPerformPress() -> Bool { // (#cm-110.1)
        guard model?.statusHeaderKind != nil else { return super.accessibilityPerformPress() } // (#cm-110.1)
        guard let actions else { return false } // (#cm-110.1)
        actions.onToggleCollapsed() // (#cm-110.1)
        return true // (#cm-110.1)
    } // (#cm-110.1)

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Manual layout: the table resizes recycled cells after configure, so
        // a size change must always re-run layout() or slots keep the widths
        // they had at make time.
        if changed {
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        // Drop indicators paint into the inter-row gap above/below the cell.
        layer?.masksToBounds = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 4
        backgroundView.layer?.cornerCurve = .continuous
        addSubview(backgroundView)

        hairlineView.wantsLayer = true // (#cm-110.1)
        hairlineView.isHidden = true // (#cm-110.1)
        addSubview(hairlineView) // (#cm-110.1)

        pinImageView.imageScaling = .scaleProportionallyDown
        addSubview(pinImageView)

        chevronButton.onClick = { [weak self] in self?.actions?.onToggleCollapsed() }
        addSubview(chevronButton)

        iconImageView.imageScaling = .scaleProportionallyDown
        addSubview(iconImageView)
        groupStatusPopover.install(in: self) // (#cm-110.2)

        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
        addSubview(nameField)

        addSubview(unreadBadgeView)

        plusButton.onClick = { [weak self] in self?.actions?.onTapPlus() }
        plusButton.menuProvider = { [weak self] in self?.makePlusMenu() }
        addSubview(plusButton)

        topDropIndicator.wantsLayer = true
        bottomDropIndicator.wantsLayer = true
        addSubview(topDropIndicator)
        addSubview(bottomDropIndicator)

        addSubview(hintPill)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        suspendPresentation()
        model = nil
        hairlineView.isHidden = true // (#cm-110.1)
        hintPill.resetForReuse()
        resetStatusHeaderLook() // (#cm-110.1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let model else { return }
        applyModel(model)
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        guard let model else { return }
        applyModel(model)
    }

    func suspendPresentation() {
        actions = nil
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        contextMenuVisible = false
    }

    func configurePresentation(model: SidebarGroupHeaderRowModel) {
        suspendPresentation()
        guard self.model != model else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    // MARK: Configure

    func configure(
        model: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        let requiresFullApply = self.actions == nil
        let previous = self.model
        if previous?.groupId != model.groupId || previous?.statusHeaderKind != model.statusHeaderKind { groupStatusPopover.close() } // (#cm-110.2)
        self.actions = actions
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        groupStatusPopover.configure(menu: model.statusHeaderKind == nil ? model.groupStatusMenu : nil, // (#cm-110.2)
            showsGlyph: model.statusHeaderKind == nil && model.groupStatusGlyph != nil, // (#cm-110.2)
            name: model.groupStatusGlyph?.name, apply: actions.onSetStatus) // (#cm-110.2)
        let hoverChanged = self.isPointerHovering != isPointerHovering
        self.isPointerHovering = isPointerHovering
        guard requiresFullApply || previous != model || hoverChanged else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    private func applyModel(_ model: SidebarGroupHeaderRowModel) {
        // Legacy parity: no implicit layer actions on content/color changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if model.statusHeaderKind != nil { applyStatusHeader(model); return } // (#cm-110.1) the status headers draw in the extension at the end of this file
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent
        let headerPalette = bandPalette(for: model)
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        let colorResolver = SidebarAppearanceColorResolver()

        pinImageView.isHidden = !model.isPinned
        if model.isPinned {
            pinImageView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "pin.fill",
                pointSize: GlobalFontMagnification.scaledSize(metrics.pinnedIconFontSize, percent: percent),
                weight: .semibold
            )
            pinImageView.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
            pinImageView.toolTip = String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
            pinImageView.setAccessibilityLabel(String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")) // (#cm-106)
        }

        chevronButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: model.isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: GlobalFontMagnification.scaledSize(metrics.chevronFontSize, percent: percent),
            weight: .semibold
        )
        chevronButton.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
        chevronButton.setAccessibilityLabel(
            model.isCollapsed
                ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        )

        let iconSymbol = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: model.iconSymbol, configured: nil)
        iconImageView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: iconSymbol,
            pointSize: GlobalFontMagnification.scaledSize(metrics.iconFontSize, percent: percent),
            weight: .semibold
        )
        iconImageView.contentTintColor = model.tintHex.flatMap { NSColor(hex: $0) }
            ?? colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
        if !model.hasOwnWorkspace { // (#cm-106) a dot where the icon was
            iconImageView.image = SidebarHeaderOnlyLook.dotImage(scale: model.indicatorScale) // (cm-128.16)
            iconImageView.contentTintColor = SidebarHeaderOnlyLook.dotTint(tintHex: model.tintHex, colorScheme: colorScheme)
                ?? colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
        }

        applyGroupStatusGlyph(model, palette: headerPalette) // (#cm-110.2)

        nameField.stringValue = model.name
        nameField.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .semibold
        )
        nameField.textColor = nameTextColor(model, palette: headerPalette) // (#cm-106)

        let showsBadge = model.anchorUnreadCount > 0 || model.anchorMarkedUnread
        unreadBadgeView.isHidden = !showsBadge
        if showsBadge {
            unreadBadgeFont = .systemFont(
                ofSize: GlobalFontMagnification.scaledSize(metrics.unreadFontSize, percent: percent),
                weight: .semibold
            )
            unreadBadgeView.configure(
                count: model.anchorUnreadCount,
                markedUnread: model.anchorMarkedUnread,
                markColor: headerPalette.unreadMarkColor(isActive: model.isAnchorActive, colorScheme: colorScheme, sidebarStandIn: model.contrastBackgroundHex.flatMap { NSColor(hex: $0) }, drawsBand: !(model.statusHeaderKind?.isSection ?? false)),
                markDiameter: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: model.indicatorScale), // (cm-128.16)
                fillColor: .controlAccentColor,
                textColor: .white,
                font: unreadBadgeFont
            )
            unreadBadgeView.setAccessibilityLabel(String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                model.anchorUnreadCount
            ))
            if model.anchorUnreadCount == 0 { unreadBadgeView.setAccessibilityLabel(nil) }
        }

        plusButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus",
            pointSize: GlobalFontMagnification.scaledSize(metrics.plusFontSize, percent: percent),
            weight: .medium
        )
        plusButton.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
        plusButton.setAccessibilityLabel(String(
            localized: "workspaceGroup.newWorkspaceInGroup.a11y",
            defaultValue: "New workspace in group"
        ))

        backgroundView.layer?.cornerRadius = model.isMultiSelected && !model.isAnchorActive
            ? 6
            : 4
        backgroundView.layer?.backgroundColor = headerPalette.bandColor
            .withAlphaComponent(headerPalette.bandOpacity).cgColor

        let accent = cmuxAccentNSColor(for: colorScheme)
        topDropIndicator.layer?.backgroundColor = accent.cgColor
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible

        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: GlobalFontMagnification.scaledSize(9, percent: percent),
            emphasis: model.isAnchorActive ? 1.0 : 0.9,
            representedIdentity: model.groupId
        )

        alphaValue = model.isBeingDragged ? 0.6 : 1
        updatePlusVisibility()
        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(model.groupId.uuidString)")
        setAccessibilityLabel(model.name)
        // The level, whether it is open, and when no workspace stands behind the name (#cm-106).
        setAccessibilityValue(SidebarNestedAccessibility.value(depth: model.depth, hasOwnWorkspace: model.hasOwnWorkspace))
        setAccessibilityDisclosureLevel(SidebarNestedAccessibility.disclosureLevel(forDepth: model.depth))
        setAccessibilityExpanded(!model.isCollapsed)
        // A click on a header with no workspace of its own folds it; say so, as the SwiftUI header does (#cm-106).
        setAccessibilityHelp(model.hasOwnWorkspace ? nil : String(
            localized: "workspaceGroup.noOwnWorkspace.hint.a11y",
            defaultValue: "Fold or unfold the group"
        ))
    }

    /// Live drop-line painting during native reorder drags; see
    /// `SidebarWorkspaceRowTableCellView.paintControllerDropIndicator`.
    func paintControllerDropIndicator(top: Bool, bottom: Bool, level: Int? = nil) {
        let colorScheme: ColorScheme = model.map { $0.colorSchemeIsDark ? .dark : .light }
            ?? SidebarAppearanceColorResolver().currentColorScheme()
        let accent = cmuxAccentNSColor(for: colorScheme)
        topDropIndicator.layer?.backgroundColor = accent.cgColor
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor
        topDropIndicator.isHidden = !top
        bottomDropIndicator.isHidden = !bottom
        // The line is indented to the level the drop lands at; a window with no nested group passes none (#cm-106).
        if dropLineLevel != level {
            dropLineLevel = level
            applyDropLineInset()
        }
    }

    /// How many groups hold the rows the drop lands among, while a reorder drag paints this header; nil keeps the
    /// lines as they were before nested groups (#cm-106).
    private var dropLineLevel: Int?

    private func dropLineLeadingInsets(width: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        guard let level = dropLineLevel else { return (0, SidebarWorkspaceGroupHeaderMetrics.memberScopedDropIndicatorLeadingInset) }
        let inset = SidebarNestedIndent.points(levels: level, availableWidth: width)
        return (inset, inset)
    }

    private func applyDropLineInset() {
        let insets = dropLineLeadingInsets(width: bounds.width)
        for (line, inset) in [(topDropIndicator, insets.top), (bottomDropIndicator, insets.bottom)] {
            let leading = SidebarReorderIndicatorView.horizontalInset + inset
            line.frame = NSRect(
                x: bounds.minX + leading, y: line.frame.minY,
                width: max(0, bounds.width - leading - SidebarReorderIndicatorView.horizontalInset),
                height: SidebarReorderIndicatorView.thickness
            )
        }
    }

#if DEBUG
    var dropIndicatorPaintForTesting: (top: Bool, bottom: Bool) {
        (!topDropIndicator.isHidden, !bottomDropIndicator.isHidden)
    }

    /// The laid-out frames of the two drop lines, in the header's coordinates.
    var dropIndicatorFramesForTesting: (top: NSRect, bottom: NSRect) {
        (topDropIndicator.frame, bottomDropIndicator.frame)
    }

    var nameTextColorForTesting: NSColor {
        nameField.textColor ?? .clear
    }

    /// Where the band is drawn, in the cell's own coordinates (#cm-106).
    var bandFrameForTesting: NSRect { backgroundView.frame }

    /// The icon's symbol image and tint (#cm-106).
    var iconTintForTesting: NSColor? { iconImageView.contentTintColor }

    /// The model the cell was last given, and the image its icon view holds (#cm-106). A test that mounts the real
    /// sidebar reads these to see what the app's own builder produced and what the cell drew from it.
    var currentModelForTesting: SidebarGroupHeaderRowModel? { model }
    var iconImageForTesting: NSImage? { iconImageView.image }

    /// Where the icon view sits, in the cell's own coordinates (#cm-106).
    var iconFrameForTesting: NSRect { iconImageView.frame }

    var chevronButtonForTesting: NSView { chevronButton } // (cm-128.16)
    var pinImageViewForTesting: NSImageView { pinImageView } // (cm-128.16)
    var plusButtonForTesting: NSView { plusButton } // (cm-128.16)
    var unreadBadgeViewForTesting: SidebarRowUnreadBadgeView { unreadBadgeView } // (cm-128.16)
    var nameFontForTesting: NSFont? { nameField.font } // (cm-128.16)
#endif

    private func updatePlusVisibility() {
        if model?.statusHeaderKind != nil { // (#cm-110.1)
            plusButton.setRevealed(false) // (#cm-110.1)
            return // (#cm-110.1)
        } // (#cm-110.1)
        let showsHint = model?.shortcutHintText != nil
        plusButton.setRevealed(isPointerHovering && !contextMenuVisible && !showsHint)
    }

    /// Authoritative hover enforcement: the controller sweeps visible cells
    /// so hover-revealed chrome cannot strand on rows the pointer left
    /// (row-index/id races during churn made per-transition repaints miss).
    func enforcePointerHovering(_ hovering: Bool) {
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
        updatePlusVisibility()
    }

    /// Optimistic press treatment: paints the anchor-active header visuals
    /// instantly (group clicks focus the anchor workspace); the next
    /// authoritative configure reconciles.
    func showOptimisticAnchorActive() {
        guard model?.statusHeaderKind == nil else { return } // (#cm-110.1)
        guard let model, !model.isAnchorActive else { return }
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        let labelColor = SidebarAppearanceColorResolver().resolvedColor(.labelColor, for: colorScheme)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 4
        let palette = bandPalette(for: model, isAnchorActive: true)
        backgroundView.layer?.backgroundColor = palette.bandColor
            .withAlphaComponent(palette.bandOpacity).cgColor
        CATransaction.commit()
        nameField.textColor = nameTextColor(model, palette: palette) // (#cm-106)
        applyGroupStatusGlyph(model, palette: palette) // (#cm-110.2)
    }

    /// Modifier-click preview: paints the same dim membership tint as an
    /// unfocused multi-selected workspace row.
    func showOptimisticMultiSelection() {
        guard model?.statusHeaderKind == nil else { return } // (#cm-110.1)
        guard let model, !model.isAnchorActive, !model.isMultiSelected else { return }
        let palette = bandPalette(for: model, isMultiSelected: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.backgroundColor = palette.bandColor
            .withAlphaComponent(palette.bandOpacity).cgColor
        CATransaction.commit()
        nameField.textColor = nameTextColor(model, palette: palette) // (#cm-106)
        applyGroupStatusGlyph(model, palette: palette) // (#cm-110.2)
    }

    /// Plain-click counterpart: clears active and multi-selected header paint
    /// while the authoritative single selection is applied.
    func showOptimisticDeselection() {
        guard model?.statusHeaderKind == nil else { return } // (#cm-110.1)
        guard let model, model.isAnchorActive || model.isMultiSelected else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 4
        let palette = bandPalette(for: model, isAnchorActive: false, isMultiSelected: false)
        backgroundView.layer?.backgroundColor = palette.bandColor
            .withAlphaComponent(palette.bandOpacity).cgColor
        CATransaction.commit()
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        nameField.textColor = nameTextColor(model, palette: palette) // (#cm-106)
        applyGroupStatusGlyph(model, palette: palette) // (#cm-110.2)
    }

    /// The name's colour: the accent tint while a folded header holds the selected workspace, else the band's own (#cm-106).
    private func nameTextColor(_ model: SidebarGroupHeaderRowModel, palette: SidebarGroupHeaderBandPalette) -> NSColor {
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        if model.isFoldedOverSelection { return cmuxAccentNSColor(for: colorScheme) }
        return palette.primaryTextColor
    }

    /// Rollback for optimistic press paint: reapplies the stored model
    /// unconditionally, mirroring the workspace cell. This must not skip
    /// active models — `showOptimisticDeselection` can clear a header whose
    /// model is still anchor-active, and a press that never produces an
    /// authoritative apply (swallowed, superseded, became a drag) would
    /// otherwise leave that header visually deselected until the next render.
    func restoreStoredModelPaint() {
        guard let model else { return }
        applyModel(model)
    }

    /// The band behind this header, from the one shared source the SwiftUI
    /// renderer also consumes (`#cm-49`). The optimistic paint paths below take
    /// the same resolution with an overridden state, so a press, a preview, and
    /// the authoritative apply cannot disagree about what a header looks like.
    private func bandPalette(
        for model: SidebarGroupHeaderRowModel,
        isAnchorActive: Bool? = nil,
        isMultiSelected: Bool? = nil
    ) -> SidebarGroupHeaderBandPalette {
        SidebarGroupHeaderBandPalette(
            tintHex: model.tintHex,
            isAnchorActive: isAnchorActive ?? model.isAnchorActive,
            isMultiSelected: isMultiSelected ?? model.isMultiSelected,
            multiSelectionBackgroundStyle: model.multiSelectionBackgroundStyle,
            renderedAppearance: .init(effectiveAppearance)
        )
    }

    /// True when a press at this view should not repaint selection (chevron
    /// toggles collapse, plus creates a workspace — neither selects).
    func selectionPreviewShouldIgnore(_ hitView: NSView) -> Bool {
        if model?.statusHeaderKind != nil { return true } // (#cm-110.1)
        if hitView === groupStatusPopover.button || hitView.isDescendant(of: groupStatusPopover.button) { return true } // (#cm-110.2)
        return hitView === chevronButton || hitView.isDescendant(of: chevronButton) // (#cm-110.1)
            || hitView === plusButton || hitView.isDescendant(of: plusButton)
    }

    // MARK: Layout

    /// Deterministic header row height for the given font scale and zoom percent. // (cm-128.16)
    static func preferredHeight(fontScale: CGFloat, globalFontMagnificationPercent: Int) -> CGFloat { // (cm-128.16)
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale) // (cm-128.16)
        let percent = globalFontMagnificationPercent // (cm-128.16)
        let nameFont = NSFont.systemFont( // (cm-128.16)
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent), // (cm-128.16)
            weight: .semibold // (cm-128.16)
        ) // (cm-128.16)
        let nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading) // (cm-128.16)
        let chevronFrame = GlobalFontMagnification.scaledSize(metrics.chevronFrame, percent: percent) // (cm-128.16)
        let iconFrame = GlobalFontMagnification.scaledSize(metrics.iconFrame, percent: percent) // (cm-128.16)
        let plusFrame = GlobalFontMagnification.scaledSize(metrics.plusFrame, percent: percent) // (cm-128.16)
        let content = max(chevronFrame, iconFrame, plusFrame, nameLineHeight) // (cm-128.16)
        return ceil(content + 10) // (cm-128.16)
    } // (cm-128.16)

    /// Deterministic row height; must stay in lockstep with `layout()`.
    static func preferredHeight(model: SidebarGroupHeaderRowModel) -> CGFloat {
        preferredHeight( // (cm-128.16)
            fontScale: model.fontScale, // (cm-128.16)
            globalFontMagnificationPercent: model.globalFontMagnificationPercent // (cm-128.16)
        ) // (cm-128.16)
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        // No implicit actions during manual layout (legacy parity —
        // geometry snaps, never interpolates).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent // (cm-128.16)
        let chevronFrame = GlobalFontMagnification.scaledSize(metrics.chevronFrame, percent: percent) // (cm-128.16)
        let iconFrame = GlobalFontMagnification.scaledSize(metrics.iconFrame, percent: percent) // (cm-128.16)
        let plusFrame = GlobalFontMagnification.scaledSize(metrics.plusFrame, percent: percent) // (cm-128.16)
        let outerPad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        // A nested header's band starts at its own indent, 12 pt per level; a top-level header's is full width (#cm-106).
        let indent = SidebarNestedIndent.points(levels: model.depth, availableWidth: bounds.width)
        let bgFrame = NSRect(x: outerPad + indent, y: 0, width: bounds.width - outerPad * 2 - indent, height: bounds.height)
        backgroundView.frame = bgFrame
        let contentMaxX = bgFrame.maxX - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let midY = bounds.height / 2
        var x = bgFrame.minX

        func centered(_ size: CGFloat) -> NSRect {
            NSRect(x: x, y: midY - size / 2, width: size, height: size)
        }

        if !pinImageView.isHidden {
            pinImageView.frame = centered(iconFrame) // (cm-128.16)
            x = pinImageView.frame.maxX + 4
        }
        chevronButton.frame = centered(chevronFrame) // (cm-128.16)
        x = chevronButton.frame.maxX + 4

        let plusSide = plusFrame // (cm-128.16)
        plusButton.frame = NSRect(x: contentMaxX - plusSide, y: midY - plusSide / 2, width: plusSide, height: plusSide)

        if !iconImageView.isHidden { // (#cm-110.1)
            iconImageView.frame = centered(iconFrame) // (#cm-110.1) (cm-128.16)
            x = iconImageView.frame.maxX + 6 // (#cm-110.1)
        } // (#cm-110.1)

        groupStatusPopover.updateFrame(iconImageView.frame) // (#cm-110.2)

        var badgeSize = NSSize.zero
        if !unreadBadgeView.isHidden {
            if model.anchorUnreadCount == 0 && model.anchorMarkedUnread {
                let badgeSide = 16 * model.indicatorScale // (cm-128.16)
                badgeSize = NSSize(width: badgeSide, height: badgeSide) // (cm-128.16)
            } else {
                let textSize = NSString(string: "\(model.anchorUnreadCount)")
                    .size(withAttributes: [.font: unreadBadgeFont])
                badgeSize = NSSize(
                    width: ceil(textSize.width) + metrics.unreadHorizontalPadding * 2,
                    height: ceil(textSize.height) + metrics.unreadVerticalPadding * 2
                )
            }
        }

        let nameAvailable = max(0, (plusButton.frame.minX - 4) - x
            - (badgeSize.width > 0 ? badgeSize.width + 6 : 0))
        let nameSize = nameField.attributedStringValue.size()
        // The field owns ALL remaining width (truncation only when genuinely
        // out of space); the badge tracks the measured text width instead.
        nameField.frame = NSRect(
            x: x,
            y: midY - ceil(nameSize.height) / 2,
            width: nameAvailable,
            height: ceil(nameSize.height)
        )
        if !unreadBadgeView.isHidden {
            let badgeX = x + min(ceil(nameSize.width), nameAvailable) + 6
            unreadBadgeView.frame = NSRect(
                x: badgeX,
                y: midY - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            )
            unreadBadgeView.needsDisplay = true
        }

        if !hairlineView.isHidden { // (#cm-110.1)
            hairlineView.frame = NSRect( // (#cm-110.1)
                x: outerPad, // (#cm-110.1)
                y: 0, // (#cm-110.1)
                width: bounds.width - outerPad * 2, // (#cm-110.1)
                height: 1 // (#cm-110.1)
            ) // (#cm-110.1)
        } // (#cm-110.1)

        let topOffset: CGFloat = model.isFirstRow ? 0 : -(model.rowSpacing / 2)
        let lineInsets = dropLineLeadingInsets(width: bounds.width) // (#cm-106)
        topDropIndicator.position(in: bounds, at: topOffset, leadingInset: lineInsets.top)
        let bottomInset = lineInsets.bottom
        bottomDropIndicator.position(
            in: bounds,
            at: bounds.height - SidebarReorderIndicatorView.thickness + model.rowSpacing / 2,
            leadingInset: bottomInset
        )

        let pillSize = hintPill.fittingPillSize()
        hintPill.frame = NSRect(
            x: bounds.width - pillSize.width - 10 + ShortcutHintDebugSettings.clamped(model.shortcutHintXOffset),
            y: 6 + ShortcutHintDebugSettings.clamped(model.shortcutHintYOffset),
            width: pillSize.width,
            height: pillSize.height
        )
    }

    // MARK: Interaction

    // Selection has exactly one click owner: the table view's action
    // (`SidebarWorkspaceTableController.didClickTableRow`), same as workspace
    // rows. A cell-level click recognizer here would fire a second
    // `onFocusAnchor` for the same click, which cancels a modifier-click
    // toggle (add then remove) and made header multi-selection impossible.

    override func menu(for event: NSEvent) -> NSMenu? {
        if model?.statusHeaderKind != nil { return nil } // (#cm-110.1)
        let point = convert(event.locationInWindow, from: nil)
        if plusButton.frame.contains(point), !plusButton.isHidden {
            return makePlusMenu()
        }
        return makeHeaderMenu()
    }

    // MARK: Menus

    private func menuItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = MenuAction(run: action)
        return item
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    private func trackedMenu() -> NSMenu {
        let menu = SidebarRowTrackedMenu()
        menu.autoenablesItems = false
        // Keep the matching close callback alive if this row retires while
        // AppKit is still tracking its menu.
        let didOpen = contextMenuDidOpen
        let didClose = contextMenuDidClose
        menu.onOpen = { [weak self] in
            self?.contextMenuVisible = true
            self?.updatePlusVisibility()
            didOpen?()
        }
        menu.onClose = { [weak self] in
            self?.contextMenuVisible = false
            self?.updatePlusVisibility()
            didClose?()
        }
        menu.delegate = menu
        return menu
    }

    private func makePlusMenu() -> NSMenu {
        guard let actions else { return NSMenu() }
        let menu = trackedMenu()
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.newWorkspace", defaultValue: "New Workspace in Group"),
            action: actions.onTapPlus
        ))
        appendResolvedConfigItems(to: menu)
        menu.addItem(.separator())
        appendConfigAndDocsItems(to: menu)
        return menu
    }

    private func appendResolvedConfigItems(to menu: NSMenu) {
        guard let model, let actions, !model.cwdContextMenuItems.isEmpty else { return }
        menu.addItem(.separator())
        for item in model.cwdContextMenuItems {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                menu.addItem(menuItem(action.title) { actions.onRunResolvedItem(action) })
            }
        }
    }

    private func appendConfigAndDocsItems(to menu: NSMenu) {
        guard let actions else { return }
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.editConfig", defaultValue: "Edit Group Config..."),
            action: actions.onEditConfig
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.openDocs", defaultValue: "Open Workspace Groups Docs"),
            action: actions.onOpenDocs
        ))
    }

    /// `Move Group to`: `Top Level`, then every group this one may go into, indented by depth, the current place
    /// ticked. The destinations are read when the menu opens (#cm-106).
    private func appendMoveGroupItem(to menu: NSMenu, actions: SidebarGroupHeaderRowActions) {
        guard let moveMenu = actions.moveMenu() else { return }
        let parent = menuItem(
            String(localized: "workspaceGroup.contextMenu.moveTo", defaultValue: "Move Group to"),
            action: {}
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let topLevel = menuItem(
            String(localized: "workspaceGroup.contextMenu.moveTo.topLevel", defaultValue: "Top Level")
        ) { actions.onMoveGroup(nil) }
        topLevel.state = moveMenu.topLevelIsCurrent ? .on : .off
        submenu.addItem(topLevel)
        if !moveMenu.destinations.isEmpty { submenu.addItem(.separator()) }
        for destination in moveMenu.destinations {
            let item = menuItem(destination.name) { actions.onMoveGroup(destination.id) }
            item.indentationLevel = min(destination.depth, 15)
            item.state = destination.isCurrent ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func makeHeaderMenu() -> NSMenu {
        guard let model, let actions else { return NSMenu() }
        let menu = trackedMenu()
        // Resolve availability at menu-open time. The row may have retained an
        // older anchor snapshot while the group was being promoted, but the
        // action bundle owns the authoritative live notification check.
        let notificationState = actions.notificationState()
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.newWorkspace", defaultValue: "New Workspace in Group"),
            action: actions.onTapPlus
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.rename", defaultValue: "Rename Group..."),
            action: actions.onRename
        ))
        // Beside Rename, above Pin: a group's name and its colour are its identity,
        // and the pin is where it sits. Appending it near Ungroup/Delete would bury
        // an everyday action between two destructive ones.
        let colorParent = menuItem(
            String(localized: "workspaceGroup.contextMenu.color", defaultValue: "Group Color"),
            action: {}
        )
        // `customColorHex`, never `tintHex` — see SidebarGroupHeaderRowModel.
        colorParent.submenu = SidebarColorSubmenu.make(
            targetHexes: [model.customColorHex],
            apply: actions.onSetColor,
            promptCustomColor: actions.onPromptCustomColor
        )
        menu.addItem(colorParent)
        appendGroupStatusMenu(to: menu, actions: actions) // (#cm-110.2)
        menu.addItem(menuItem(
            model.isPinned
                ? String(localized: "workspaceGroup.contextMenu.unpin", defaultValue: "Unpin Group")
                : String(localized: "workspaceGroup.contextMenu.pin", defaultValue: "Pin Group"),
            action: actions.onTogglePinned
        ))
        appendMoveGroupItem(to: menu, actions: actions) // (#cm-106)
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markRead", defaultValue: "Mark Group as Read"),
            enabled: notificationState.canMarkRead,
            action: actions.onMarkRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markUnread", defaultValue: "Mark Group as Unread"),
            enabled: notificationState.canMarkUnread,
            action: actions.onMarkUnread
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            enabled: notificationState.hasLatestNotifications,
            action: actions.onClearLatestNotifications
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllRead", defaultValue: "Mark All Workspaces in Group as Read"),
            enabled: notificationState.canMarkAllRead,
            action: actions.onMarkAllRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllUnread", defaultValue: "Mark All Workspaces in Group as Unread"),
            enabled: notificationState.canMarkAllUnread,
            action: actions.onMarkAllUnread
        ))
        menu.addItem(.separator())
        appendConfigAndDocsItems(to: menu)
        menu.addItem(.separator())
        if !model.isPinned || model.memberCount > 0 || model.holdsGroups { // (#cm-106)
            menu.addItem(menuItem(
                String(localized: "workspaceGroup.contextMenu.ungroup", defaultValue: "Ungroup Workspaces"),
                action: actions.onUngroup
            ))
        }
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.delete", defaultValue: "Delete Group"),
            action: actions.onDelete
        ))
        return menu
    }
}

/// Borderless glyph button used for the header chevron and plus controls.
@MainActor
final class SidebarHeaderGlyphButton: NSButton {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    var glyphImage: NSImage? {
        didSet { image = glyphImage }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        target = self
        action = #selector(didClick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didClick() {
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    /// Arc-style hover reveal: 120ms ease-out fade instead of a hard snap.
    /// Hit-testing follows the target state immediately so a fading-out
    /// button never swallows a click.
    func setRevealed(_ revealed: Bool) {
        if revealed {
            if isHidden {
                alphaValue = 0
                isHidden = false
            }
            isEnabled = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            guard !isHidden else { return }
            isEnabled = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isEnabled else { return }
                self.isHidden = true
            })
        }
    }
}

/// AppKit rendition of the sidebar shortcut-hint capsule. The outer view owns
/// the shadow while the inner visual-effect view clips material to the capsule;
/// putting both on one unclipped layer leaves a square material background.
@MainActor
final class SidebarShortcutHintPillView: NSView {
    private static let horizontalPadding: CGFloat = 4
    private static let visibilityAnimationKey = "shortcutHintVisibility"

    private let materialView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let reduceMotionProvider: () -> Bool
    private var emphasis: Double = 1.0
    private var representedIdentity: UUID?
    private var isRevealed = false
    private var visibilityGeneration: UInt64 = 0

    init(
        reduceMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.reduceMotionProvider = reduceMotionProvider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        materialView.material = .popover
        materialView.state = .active
        materialView.blendingMode = .withinWindow
        materialView.wantsLayer = true
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.8
        addSubview(materialView)

        label.alignment = .center
        label.lineBreakMode = .byClipping
        materialView.addSubview(label)
        layer?.opacity = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String?,
        fontSize: CGFloat,
        emphasis: Double,
        representedIdentity: UUID? = nil
    ) {
        let identityChanged = self.representedIdentity != representedIdentity
        self.representedIdentity = representedIdentity
        guard let text else {
            setRevealed(false, animated: !identityChanged)
            return
        }
        self.emphasis = emphasis
        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .labelColor
        materialView.layer?.borderColor = NSColor.white.withAlphaComponent(0.30 * emphasis).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.22 * emphasis).cgColor
        setRevealed(true, animated: !identityChanged)
    }

    func fittingPillSize() -> NSSize {
        guard !isHidden else { return .zero }
        let textSize = label.sidebarNaturalCellSize
        return NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: ceil(textSize.height) + 4
        )
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        materialView.frame = bounds
        materialView.layer?.cornerRadius = radius
        label.frame = materialView.bounds.insetBy(dx: Self.horizontalPadding, dy: 2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func resetForReuse() {
        representedIdentity = nil
        isRevealed = false
        visibilityGeneration &+= 1
        applyImmediateVisibility(false)
        label.stringValue = ""
    }

    private func setRevealed(_ revealed: Bool, animated: Bool = true) {
        if !animated {
            isRevealed = revealed
            visibilityGeneration &+= 1
            applyImmediateVisibility(revealed)
            return
        }
        guard isRevealed != revealed else { return }
        isRevealed = revealed
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        if reduceMotionProvider() {
            applyImmediateVisibility(revealed)
            return
        }

        if revealed {
            if isHidden {
                layer?.opacity = 0
                isHidden = false
            }
            animateOpacity(to: 1, generation: generation)
        } else {
            guard !isHidden else {
                layer?.opacity = 0
                return
            }
            animateOpacity(to: 0, generation: generation, hidesWhenFinished: true)
        }
    }

    private func applyImmediateVisibility(_ revealed: Bool) {
        layer?.removeAnimation(forKey: Self.visibilityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = revealed ? 1 : 0
        CATransaction.commit()
        isHidden = !revealed
    }

    private func animateOpacity(
        to value: Float,
        generation: UInt64,
        hidesWhenFinished: Bool = false
    ) {
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = value
        animation.duration = ShortcutHintAnimation.visibilityDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hidesWhenFinished {
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.visibilityGeneration == generation,
                          !self.isRevealed else { return }
                    self.isHidden = true
                }
            }
        }
        layer.opacity = value
        layer.add(animation, forKey: Self.visibilityAnimationKey)
        CATransaction.commit()
    }
}

// MARK: Status headers (#cm-110.1)

/// The `Statuses` header and a status group's header. They are drawn here, not in `applyModel`, so upstream's group (#cm-110.1)
/// header code stays as it is; `applyModel` hands a model with a `statusHeaderKind` to `applyStatusHeader`. (#cm-110.1)
extension SidebarGroupHeaderTableCellView { // (#cm-110.1)
    /// A reused cell resets its accessibility role, disclosure level and expanded state to what a fresh cell reports. // (#cm-110.1)
    /// The group branch of `applyModel` sets its level and expanded state on every apply; the status branch sets neither. // (#cm-110.1)
    func resetStatusHeaderLook() { // (#cm-110.1)
        setAccessibilityRole(.unknown) // what a fresh cell reports; nil would clear it // (#cm-110.1)
        setAccessibilityDisclosureLevel(0) // (#cm-110.1)
        setAccessibilityExpanded(false) // (#cm-110.1)
    } // (#cm-110.1)

    func applyStatusHeader(_ model: SidebarGroupHeaderRowModel) { // (#cm-110.1)
        guard let kind = model.statusHeaderKind else { return } // (#cm-110.1)
        CATransaction.begin() // (#cm-110.1)
        CATransaction.setDisableActions(true) // (#cm-110.1)
        defer { CATransaction.commit() } // (#cm-110.1)
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale) // (#cm-110.1)
        let percent = model.globalFontMagnificationPercent // (#cm-110.1)
        let headerPalette = bandPalette(for: model) // (#cm-110.1)
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light // (#cm-110.1)
        let colorResolver = SidebarAppearanceColorResolver() // (#cm-110.1)

        pinImageView.isHidden = true // (#cm-110.1)
        chevronButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage( // (#cm-110.1)
            systemName: model.isCollapsed ? "chevron.right" : "chevron.down", // (#cm-110.1)
            pointSize: GlobalFontMagnification.scaledSize(metrics.chevronFontSize, percent: percent), // (#cm-110.1)
            weight: .semibold // (#cm-110.1)
        ) // (#cm-110.1)
        chevronButton.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme) // (#cm-110.1)
        chevronButton.setAccessibilityLabel(SidebarStatusHeaderText.chevronLabel(kind: kind, isCollapsed: model.isCollapsed)) // (#cm-110.1)

        switch kind { // (#cm-110.1)
        case .statusesArea, .workspacesArea, .pinnedArea: // (#cm-110.5)
            iconImageView.isHidden = true // (#cm-110.1)
            iconImageView.image = nil // (#cm-110.1)
        case .statusGroup: // (#cm-110.1)
            iconImageView.isHidden = false // (#cm-110.1)
            iconImageView.image = SidebarStatusHeaderGlyphImage.make( // (#cm-110.1)
                presentation: SidebarStatusGroupPresentation( // (#cm-110.1)
                    name: model.name, // (#cm-110.1)
                    tintHex: model.tintHex, // (#cm-110.1)
                    glyph: model.statusGlyph, // (#cm-110.1)
                    behavesAs: model.statusBehavesAs // (#cm-110.1)
                ), // (#cm-110.1)
                fontScale: model.indicatorScale, // (cm-128.16)
                colorScheme: colorScheme, // (#cm-110.1)
                nameColor: nameTextColor(model, palette: headerPalette), // (#cm-110.1)
                tickColor: headerPalette.compositedBandColor // (#cm-110.1)
            ) // (#cm-110.1)
        } // (#cm-110.1)
        iconImageView.contentTintColor = nil // (#cm-110.1)

        nameField.stringValue = model.name // (#cm-110.1)
        nameField.font = .systemFont( // (#cm-110.1)
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent), // (#cm-110.1)
            weight: .semibold // (#cm-110.1)
        ) // (#cm-110.1)
        nameField.textColor = kind.isSection // (#cm-110.4)
            ? colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme) // (#cm-110.1)
            : nameTextColor(model, palette: headerPalette) // (#cm-110.1)

        let showsBadge = model.anchorUnreadCount > 0 || model.anchorMarkedUnread // (#cm-110.1)
        unreadBadgeView.isHidden = !showsBadge // (#cm-110.1)
        if showsBadge { // (#cm-110.1)
            unreadBadgeFont = .systemFont( // (#cm-110.1)
                ofSize: GlobalFontMagnification.scaledSize(metrics.unreadFontSize, percent: percent), // (#cm-110.1)
                weight: .semibold // (#cm-110.1)
            ) // (#cm-110.1)
            unreadBadgeView.configure( // (#cm-110.1)
                count: model.anchorUnreadCount,
                markedUnread: model.anchorMarkedUnread,
                markColor: headerPalette.unreadMarkColor(isActive: model.isAnchorActive, colorScheme: colorScheme, sidebarStandIn: model.contrastBackgroundHex.flatMap { NSColor(hex: $0) }, drawsBand: !(model.statusHeaderKind?.isSection ?? false)),
                markDiameter: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: model.indicatorScale), // (cm-128.16)
                fillColor: .controlAccentColor, // (#cm-110.1)
                textColor: .white, // (#cm-110.1)
                font: unreadBadgeFont // (#cm-110.1)
            ) // (#cm-110.1)
            unreadBadgeView.setAccessibilityLabel(String.localizedStringWithFormat( // (#cm-110.1)
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"), // (#cm-110.1)
                model.anchorUnreadCount // (#cm-110.1)
            )) // (#cm-110.1)
        } // (#cm-110.1)

        backgroundView.layer?.cornerRadius = 4 // (#cm-110.1)
        if kind.isSection { // (#cm-110.4)
            // No band: a hairline above the name. (#cm-110.1)
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor // (#cm-110.1)
            hairlineView.isHidden = false // (#cm-110.1)
            hairlineView.layer?.backgroundColor = colorResolver.resolvedColor(.separatorColor, for: colorScheme).cgColor // (#cm-110.1)
        } else { // (#cm-110.1)
            hairlineView.isHidden = true // (#cm-110.1)
            backgroundView.layer?.backgroundColor = headerPalette.bandColor // (#cm-110.1)
                .withAlphaComponent(headerPalette.bandOpacity).cgColor // (#cm-110.1)
        } // (#cm-110.1)

        let accent = cmuxAccentNSColor(for: colorScheme) // (#cm-110.1)
        topDropIndicator.layer?.backgroundColor = accent.cgColor // (#cm-110.1)
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor // (#cm-110.1)
        topDropIndicator.isHidden = !model.topDropIndicatorVisible // (#cm-110.1)
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible // (#cm-110.1)
        hintPill.isHidden = true // (#cm-110.1)
        alphaValue = model.isBeingDragged ? 0.6 : 1 // (#cm-110.1)
        updatePlusVisibility() // (#cm-110.1)

        switch kind { // (#cm-110.1)
        case .statusesArea: // (#cm-110.1)
            setAccessibilityIdentifier("sidebarStatusesArea") // (#cm-110.1)
            setAccessibilityLabel(SidebarStatusHeaderText.statusesAreaLabel(groupCount: model.memberCount, isCollapsed: model.isCollapsed)) // (#cm-110.1)
        case .workspacesArea: // (#cm-110.4)
            setAccessibilityIdentifier("sidebarWorkspacesArea") // (#cm-110.4)
            setAccessibilityLabel(SidebarStatusHeaderText.workspacesAreaLabel(isCollapsed: model.isCollapsed)) // (#cm-110.4)
        case .pinnedArea: // (#cm-110.5)
            setAccessibilityIdentifier("sidebarPinnedArea") // (#cm-110.5)
            setAccessibilityLabel(SidebarStatusHeaderText.pinnedAreaLabel(isCollapsed: model.isCollapsed)) // (#cm-110.5)
        case .statusGroup(let statusId): // (#cm-110.1)
            setAccessibilityIdentifier("sidebarStatusGroup.\(statusId)") // (#cm-110.1)
            setAccessibilityLabel(SidebarStatusHeaderText.statusGroupLabel(name: model.name, memberCount: model.memberCount, isCollapsed: model.isCollapsed)) // (#cm-110.1)
        } // (#cm-110.1)
        // A button whose label says its state. A workspace group's disclosure level, value and help do not apply. (#cm-110.1)
        setAccessibilityRole(.button) // (#cm-110.1)
        setAccessibilityValue(nil) // (#cm-110.1)
        setAccessibilityHelp(nil) // (#cm-110.1)
    } // (#cm-110.1)
} // (#cm-110.1)
