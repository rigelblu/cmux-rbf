import SwiftUI

/// Decides whether an arrow press on a color's reorder handle moves the color.
enum WorkspaceColorReorderKeyPolicy {
    /// Whether an arrow press is the bare stroke, with no chord held.
    ///
    /// An arrow key always arrives with the numeric-pad and function flags set,
    /// and caps lock can be on as well. None of those is somebody pressing a
    /// chord, so `modifiers.isEmpty` is never true for an arrow. Only Command,
    /// Control, Option and Shift count as modifiers here.
    static func isBareArrow(_ modifiers: EventModifiers) -> Bool {
        modifiers.isDisjoint(with: [.command, .control, .option, .shift])
    }
}
