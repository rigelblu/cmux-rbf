import Foundation

/// Immutable snapshot of the group list offered by a row's context menu.
struct WorkspaceGroupMenuSnapshot: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let name: String
        /// How many groups hold this group; the submenu indents by it (#cm-106). 0 in a window with no nested group.
        var depth: Int = 0

        /// The submenu item's indentation level (AppKit), at most the 15 a menu item takes (#cm-106).
        var menuIndentationLevel: Int { min(max(depth, 0), 15) }

        /// The title a SwiftUI menu shows, which has no indent: padded by depth with em spaces (#cm-106).
        var paddedTitle: String { String(repeating: "\u{2003}", count: menuIndentationLevel) + name }
    }

    let items: [Item]
}
