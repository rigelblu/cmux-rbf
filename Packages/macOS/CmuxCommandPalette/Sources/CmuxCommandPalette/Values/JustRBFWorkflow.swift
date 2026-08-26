/// One validated just-rbf workflow exposed to the command palette.
public struct JustRBFWorkflow: Sendable, Equatable {
    /// The canonical bare workflow name.
    public let name: String
    /// The escaped description from `just-rbf --list`, or `nil` when the row had no tab.
    public let escapedDescription: String?
    init(name: String, escapedDescription: String?) {
        self.name = name
        self.escapedDescription = escapedDescription
    }

    /// The stable command-palette identifier for this workflow.
    public var commandPaletteID: String {
        JustRBFWorkflowCommandPalettePolicy.commandIDPrefix + name
    }

    /// Search terms for the workflow's name, purpose, and shared category aliases.
    public var commandPaletteKeywords: [String] {
        var keywords = [name, "workflow", "just-rbf", "rbf"]
        if let escapedDescription, !escapedDescription.isEmpty {
            keywords.append(escapedDescription)
        }
        return keywords
    }

    /// Builds the palette row title using a localized category label.
    public func commandPaletteTitle(category: String) -> String {
        guard let escapedDescription, !escapedDescription.isEmpty else {
            return "\(category): \(name)"
        }
        return "\(category): \(name) \(escapedDescription)"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.escapedDescription == rhs.escapedDescription
    }
}
