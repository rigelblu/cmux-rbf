import AppKit
import SwiftUI

/// A quiet background-work mark that occupies the same slot as the activity spinner. (#cm-128.3)
struct SidebarWorkspaceMonitoringWaveform: View {
    // Shared bold weight for legibility in both sidebar renderers. (#cm-128.3)
    static let symbolWeight: NSFont.Weight = .bold
    let side: CGFloat
    let color: NSColor

    var body: some View {
        Image(systemName: "waveform.path.ecg")
            .resizable()
            .scaledToFit()
            .font(Font(NSFont.systemFont(ofSize: side, weight: Self.symbolWeight)))
            .foregroundColor(Color(nsColor: color))
            .frame(width: side, height: side)
            .safeHelp(String(localized: "sidebar.agentMonitoring.tooltip", defaultValue: "Watching a background job"))
            .accessibilityLabel(String(localized: "sidebar.agentMonitoring.tooltip", defaultValue: "Watching a background job"))
    }
}
