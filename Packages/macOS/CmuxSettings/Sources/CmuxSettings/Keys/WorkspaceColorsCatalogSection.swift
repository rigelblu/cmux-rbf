import Foundation

/// Settings under the dotted-id prefix `workspaceColors.*`.
public struct WorkspaceColorsCatalogSection: SettingCatalogSection {
    /// Local chooser presentation only; never changes palette resolution or assignments.
    public let menuPreferences = DefaultsKey<WorkspaceColorMenuPreferences>(
        id: "workspaceColors.menuPreferences",
        defaultValue: WorkspaceColorMenuPreferences(),
        userDefaultsKey: "workspaceTabColor.menuPreferences"
    )
    // `workspaceColors.indicatorStyle` was removed 2026-07-31. Accent Strip is
    // no longer one style among three — it is how a coloured workspace row
    // renders, so there is nothing left to choose between. Stored
    // `sidebarActiveTabIndicatorStyle` values in UserDefaults and
    // `indicatorStyle` keys in cmux.json are simply ignored; they select
    // nothing rather than failing.

    public let selectionColorHex = DefaultsKey<String>(
        id: "workspaceColors.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "workspaceColors.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    public let palette = DefaultsKey<[String: String]>(
        id: "workspaceColors.colors",
        // A missing key is the built-in palette; a stored empty dictionary is an
        // intentionally empty palette. Do not collapse those two states in Settings.
        defaultValue: [
            "Red": "#C0392B", "Crimson": "#922B21", "Orange": "#A04000", "Amber": "#7D6608",
            "Olive": "#4A5C18", "Green": "#196F3D", "Teal": "#006B6B", "Aqua": "#0E6B8C",
            "Blue": "#1565C0", "Navy": "#1A5276", "Indigo": "#283593", "Purple": "#6A1B9A",
            "Magenta": "#AD1457", "Rose": "#880E4F", "Brown": "#7B3F00", "Charcoal": "#3E4B5E"
        ],
        userDefaultsKey: "workspaceTabColor.colors"
    )

    /// Optional semantic labels keyed by raw palette name, e.g. `Teal` → `GOAL: Primary`.
    ///
    /// Additive metadata. A missing key, a missing raw color, or a cleared string simply
    /// leaves that entry showing its raw palette name.
    public let labels = DefaultsKey<[String: String]>(
        id: "workspaceColors.labels",
        defaultValue: [:],
        userDefaultsKey: "workspaceTabColor.labels"
    )

    /// Optional editable display names keyed by stable raw custom palette identity.
    ///
    /// Additive metadata. Built-in or missing raw names fail closed in the shared
    /// resolver; clearing one restores the raw `Custom N` fallback.
    public let displayNames = DefaultsKey<[String: String]>(
        id: "workspaceColors.displayNames",
        defaultValue: [:],
        userDefaultsKey: "workspaceTabColor.displayNames"
    )

    /// Highest `Custom N` index ever minted. Internal bookkeeping, not user configuration:
    /// no `cmux.json` parsing writes it. It lives in the catalog so `CmuxSettingsUI` can
    /// advance it through the typed store, which never hands out raw `UserDefaults`.
    ///
    /// Deliberately outside the palette dictionary so **Reset Palette** cannot revive
    /// name recycling. See `WorkspaceColorCustomNameMint`.
    public let customNameHighWaterMark = DefaultsKey<Int>(
        id: "workspaceColors.customNameHighWaterMark",
        defaultValue: 0,
        userDefaultsKey: WorkspaceColorCustomNameMint.highWaterMarkDefaultsKey
    )

    public let paletteOverrides = JSONKey<[String: String]>(
        id: "workspaceColors.paletteOverrides",
        defaultValue: [:]
    )

    public let customColors = JSONKey<[String]>(
        id: "workspaceColors.customColors",
        defaultValue: []
    )

    public init() {}
}
