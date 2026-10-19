import Bonsplit

/// The result of placing a browser beside or below a source surface.
@MainActor
struct BrowserSplitPlacement {
    let panel: BrowserPanel
    let createdSplit: Bool
    let orientation: BoardLayoutOrientation?
    let splitDirection: SplitOrientation?

    init(panel: BrowserPanel, createdSplit: Bool, orientation: BoardLayoutOrientation? = nil, splitDirection: SplitOrientation? = nil) {
        self.panel = panel
        self.createdSplit = createdSplit
        self.orientation = orientation
        self.splitDirection = splitDirection
    }
}
