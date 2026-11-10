import AppKit
import SwiftUI

/// A quiet background-work mark that occupies the same slot as the activity spinner. (#cm-128.3)
/// cm-128.6: it draws from the same symbol configuration as the AppKit mark (`NSImage.SymbolConfiguration(pointSize:weight:)`),
/// so both renderers show one bold waveform, and it carries no tooltip of its own: the call site sets the builder's lines.
struct SidebarWorkspaceMonitoringWaveform: View {
    // Shared bold weight for legibility in both sidebar renderers. (#cm-128.3)
    static let symbolWeight: NSFont.Weight = .bold
    let side: CGFloat
    let color: NSColor

    var body: some View {
        Image(nsImage: Self.image(pointSize: side))
            .resizable()
            .scaledToFit()
            .foregroundColor(Color(nsColor: color))
            .frame(width: side, height: side)
    }

    /// The AppKit mark's image: the symbol at `pointSize` and the shared weight, as a template so the colour tints it.
    static func image(pointSize: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil) ?? NSImage()
        let configured = symbol.withSymbolConfiguration(.init(pointSize: pointSize, weight: symbolWeight)) ?? symbol
        configured.isTemplate = true
        return configured
    }
}
