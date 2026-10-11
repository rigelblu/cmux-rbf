import Foundation

/// Settings for the Figma design pane and the agent that fills it (the `figma.*` keys).
public struct FigmaCatalogSection: SettingCatalogSection {
    /// The link to the Figma folder where new designs an agent creates should
    /// go, as stored by ``FigmaFolderLink`` (trimmed). Empty means not set, and
    /// new designs go to the person's Figma Drafts.
    ///
    /// JSON-backed (`JSONKey`) on purpose: `cmux.json` lives at a fixed path
    /// shared by every bundle id, so one value is honored by every cmux build
    /// on the Mac and by `cmux figma folder` with no app running.
    public let defaultFolder = JSONKey<String>(
        id: "figma.defaultFolder",
        defaultValue: ""
    )

    /// Creates the section with the shipped default (not set).
    public init() {}
}
