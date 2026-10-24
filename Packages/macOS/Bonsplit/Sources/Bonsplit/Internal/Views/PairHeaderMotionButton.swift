// cmux-rbf (#cm-73.32)
import AppKit
import SwiftUI

/// The pair header's native motion button for Play / Still.
struct PairHeaderMotionButton: NSViewRepresentable {
    let symbolName: String
    let tooltip: String
    let isSelected: Bool
    let appearance: BonsplitConfiguration.Appearance
    let iconScale: CGFloat
    let onToggle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.identifier = NSUserInterfaceItemIdentifier("paneTabBarControl.figmaMotion")
        button.setAccessibilityIdentifier("paneTabBarControl.figmaMotion")
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        apply(to: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        apply(to: button)
    }

    private func apply(to button: NSButton) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12 * iconScale, weight: .regular))
        button.contentTintColor = isSelected
            ? NSColor.labelColor
            : TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    @MainActor final class Coordinator: NSObject {
        var onToggle: () -> Void
        init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }
        @objc func press() { onToggle() }
    }
}
