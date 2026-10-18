// cmux-rbf #cm-73.16
import AppKit
import SwiftUI

/// The pair header's native exit button, whose host owns leaving the mode.
struct PairHeaderExitButton: NSViewRepresentable {
    let tooltip: String
    let appearance: BonsplitConfiguration.Appearance
    let iconScale: CGFloat
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.identifier = NSUserInterfaceItemIdentifier("paneTabBarControl.pairExit")
        button.setAccessibilityIdentifier("paneTabBarControl.pairExit")
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        apply(to: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onExit = onExit
        apply(to: button)
    }

    private func apply(to button: NSButton) {
        button.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12 * iconScale, weight: .regular))
        button.contentTintColor = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    @MainActor final class Coordinator: NSObject {
        var onExit: () -> Void
        init(onExit: @escaping () -> Void) { self.onExit = onExit }
        @objc func press() { onExit() }
    }
}
