import Foundation

// cmux-rbf #cm-126.3: ownership installed before a split's tab is built.

/// The terminal's stable ownership key and the purpose of its browser pane.
struct BrowserPaneOwner {
    let terminalStableID: UUID
    let kind: BrowserOwnedKind
}
