import Foundation

/// Settings under the dotted-id prefix `workspaceColors.*`.
public struct WorkspaceColorsCatalogSection: SettingCatalogSection {
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
        defaultValue: [:],
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
