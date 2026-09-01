import Foundation

/// Settings under the dotted-id prefix `panes.*`.
///
/// Distinct from ``PaneChromeCatalogSection``, whose keys keep root-level
/// `cmux.json` paths inherited from upstream. New pane-layout settings nest
/// here instead, matching the `workspaceColors.*` shape.
public struct PanesCatalogSection: SettingCatalogSection {
    /// User-defined Arrange Splits patterns, keyed by the display name shown in
    /// the menu, valued by the colon ratio notation the menu already prints as
    /// its hints — e.g. `"Triptych": "1:1:0.5"`.
    ///
    /// Additive: an absent key means no custom patterns, and the four built-ins
    /// are unaffected. An entry whose ratios will not parse is dropped alone
    /// rather than failing the file, the same way an unusable stored palette
    /// colour selects nothing. Parsing and validation live in
    /// `SplitRatioSpec`; ordering and labelling in `SplitArrangementPattern`.
    public let arrangePatterns = DefaultsKey<[String: String]>(
        id: "panes.arrangePatterns",
        defaultValue: [:],
        userDefaultsKey: "panes.arrangePatterns"
    )

    /// Creates the panes settings section with its default keys.
    public init() {}
}
