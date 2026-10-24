// cmux-rbf (#cm-73.32)
import Foundation

/// The motion state of the Design Focus Figma preview pane.
public enum PairFigmaMotionState: Sendable, Equatable {
    /// Hidden: not a preview of a design file with a motion mark.
    case hidden
    /// Still: preview with a motion mark, currently showing the still read view.
    case still
    /// Playing: preview with a motion mark, currently playing prototype motion.
    case playing
}
