import AppKit

/// The Reply toolbar over a selection in an agent's pane (`cm-136.1`): a pill
/// holding one button.
///
/// **It never takes the keyboard (Q2, Tom 2026-11-05).** The view refuses
/// first responder and its clicks never call `makeFirstResponder`, so the
/// terminal still owns the keys after Reply and the next letter typed starts
/// the answer. It is plain AppKit rather than a SwiftUI button in an
/// `NSHostingView`: a SwiftUI control may claim focus on click, and this one
/// must not.
///
/// A mouse-down on the pill reaches this view, not the terminal under it, so
/// pressing Reply never starts a selection. The press follows a native
/// button: the pressed look holds until mouse-up, and releasing outside the
/// pill cancels.
final class ReplyInlineToolbarView: NSView {
    /// Called once per completed click.
    var onReply: (() -> Void)?
    /// Called when the view leaves its window: the pane closed or was detached.
    var onDetach: (() -> Void)?

    private let title: String
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let horizontalPadding: CGFloat = 16

    /// The toolbar's size for a label: at least the fixed 28 pt pill, wide
    /// enough for the translated word. It never follows the pane or the
    /// terminal's font size (Q3).
    static func size(for title: String) -> CGSize {
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(
            width: max(ReplyInlinePlacement.toolbarSize.width, text + 2 * horizontalPadding),
            height: ReplyInlinePlacement.toolbarSize.height
        )
    }

    init(title: String, accessibilityLabel: String) {
        self.title = title
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: title)))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityTitle(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Keyboard stays in the terminal

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Drawing

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: bounds.height / 2,
            cornerHeight: bounds.height / 2,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        var fill = NSColor.controlAccentColor
        if isPressed {
            fill = fill.blended(withFraction: 0.30, of: .black) ?? fill
        } else if isHovered {
            fill = fill.blended(withFraction: 0.15, of: .black) ?? fill
        }
        fill.setFill()
        pill.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.alternateSelectedControlTextColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != isPressed else { return }
        isPressed = inside
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let completed = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if completed { onReply?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onReply?()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }
}
