import CoreGraphics

/// How far a row is drawn in, by its level (#cm-106). One step is the member indent a row already has, 12 pt.
/// The drawn indent never takes more than 40% of the sidebar's width: a row deeper than that is drawn at the
/// same indent as the deepest level that fits. One level always fits, so a flat window draws what it draws today.
enum SidebarNestedIndent {
    /// The share of the sidebar's width the indent may take (a first number, which can be tuned).
    static let maxShareOfWidth: CGFloat = 0.4
    /// The width the SwiftUI list assumes, which cannot read its own width below the lazy boundary: the default 240 pt.
    static let assumedWidth: CGFloat = 240

    static func points(levels: Int, availableWidth: CGFloat?) -> CGFloat {
        guard levels > 0 else { return 0 }
        let step = SidebarWorkspaceGroupingMetrics.memberIndent
        // A width that is missing, not finite or not positive is the default width.
        let width = availableWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? assumedWidth
        let fittingLevels = max(1, Int((width * maxShareOfWidth) / step))
        return CGFloat(min(levels, fittingLevels)) * step
    }
}
