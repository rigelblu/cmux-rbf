import AppKit
import SwiftUI

/// Plain one-surface identity shown in the pane header.
///
/// This intentionally does not reuse `TabItemView`: the caption has no selected
/// fill, tab boundary, tab position, or button/selected accessibility traits.
struct SurfaceCaptionView: View {
    let tab: TabItem
    let showsZoomIndicator: Bool
    let appearance: BonsplitConfiguration.Appearance
    let chrome: SurfaceCaptionChrome
    let saturation: Double
    let allowsClose: Bool
    let allowsContextMenu: Bool
    let contextMenuState: TabContextMenuState
    let moveDestinationsProvider: () -> [TabContextMoveDestination]
    let forkConversationAvailabilityProvider: () -> TabContextForkConversationAvailability
    let onFocus: () -> Void
    let onClose: (TabCloseRequestSource) -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (TabContextAction) -> Void
    let onMoveDestination: (String) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false
    @State private var isAudioHovered = false
    @State private var showGlobeFallback = true
    @State private var globeFallbackWorkItem: DispatchWorkItem?
    @State private var lastIsLoadingObserved = false
    @State private var lastLoadingStoppedAt: Date?
    @State private var renderedFaviconData: Data?
    @State private var renderedFaviconImage: NSImage?
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    var body: some View {
        content
            .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
            .frame(
                minWidth: TabItemStyling.tabWidthRange(for: appearance).lowerBound,
                maxWidth: TabItemStyling.tabWidthRange(for: appearance).upperBound,
                minHeight: captionHeight,
                maxHeight: captionHeight,
                alignment: .leading
            )
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle().inset(by: -BonsplitTabItemHitTesting.horizontalSlop))
            .background(MiddleClickMonitorView(onMiddleClick: {
                guard allowsClose, !tab.isPinned else { return }
                onClose(.middleClick)
            }))
            .background {
                if allowsContextMenu {
                    TabContextMenuPresenter(
                        snapshot: TabContextMenuSnapshot(
                            tabId: tab.id,
                            state: contextMenuState,
                            moveDestinationsProvider: moveDestinationsProvider,
                            forkConversationAvailabilityProvider: forkConversationAvailabilityProvider
                        ),
                        onContextAction: onContextAction,
                        onMoveDestination: onMoveDestination
                    )
                }
            }
            .onTapGesture {
                onFocus()
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onZoomToggle()
                }
            )
            .onHover { hovering in
                withTransaction(Transaction(animation: nil)) {
                    isHovered = hovering
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tab.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("paneSurfaceCaption")
            .accessibilityFocused($isAccessibilityFocused)
            // The caption deliberately exposes no button trait, so its tap and
            // double-tap have no accessibility equivalent. Named actions give
            // VoiceOver the same two operations without claiming the tab
            // semantics the caption exists to avoid.
            .accessibilityAction(
                named: Text(localized("surfaceCaption.action.focusPane", defaultValue: "Focus Pane"))
            ) {
                onFocus()
            }
            .accessibilityAction(
                named: Text(localized("surfaceCaption.action.toggleZoom", defaultValue: "Toggle Zoom"))
            ) {
                onZoomToggle()
            }
            .safeHelp(tab.title)
    }

    private var content: some View {
        HStack(spacing: 0) {
            HStack(spacing: scaledContentSpacing) {
                leadingIcon

                Text(tab.title)
                    .font(.system(size: appearance.tabTitleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(chrome.activeTextColor)
                    .saturation(saturation)

                if tab.showsRemoteIndicator {
                    Image(systemName: "network")
                        .font(.system(size: accessoryFontSize, weight: .semibold))
                        .foregroundStyle(
                            chrome.activeTextColor.opacity(0.78)
                        )
                        .saturation(saturation)
                        .accessibilityHidden(true)
                }

                if tab.isAudioMuted || tab.isAudioPlaying {
                    audioButton
                }

                if showsZoomIndicator {
                    zoomButton
                }
            }

            Color.clear.frame(width: scaledContentSpacing)
            trailingAccessory
        }
    }

    private var audioButton: some View {
        let isMuted = tab.isAudioMuted
        let label = Bundle.module.localizedString(
            forKey: isMuted ? "tabContext.unmuteTab" : "tabContext.muteTab",
            value: isMuted ? "Unmute Tab" : "Mute Tab",
            table: nil
        )

        return Button {
            onContextAction(.toggleAudioMute)
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: accessoryFontSize, weight: .semibold))
                .foregroundStyle(
                    isAudioHovered
                        ? chrome.activeTextColor
                        : chrome.activeTextColor.opacity(0.78)
                )
                .frame(width: accessorySlotSize, height: accessorySlotSize)
                .background(
                    Circle().fill(
                        isAudioHovered
                            ? chrome.hoveredBackgroundColor
                            : .clear
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withTransaction(Transaction(animation: nil)) {
                isAudioHovered = hovering
            }
        }
        .saturation(saturation)
        .safeHelp(label)
        .accessibilityLabel(label)
        .tabBarButtonAnimationsDisabled()
    }

    private var zoomButton: some View {
        let label = Bundle.module.localizedString(
            forKey: "tabContext.exitZoom",
            value: "Exit Zoom",
            table: nil
        )

        return Button {
            onZoomToggle()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: accessoryFontSize, weight: .semibold))
                .foregroundStyle(
                    isZoomHovered
                        ? chrome.activeTextColor
                        : chrome.inactiveTextColor
                )
                .frame(width: accessorySlotSize, height: accessorySlotSize)
                .background(
                    Circle().fill(
                        isZoomHovered
                            ? chrome.hoveredBackgroundColor
                            : .clear
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withTransaction(Transaction(animation: nil)) {
                isZoomHovered = hovering
            }
        }
        .saturation(saturation)
        .safeHelp(label)
        .accessibilityLabel(label)
        .tabBarButtonAnimationsDisabled()
    }

    @ViewBuilder
    private var leadingIcon: some View {
        let iconTintColor = NSColor(chrome.activeTextColor)
        let iconTint = Color(nsColor: iconTintColor)
        let faviconImage = renderedFaviconImage ?? tab.iconImageData.flatMap { NSImage(data: $0) }

        Group {
            if tab.isLoading {
                TabLoadingSpinner(size: scaledIconSize * 0.86, color: iconTintColor)
            } else if let image = faviconImage {
                FaviconIconView(image: image)
                    .frame(width: scaledIconSize, height: scaledIconSize, alignment: .center)
                    .clipped()
            } else if let iconAsset = tab.iconAsset {
                Image(iconAsset, bundle: .main)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compactMarkSize, height: compactMarkSize, alignment: .center)
            } else if let iconName = tab.icon {
                if iconName == "globe", !showGlobeFallback {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(iconTint.opacity(0.25), lineWidth: 1)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: glyphSize(for: iconName)))
                        .foregroundStyle(iconTint)
                }
            }
        }
        .saturation(
            TabItemStyling.iconSaturation(
                hasRasterIcon: faviconImage != nil,
                tabSaturation: saturation
            )
        )
        .transaction { transaction in
            transaction.animation = nil
        }
        .frame(width: scaledIconSize, height: scaledIconSize, alignment: .center)
        .onAppear {
            updateRenderedFaviconImage()
            updateGlobeFallback()
        }
        .onDisappear {
            globeFallbackWorkItem?.cancel()
            globeFallbackWorkItem = nil
        }
        .onChange(of: tab.isLoading) { _, _ in updateGlobeFallback() }
        .onChange(of: tab.iconImageData) { _, _ in
            updateRenderedFaviconImage()
            updateGlobeFallback()
        }
        .onChange(of: tab.icon) { _, _ in updateGlobeFallback() }
    }

    private var trailingAccessory: some View {
        ZStack {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: scaledCloseIconSize, weight: .semibold))
                    .foregroundStyle(chrome.inactiveTextColor)
                    .saturation(saturation)
            } else if allowsClose && (isHovered || isCloseHovered || isAccessibilityFocused) {
                closeButton
            } else {
                statusMarks
            }
        }
        .frame(width: accessorySlotSize, height: accessorySlotSize)
        .tabBarButtonAnimationsDisabled()
    }

    private var closeButton: some View {
        let label = Bundle.module.localizedString(
            forKey: "surfaceCaption.close",
            value: "Close Surface",
            table: nil
        )

        return Button {
            onClose(.closeButton)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: scaledCloseIconSize, weight: .semibold))
                .foregroundStyle(
                    isCloseHovered
                        ? chrome.activeTextColor
                        : chrome.inactiveTextColor
                )
                .frame(width: accessorySlotSize, height: accessorySlotSize)
                .background(
                    Circle().fill(
                        isCloseHovered
                            ? chrome.hoveredBackgroundColor
                            : .clear
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withTransaction(Transaction(animation: nil)) {
                isCloseHovered = hovering
            }
        }
        .saturation(saturation)
        .safeHelp(label)
        .accessibilityLabel(label)
    }

    private var statusMarks: some View {
        HStack(spacing: 2) {
            if tab.showsNotificationBadge {
                Circle()
                    .fill(TabBarColors.notificationBadge(for: appearance))
                    .frame(
                        width: TabBarMetrics.notificationBadgeSize,
                        height: TabBarMetrics.notificationBadgeSize
                    )
            }
            if tab.isDirty {
                Circle()
                    .fill(TabBarColors.dirtyIndicator(for: appearance))
                    .frame(
                        width: TabBarMetrics.dirtyIndicatorSize,
                        height: TabBarMetrics.dirtyIndicatorSize
                    )
                    .saturation(saturation)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if tab.isLoading {
            parts.append(localized("surfaceCaption.loading", defaultValue: "Loading"))
        }
        if tab.isPinned {
            parts.append(localized("surfaceCaption.pinned", defaultValue: "Pinned"))
        }
        if tab.showsNotificationBadge {
            parts.append(localized("surfaceCaption.unread", defaultValue: "Unread"))
        }
        if tab.isDirty {
            parts.append(localized("surfaceCaption.modified", defaultValue: "Modified"))
        }
        if tab.isAudioMuted {
            parts.append(localized("tabContext.audioMutedAccessibility", defaultValue: "Muted"))
        }
        if tab.showsRemoteIndicator {
            parts.append(
                localized(
                    "tabContext.remoteConnectedAccessibility",
                    defaultValue: "Connected over SSH"
                )
            )
        }
        if showsZoomIndicator {
            parts.append(localized("surfaceCaption.zoomed", defaultValue: "Zoomed"))
        }
        return parts.joined(separator: ", ")
    }

    private var captionHeight: CGFloat {
        max(1, appearance.tabBarHeight)
    }

    private var fontScale: CGFloat {
        max(0.1, appearance.tabTitleFontSize / TabBarMetrics.titleFontSize)
    }

    private var scaledIconSize: CGFloat {
        TabBarMetrics.iconSize * fontScale
    }

    private var scaledCloseIconSize: CGFloat {
        TabBarMetrics.closeIconSize * fontScale
    }

    private var compactMarkSize: CGFloat {
        max(10, TabBarMetrics.iconSize - 2.5) * fontScale
    }

    private var scaledContentSpacing: CGFloat {
        TabBarMetrics.contentSpacing * fontScale
    }

    private var accessoryFontSize: CGFloat {
        max(8, appearance.tabTitleFontSize - 2)
    }

    private var accessorySlotSize: CGFloat {
        min(captionHeight, max(TabBarMetrics.closeButtonSize, ceil(accessoryFontSize + 4)))
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return compactMarkSize
        }
        return scaledIconSize
    }

    private func updateGlobeFallback() {
        if lastIsLoadingObserved && !tab.isLoading {
            lastLoadingStoppedAt = Date()
        }
        lastIsLoadingObserved = tab.isLoading

        globeFallbackWorkItem?.cancel()
        globeFallbackWorkItem = nil

        let recentlyStoppedLoading: Bool = {
            guard let lastLoadingStoppedAt else { return false }
            return Date().timeIntervalSince(lastLoadingStoppedAt) < 1.5
        }()
        let shouldDelayGlobe = tab.icon == "globe"
            && tab.iconImageData == nil
            && !tab.isLoading
            && recentlyStoppedLoading
        if !shouldDelayGlobe {
            showGlobeFallback = true
            return
        }

        showGlobeFallback = false
        let work = DispatchWorkItem {
            showGlobeFallback = true
        }
        globeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func updateRenderedFaviconImage() {
        guard renderedFaviconData != tab.iconImageData
            || (renderedFaviconImage == nil && tab.iconImageData != nil) else {
            return
        }
        renderedFaviconData = tab.iconImageData
        renderedFaviconImage = TabItemStyling.resolvedFaviconImage(
            existing: renderedFaviconImage,
            incomingData: tab.iconImageData
        )
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        Bundle.module.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}
