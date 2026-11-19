import Foundation

/// Settings for the Agent Pane (the `agentPane.*` keys). cmux-rbf #cm-126.15.
public struct AgentPaneCatalogSection: SettingCatalogSection {
    /// The name each agent's Agent Pane shows in place of "Agent Pane": an object from an
    /// agent's slug (`claude`, `codex`) or `*` for every agent to the text of the caption.
    /// Kept raw by ``AgentPaneNameEntries``, so one value that is not text never hides the
    /// others.
    ///
    /// JSON-backed (`JSONKey`) on purpose, like `figma.folders`: `cmux.json` lives at a fixed
    /// path shared by every bundle id.
    public let names = JSONKey<AgentPaneNameEntries>(
        id: "agentPane.names",
        defaultValue: .empty
    )

    /// Creates the section with the shipped default (no names).
    public init() {}
}
