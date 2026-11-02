import AppKit
import Foundation

// cmux-rbf #cm-126.3: the Agent Pane, a browser pane one agent's terminal owns.

/// The Agent Pane's rules, all over plain values so each tests without the app.
///
/// An Agent Pane is a browser pane with an owner (the terminal's
/// `stableSurfaceId`, `cm-73.45`'s field) and the kind ``BrowserOwnedKind/agentPane``.
/// It is recognized by those two stored values, never by its address: the mark,
/// keep-loaded, the lookup and the placement rule all read them, so no page the
/// agent or a click loads turns an Agent Pane into a plain pane, or the other way.
enum AgentPaneMark {

    /// One browser pane, as the rules read it.
    struct Candidate: Equatable {
        let panelID: UUID
        let owner: UUID?
        let kind: BrowserOwnedKind?
    }

    /// What `show` does for a caller: open an Agent Pane beside its terminal, or
    /// steer the first one it already owns.
    enum Placement: Equatable {
        case open
        /// `others`: how many more panes that terminal owns in the workspace.
        case navigate(UUID, others: Int)
    }

    /// An Agent Pane has an owner and the Agent Pane kind. A Figma pane `cm-73.45` gave
    /// an owner has no kind, so it is never one.
    static func isAgentPaneKind(owner: UUID?, kind: BrowserOwnedKind?) -> Bool {
        owner != nil && kind == .agentPane
    }

    /// The panes `owner` owns among `candidates`, in the order given.
    static func panes(ownedBy owner: UUID, among candidates: [Candidate]) -> [UUID] {
        candidates
            .filter { isAgentPaneKind(owner: $0.owner, kind: $0.kind) && $0.owner == owner }
            .map(\.panelID)
    }

    /// None → open one; otherwise steer the first and count the rest.
    /// Additional owned panes are reported, never closed.
    static func placement(panes: [UUID]) -> Placement {
        guard let first = panes.first else { return .open }
        return .navigate(first, others: panes.count - 1)
    }

    /// Whether a pane holding these tabs holds an Agent Pane, so a tab that would
    /// land there splits instead.
    static func paneHoldsAgentPane(_ tabs: [Candidate]) -> Bool {
        tabs.contains { isAgentPaneKind(owner: $0.owner, kind: $0.kind) }
    }

    /// The picture a tab is handed: the mark for an Agent Pane, whatever the page's
    /// own icon, so a page can't make an Agent Pane look like Tom's own tab; else
    /// `own`.
    static func picture(isAgentPaneKind: Bool, own: Data?) -> Data? {
        isAgentPaneKind ? shippedPicture : own
    }

    /// A page cannot replace the Agent Pane's caption with its own title.
    static func title(isAgentPaneKind: Bool, own: String) -> String {
        isAgentPaneKind ? String(localized: "agentPane.tab.title", defaultValue: "Agent Pane") : own
    }

    /// The SF Symbol `eyeglasses` drawn once as a 32 by 32 pixel PNG, the size
    /// ``FigmaTabMark/shippedPicture`` hands the tab, in a mid grey that reads on
    /// a light and a dark tab bar (the tab draws the picture as it is, untinted).
    static let shippedPicture: Data = {
        let side = 32
        guard let symbol = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [markColor]))
                ),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: side,
                  pixelsHigh: side,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return Data() }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let size = symbol.size
        let scale = min(CGFloat(side) / size.width, CGFloat(side) / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        symbol.draw(
            in: NSRect(
                x: (CGFloat(side) - drawn.width) / 2,
                y: (CGFloat(side) - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            )
        )
        NSGraphicsContext.current?.flushGraphics()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }()

    private static let markColor = NSColor(srgbRed: 0.48, green: 0.48, blue: 0.53, alpha: 1)

    /// Why the app refuses a page before anything changes, or `nil`: a scheme
    /// other than `file`, `https` or `http`, or a page ``FigmaTabMark`` would
    /// count as a Figma pane's (Figma's editor, or cmux's read view). The CLI
    /// refuses the same first (`AgentPaneCLIRules`); this is the app's own check.
    static func refusal(for address: URL) -> AddressRefusal? {
        guard let scheme = address.scheme?.lowercased(), ["file", "https", "http"].contains(scheme) else {
            return .badScheme
        }
        if FigmaPaneURL.isWrapperPage(address) || FigmaFileLink.isEditorPage(address) {
            return .figmaAddress
        }
        return nil
    }

    enum AddressRefusal: Equatable {
        case badScheme
        case figmaAddress
    }
}
