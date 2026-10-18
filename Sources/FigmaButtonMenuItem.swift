import AppKit

// cmux-rbf #cm-73.16: the menu retains each row's action for AppKit's tracking loop.
@MainActor
final class FigmaButtonMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { handler() }
}
