import AppKit

/// The Reply toolbar over a selection in an agent's pane (`cm-136.1`, `cm-136.8`):
/// a rounded rectangle holding one button.
///
/// **It never takes the keyboard (Q2, Tom 2026-11-05).** The view refuses
/// first responder and its clicks never call `makeFirstResponder`, so the
/// terminal still owns the keys after Reply and the next letter typed starts
/// the answer. It is plain AppKit rather than a SwiftUI button in an
/// `NSHostingView`: a SwiftUI control may claim focus on click, and this one
/// must not.
///
/// A mouse-down on the toolbar reaches this view, not the terminal under it, so
/// pressing Reply never starts a selection. The press follows a native
/// button: the pressed look holds until mouse-up, and releasing outside the
/// toolbar cancels.
final class ReplyInlineToolbarView: NSView {
    /// Called once per completed click.
    var onReply: (() -> Void)?
    /// Called when the view leaves its window: the pane closed or was detached.
    var onDetach: (() -> Void)?

    private let title: String
    var state: ReplyInlineToolbarStyle.State = .rest
    private var trackingArea: NSTrackingArea?
    private var isObservingContrast = false

    static let font = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let horizontalPadding: CGFloat = 14

    /// The toolbar's size for a label: at least `ReplyInlinePlacement.toolbarSize`
    /// (62×28 pt), widening with `2 * horizontalPadding` when the translated
    /// word needs more room (`max(toolbarSize.width, ceil(w) + 28)`).
    /// It never follows the pane or the terminal's font size (Q3).
    static func size(for title: String) -> CGSize {
        let labelWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(
            width: max(ReplyInlinePlacement.toolbarSize.width, labelWidth + 2 * horizontalPadding),
            height: ReplyInlinePlacement.toolbarSize.height
        )
    }

    init(title: String, accessibilityLabel: String) {
        self.title = title
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: title)))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
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

    // MARK: Appearance & Contrast

    private var currentAppearance: ReplyInlineToolbarStyle.Appearance {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func startObservingContrastIfNeeded() {
        guard !isObservingContrast else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        isObservingContrast = true
    }

    private func stopObservingContrast() {
        guard isObservingContrast else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        isObservingContrast = false
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        needsDisplay = true
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.lineWidth = 1.0

        let appearance = currentAppearance
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        let fill = ReplyInlineToolbarStyle.fillColor(for: appearance, state: state)
        fill.setFill()
        path.fill()

        let edge = ReplyInlineToolbarStyle.edgeColor(for: appearance, increaseContrast: increaseContrast)
        edge.setStroke()
        path.stroke()

        let labelColor = ReplyInlineToolbarStyle.labelColor(for: appearance)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: labelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(
                x: round(bounds.midX - size.width / 2),
                y: round(bounds.midY - size.height / 2)
            ),
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

    override func mouseEntered(with event: NSEvent) {
        state = .hover
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        state = .rest
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        state = .pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let newState: ReplyInlineToolbarStyle.State = inside ? .pressed : .rest
        if state != newState {
            state = newState
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let completed = state == .pressed && inside
        state = inside ? .hover : .rest
        needsDisplay = true
        if completed { onReply?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onReply?()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startObservingContrastIfNeeded()
        } else {
            stopObservingContrast()
            onDetach?()
        }
    }
}
