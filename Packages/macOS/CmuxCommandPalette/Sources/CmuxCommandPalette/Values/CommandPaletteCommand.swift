import Foundation

/// One runnable palette command: identity, display strings, search keywords,
/// and the action executed when the command is activated.
public struct CommandPaletteCommand: Identifiable {
    /// Stable command identifier.
    public let id: String
    /// Tie-break rank; lower sorts first at equal score.
    public let rank: Int
    /// Display title.
    public let title: String
    /// Optional exact title token rendered with inline-code styling.
    ///
    /// The plain `title` remains the search and accessibility value. Callers
    /// supply this token instead of asking presentation code to infer one from
    /// localized title text.
    public let titleCodeToken: String?
    /// Display subtitle.
    public let subtitle: String
    /// Optional keyboard-shortcut hint shown trailing the row.
    public let shortcutHint: String?
    /// Optional kind label (for example a switcher row's surface kind).
    public let kindLabel: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
    /// The action executed on activation.
    public let action: () -> Void

    /// Creates a command.
    public init(
        id: String,
        rank: Int,
        title: String,
        titleCodeToken: String? = nil,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.titleCodeToken = titleCodeToken
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.action = action
    }

    /// Texts the search corpus indexes for this command.
    public var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}
