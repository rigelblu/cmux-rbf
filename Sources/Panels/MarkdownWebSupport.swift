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
    /// Handles a plain Escape while this view owns the keyboard, returning
    /// whether it consumed the key.
    ///
    /// **Opt-in per mount, and that is the point.** `MarkdownWebRenderer` has
    /// two mounts — the Reply panel and the markdown panel — and both get this
    /// same class. Only Reply wants Escape to mean *give the keyboard back*,
    /// so the markdown panel leaves this `nil` and keeps AppKit's behaviour
    /// untouched. An unconditional `keyCode == 53` arm here would change both.
    ///
    /// Reply needs it because `cm-69.1b` made this view the sidebar's focus
    /// owner, which stopped `repairFocusedTerminalKeyboardRoutingIfNeeded`
    /// firing for Reply — and that repair was the only route out of the panel.
    var onEscape: ((NSWindow) -> Bool)?

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
        if handleEscapeHandoff(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Gives the keyboard back on a plain Escape, when a mount asked for it.
    ///
    /// Deliberately *not* gated on `editableFocusStateConfirmed` the way
    /// ``handleViewerNavigationKey`` is. That flag only turns true once the
    /// injected script posts its first message, so gating on it would leave
    /// Escape silently dead on a page that has not finished loading — the
    /// exact failure this arm exists to remove.
    private func handleEscapeHandoff(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, let onEscape else { return false }
        // Plain Escape only. `⌥⎋` and friends belong to whoever binds them;
        // caps lock and the function/numeric-pad bits ride along on stray
        // hardware and are not a chord.
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard modifiers.isEmpty else { return false }
        // Same ownership question the viewer-navigation path asks: is this
        // view, or something inside it, first responder in this window.
        guard cmuxOwnsKeyEvent(event), let window else { return false }
        return onEscape(window)
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
    /// The user's own system accent, for a mark the page paints on purpose.
    ///
    /// **Why a new role rather than a shade of an existing one.** Every
    /// colour above is `background` overlaid with black or white at a
    /// contrast target, so they are all one hue — greys. The Reply panel's
    /// annotation needs two *hues*: a wash saying "marked" and a hover in a
    /// genuinely different colour, which a second grey cannot express.
    ///
    /// **What it costs, accepted:** this follows macOS rather than Ghostty,
    /// so in a warm-cream terminal theme the mark is still the system
    /// accent. The page's *ground* keeps following Ghostty through
    /// `resolve(backgroundColor:)` — only the mark is system-coloured.
    let accent: String

    /// The hovered mark's wash — a genuinely different **hue** from the
    /// resting one, not a stronger tint of it.
    ///
    /// **Why a second hue at all:** hover is transient, so a second hue
    /// cannot harden into a second category, and distinguishability was the
    /// actual requirement (settled 2026-09-04 from three rendered
    /// candidates). A darker version of the resting wash reads as *more
    /// marked*, which is a claim hover has no business making.
    ///
    /// **Where it comes from, since the design never said.** The accent
    /// Decision names a second hue as the reason the system accent beat
    /// derived greys, and then sources only the first. Rotating the user's
    /// own accent is the answer that needs no new palette: it is a different
    /// hue by construction, and it still belongs to the colour they chose.
    /// Ships as a raw violet only if the accent has no hue to rotate.
    let accentHover: String

    /// What sits legibly **on** the hovered mark.
    ///
    /// Same role `onAccent` plays for the accent, and it exists for the same
    /// reason: text inside a wash has to track the wash, not the page. Now
    /// that the fill is opaque there is no ground showing through to keep the
    /// body colour readable, so the mark owns its own text colour.
    let onAccentHover: String

    /// `onAccentHover` as a colour, for the footer row that names the same
    /// mark — bound from one value, exactly as `activeMarkColor` is.
    let onActiveMarkColor: NSColor

    /// `accentHover` as a colour, for native chrome that names the same mark.
    ///
    /// **Why both, from one expression.** A hovered note in the Reply footer
    /// and the hovered mark in the page are one object — the same
    /// `hoveredID` lights both — so they have to be one colour. The footer
    /// row shipped in a grey while the mark was violet, which read as two
    /// unrelated things reacting to one pointer (Tom, dogfood 2026-09-06:
    /// *"it's not using the same color as the background of the
    /// highlight"*).
    ///
    /// Deriving both fields from a single value is the point: a colour that
    /// exists twice drifts, and it drifts silently because neither copy is
    /// wrong on its own.
    ///
    /// Translucent on purpose, unlike `adjacentChromeColor`: this one is
    /// drawn **over** the footer's own opaque ground, so its alpha
    /// composites against a surface SwiftUI actually has.
    let activeMarkColor: NSColor

    /// What sits legibly **on** `accent`.
    ///
    /// Two fields rather than one because a numeral inside the wash must
    /// track the wash, not the page. The same defect shipped once already:
    /// a `Paste` label with a raw `#0e1116` that vanished the moment the
    /// surface under it changed.
    let onAccent: String

    /// The colour the web view itself should be backed by, or nil to stay
    /// transparent. Without this the CSS canvas would be painted over a
    /// transparent `WKWebView` and the terminal would still show through at the
    /// edges — the page would look solid while the panel was not.
    let canvasColor: NSColor?

    /// The page's own hairline, as an `NSColor`, for native chrome that has
    /// to draw one against it.
    ///
    /// **Flattened over the canvas, like `adjacentChromeColor` and for the
    /// same reason** — `markdownThemeOverlay` returns a translucent colour.
    ///
    /// The Reply panel's message/footer rule used SwiftUI's `Divider()`,
    /// which paints the *system* separator: a sidebar colour, drawn against a
    /// page that follows Ghostty, and markedly darker than anything the page
    /// draws itself (Tom, dogfood 2026-09-06: *"too dark of a gray … can we
    /// do a lighter gray?"*).
    ///
    /// Worth knowing: the design draws **no rule here at all**. `N10`'s
    /// `138:1475` is a 1pt frame named `flex` with no fill — a spacer. The
    /// boundary it intends is the tone step `adjacentChromeColor` already
    /// makes, so this hairline is a softer version of a line the frames do
    /// not ask for.
    let hairlineColor: NSColor?

    /// Chrome sitting directly against the reading surface, as an `NSColor`.
    ///
    /// Same derivation as `mutedBackground`, which is already this role in
    /// CSS — a small step off the page's own ground. Native chrome next to
    /// the page needs it as a colour rather than a string.
    ///
    /// **Why it has to come from here.** The Reply panel's footer sits
    /// directly under a page that follows Ghostty. Left unpainted it shows
    /// the sidebar's own chrome instead, so the two sides of one edge are
    /// drawn from two different palettes and the step between them is
    /// whatever those two happen to be. Nobody chose it, and it reads
    /// exactly that way.
    let adjacentChromeColor: NSColor?

    /// The focused mark's fill — `#6A1B9A`, opaque, the same on both canvases.
    ///
    /// **Chosen by Tom on 2026-09-06/07 after ten candidates were tried live**
    /// — Rosé Pine Dawn's seven accents, iris's dark variant, and two light
    /// lavenders. The decision that actually settled it was not a hue but a
    /// *shape*: a focused mark can **tint** the agent's words (a pale fill
    /// with dark text, the words stay primary) or **block** them (a strong
    /// fill with white text, the mark dominates). Everything tried was a
    /// variation inside one of those two. Tom took the block.
    ///
    /// **Why there is no alpha.** The mark used to be
    /// `NSColor.controlAccentColor` weakened with alpha, and that was never a
    /// choice about how a highlight should look. `controlAccentColor` is a
    /// *foreground* colour — what macOS fills buttons with, built to carry
    /// white text — so painting it behind the agent's dark body text needed
    /// it weakened or the text was unreadable. The alpha manufactured a
    /// background out of a colour that was not one, and it is what made every
    /// candidate arrive pale: `#6A1B9A` reached the screen as `#D7C0E4`.
    /// Choosing the hue directly removes the constraint, and the page always
    /// has an opaque canvas under the mark (`pageTheme` resolves `.solid`).
    /// Nothing else needed the translucency — overlapping marks are refused
    /// at the model level, and a code span inside a mark paints over its
    /// parent regardless.
    ///
    /// **One hex for both appearances, and it is the only candidate that
    /// managed it.** Every Rosé Pine hue needed a separate dark partner,
    /// because Dawn is a *light-theme* palette: at full opacity six of its
    /// seven clear AA against black text and only one clears it against
    /// white. This fill is dark enough that its own ink (white, chosen by
    /// `hoveredMarkInk` from the fill's luminance) clears AA on either canvas
    /// at **9.4:1**, against Pine's 6.1.
    ///
    /// **Not the highest-contrast candidate, and that was the point.**
    /// `#283593` scored 10.4:1 and was rejected: indigo sits beside the blue
    /// the *resting* mark already uses, so focused-vs-resting became one hue
    /// at two depths. Separating those two is the only job this colour has
    /// left since the outline was deleted, so a hue that also shifts beats a
    /// hue that only darkens.
    static func hoveredMarkFill(isDark: Bool) -> NSColor {
        _ = isDark
        return NSColor(srgbRed: 0x6a / 255, green: 0x1b / 255, blue: 0x9a / 255, alpha: 1)
    }

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
        // Converted through sRGB before reading components: the system accent
        // is a catalog colour and has no components in its own space.
        let systemAccent = NSColor.controlAccentColor
            .usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        // Bound once so the CSS string and the `NSColor` cannot drift — see
        // `activeMarkColor`.
        let hoveredMark = MarkdownWebTheme.hoveredMarkFill(isDark: isDark)
        // Near-black rather than pure black, matching `onAccent`'s own pair.
        let hoveredMarkInk: NSColor = hoveredMark.isLightColor
            ? NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
            : .white
        return MarkdownWebTheme(
            isDark: isDark,
            background: style == .solid ? base.markdownCSSColor : "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor,
            accent: systemAccent.markdownCSSColor,
            accentHover: hoveredMark.markdownCSSColor,
            // **Follows the fill, not the page.** Held fixed at white while
            // the hues were trialled, so only one variable moved — but a
            // light fill cannot carry white text (`#C4A7E7` gives 2.1:1),
            // and a dark one cannot carry black. Same rule `onAccent`
            // already applies for the same reason, one role up.
            onAccentHover: hoveredMarkInk.markdownCSSColor,
            onActiveMarkColor: hoveredMarkInk,
            activeMarkColor: hoveredMark,
            // White on every accent macOS ships except yellow, where it goes
            // near-black. Chosen by the accent's own luminance rather than by
            // the page's: this label sits on the accent, not on the page.
            onAccent: systemAccent.isLightColor
                ? NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).markdownCSSColor
                : NSColor.white.markdownCSSColor,
            canvasColor: style == .solid ? base : nil,
            // Flattened over the canvas, not the raw overlay.
            // `markdownThemeOverlay` returns a *translucent* colour, built to
            // be composited by CSS over the page's own background. Handed to
            // SwiftUI's `.background` it composites over whatever is behind
            // the panel instead — the sidebar's own chrome — so the footer
            // came out as the sidebar's colour with a wash on top. That is
            // precisely the defect this field exists to prevent, reintroduced
            // by shipping the overlay rather than its result (Tom, dogfood
            // 2026-09-06: *"it's still in like a washed out purple violet"*).
            hairlineColor: style == .solid
                ? (base.blended(withFraction: border.alphaComponent * 0.70, of: border) ?? base)
                    .withAlphaComponent(1)
                : nil,
            //
            // `.withAlphaComponent(1)` is not decoration: `blended` carries
            // the overlay's own alpha into its result, so this came out at
            // ~0.94 and the sidebar still showed faintly through the footer.
            // A weaker version of the same defect, surviving inside its own
            // fix — found by the hairline's test, which asked the question
            // this one never did.
            adjacentChromeColor: style == .solid
                ? (base.blended(withFraction: muted.alphaComponent, of: muted) ?? base)
                    .withAlphaComponent(1)
                : nil
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

/// A selection the rendered page reported: what the user marked, and where it
/// sits.
///
/// **Two coordinate systems on purpose.** `quote` is the selection's
/// **markdown** — `markdownOf(range)`, the source behind what the user saw,
/// which is what the agent is sent. `range` counts characters across the
/// page's *rendered* text nodes. They never have to agree, and after the
/// 2026-09-06 move to markdown they routinely do not: the quote is the
/// payload, and the range only has to order marks and answer whether two of
/// them share a character.
struct MarkdownPageSelection: Equatable {
    let quote: String
    let range: Range<Int>
}

/// One mark for the page to paint.
///
/// Encoded straight to JSON for the page script, so the field names here are
/// the contract with it.
struct MarkdownPageMark: Codable, Equatable {
    /// Matches the annotation's own id, so hover can name one mark.
    let id: String
    let start: Int
    let end: Int
    /// The position the numeral prints — derived from document order every
    /// time, never stored on the annotation.
    let number: Int

    // **There is deliberately no `state` here.** Marks used to carry
    // `writing`/`committed`, drawn as an outline and an underline — a second
    // channel on top of the wash. Both are gone by Tom's call (2026-09-06:
    // *"remove the underline and the outline on both our Figma designs and
    // our code. We only use the different tone for the current one being
    // edited"*).
    //
    // The tone is `data-cmux-active`, which the page already had for hover,
    // so the distinction now costs no new mechanism — and a mark never grows
    // a border, which is what made every unwritten span read as an error.
}

extension NSColor {
    }
