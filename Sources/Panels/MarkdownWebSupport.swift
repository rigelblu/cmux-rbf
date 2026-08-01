import AppKit
import CmuxFoundation
import WebKit

@MainActor
final class WeakMarkdownScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class MarkdownWebView: WKWebView {
    var onPointerDown: (() -> Void)?
    /// Invoked when the view leaves its window (the detach half of a pane
    /// re-parent). Lets the renderer coordinator record whether the document
    /// was healthy at detach time so re-entry recovery can tell a detach
    /// artifact apart from an attached crash loop.
    var onLeaveWindow: (() -> Void)?
    /// Invoked when the view re-enters a window after being detached. Lets the
    /// renderer coordinator recover content WebKit dropped while the view was
    /// out of the window (e.g. a pane drag re-parented the hosting views).
    var onReenterWindow: (() -> Void)?

    private var needsRenderingReattach = false
    private var editableFocusStateConfirmed = false
    private var editableElementFocused = false
    private let viewerNavigationKeyRouter = ViewerNavigationKeyRouter(actions: [
        .diffViewerScrollDown, .diffViewerScrollUp,
        .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
        .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
        .diffViewerScrollToBottom, .diffViewerScrollToTop,
    ])

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        Self.installEditableFocusTracking(on: configuration.userContentController)
        super.init(frame: frame, configuration: configuration)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.installEditableFocusTracking(on: configuration.userContentController)
    }

    private static func installEditableFocusTracking(on controller: WKUserContentController) {
        let name = MarkdownEditableFocusMessageHandler.name
        controller.add(MarkdownEditableFocusMessageHandler.shared, name: name)
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
              const handler = window.webkit?.messageHandlers?.['\(name)'];
              if (!handler) return;
              const deepestActiveElement = () => {
                let element = document.activeElement;
                while (element?.shadowRoot?.activeElement) {
                  element = element.shadowRoot.activeElement;
                }
                return element;
              };
              const publish = () => {
                const element = deepestActiveElement();
                const editable = !!element?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable='false'])");
                handler.postMessage({ editable });
              };
              document.addEventListener('focusin', publish, true);
              document.addEventListener('focusout', () => queueMicrotask(publish), true);
              document.addEventListener('pointerdown', () => requestAnimationFrame(publish), true);
              document.addEventListener('DOMContentLoaded', publish, { once: true });
              publish();
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func markdownEditableFocusDidChange(_ editable: Bool) {
        editableFocusStateConfirmed = true
        editableElementFocused = editable
        if editable {
            viewerNavigationKeyRouter.reset()
        }
    }

    var isViewerNavigationEditableElementFocused: Bool {
        editableElementFocused
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        editableFocusStateConfirmed = false
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleViewerNavigationKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            editableFocusStateConfirmed = false
        }
        if handleViewerNavigationKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    func handleViewerNavigationKey(_ event: NSEvent) -> Bool {
        guard cmuxOwnsKeyEvent(event),
              editableFocusStateConfirmed,
              !editableElementFocused else {
            viewerNavigationKeyRouter.reset()
            return false
        }
        return viewerNavigationKeyRouter.handle(event, isAllowed: { action, event in
            AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
        }, perform: { [weak self] action in
            self?.performViewerNavigationAction(action)
        })
    }

    private func performViewerNavigationAction(_ action: KeyboardShortcutSettings.Action) {
        evaluateJavaScript("window.__cmuxPerformViewerNavigationAction?.('\(action.rawValue)')")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Leaving the window (the detach half of a pane re-parent). Drive
            // WebKit's in-window lifecycle out so the matching re-entry below
            // resumes rendering, mirroring the browser panel's recovery path.
            needsRenderingReattach = true
            callVoidSelectorIfAvailable("viewDidHide")
            callVoidSelectorIfAvailable("_exitInWindow")
            onLeaveWindow?()
        } else {
            reattachRenderingState()
            onReenterWindow?()
        }
    }

    /// Resume WebKit's rendering after the view re-enters a window. WebKit can
    /// suspend painting (or reclaim the WebContent process) while a WKWebView
    /// is detached during a pane drag, which previously left the Markdown
    /// viewer permanently blank. This nudges the in-window lifecycle back on
    /// and forces a layout/display pass so the live document repaints.
    private func reattachRenderingState() {
        guard needsRenderingReattach else { return }
        needsRenderingReattach = false
        callVoidSelectorIfAvailable("viewDidUnhide")
        callVoidSelectorIfAvailable("_enterInWindow")
        callVoidSelectorIfAvailable("_endDeferringViewInWindowChangesSync")
        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    /// Calls a private WKWebView lifecycle selector when present. Guarded by
    /// `responds(to:)` so it degrades to a no-op if the selector is removed.
    private func callVoidSelectorIfAvailable(_ rawSelector: String) {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

/// What the markdown viewer paints its page on.
///
/// The distinction is legibility, not decoration. Under ``terminal`` the page
/// canvas is transparent and the terminal's own background shows through, so no
/// colour the viewer draws has a knowable contrast ratio — it depends on a theme
/// this code cannot see, and the only oracle is a human looking at it. Under
/// ``solid`` the canvas is the one `github-markdown.css` was designed against,
/// so every ratio is fixed and checkable.
enum MarkdownBackgroundStyle: String, Equatable {
    case terminal
    case solid

    /// Unknown values fall back to `terminal`, the pre-existing behaviour: a
    /// typo in `cmux.json` must not repaint the panel.
    init(rawValueOrTerminal raw: String?) {
        self = MarkdownBackgroundStyle(rawValue: raw ?? "") ?? .terminal
    }

    /// The colour that must sit directly behind the rendered page.
    ///
    /// Extracted from `MarkdownPanelView` so the decision is testable. It is the
    /// whole content of the resize-flash fix: a relayout moves the container
    /// before the web view repaints, so whatever is behind the page shows for
    /// that moment and must not be a different colour from the page. Under
    /// `terminal` there is no canvas and the panel's own colour is correct.
    ///
    /// What this does NOT capture is *where* the view puts it — that is a
    /// SwiftUI view-tree property with no unit-test seam. Placement is verified
    /// by dogfood only; see the note in MarkdownBackgroundStyleTests.
    static func colourBehindPage(theme: MarkdownWebTheme, panelContent: NSColor) -> NSColor {
        theme.canvasColor ?? panelContent
    }

    /// The canvas `github-markdown.css` pairs with each appearance.
    static func solidCanvas(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 0x0D / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}

struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String
    /// The colour the web view itself should be backed by, or nil to stay
    /// transparent. Without this the CSS canvas would be painted over a
    /// transparent `WKWebView` and the terminal would still show through at the
    /// edges — the page would look solid while the panel was not.
    let canvasColor: NSColor?

    static func resolve(
        backgroundColor: NSColor,
        style: MarkdownBackgroundStyle = .terminal
    ) -> MarkdownWebTheme {
        let terminalBase = backgroundColor.markdownOpaqueSRGB
        // Appearance still follows the terminal even in `solid`: the choice is
        // which canvas to paint, not whether the user is in light or dark mode.
        let isDark = !terminalBase.isLightColor
        let base = style == .solid
            ? MarkdownBackgroundStyle.solidCanvas(isDark: isDark)
            : terminalBase
        let overlayColor: NSColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlayColor
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlayColor
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlayColor
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: style == .solid ? base.markdownCSSColor : "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor,
            canvasColor: style == .solid ? base : nil
        )
    }
}

/// Panel-owned renderer session for a markdown preview.
///
/// SwiftUI may recreate `MarkdownWebRenderer` wrappers during split/tab layout
/// updates. The session keeps the WebKit coordinator identity tied to the
/// logical `MarkdownPanel` instead of the transient representable instance.
@MainActor
final class MarkdownRendererSession {
    private let ownedCoordinator = MarkdownWebRenderer.Coordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String
    ) -> MarkdownWebRenderer.Coordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    func renderedHTML(markdown: String? = nil) async -> String? {
        await ownedCoordinator.renderedHTML(markdown: markdown)
    }

    func renderedText() async -> String? {
        await ownedCoordinator.renderedText()
    }
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
