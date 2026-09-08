import Foundation

/// Settings under the dotted-id prefix `reply.*` — the right sidebar's Reply
/// mode.
///
/// **Top-level rather than under `rightSidebar`, and the reason is a real
/// trap.** `rightSidebar` sits in the settings validator's `structural` skip
/// set (`skills/cmux-settings/scripts/cmux-settings`), so a typo beneath it is
/// never reported — the key is silently ignored forever. A top-level `reply.`
/// section is merely unregistered until it is added to `known_sections`, which
/// is one line and is done. `fileExplorer` is the precedent this follows;
/// `vault` is *not*, and citing it was backwards — it carries no schema
/// description in any of the 20 locales and sits in that same skip set.
public struct ReplyCatalogSection: SettingCatalogSection {
    /// Valid values for how far `◄` walks back, for the parser and any future
    /// settings UI.
    ///
    /// The floor is 1 because `0` would leave the newest reply as the only
    /// reachable one and `◄` permanently dead, which reads as a broken panel
    /// rather than a configured one. The ceiling is high enough to be
    /// effectively "no cap", which is what the manual test scenarios need in
    /// order to reach the paging paths the cap otherwise makes rare.
    public static let maxMessagesBackRange = 1...100_000

    /// How many **un-annotated** replies `◄` steps back through, default 5.
    ///
    /// A reply carrying unsent marks never spends this budget and stays
    /// reachable past it, so the configured number is only what shows on
    /// screen when nothing is marked.
    ///
    /// No Settings row (Tom, 2026-09-07): the panel is for the most recent
    /// replies, and the default is right for everyone who has not gone looking
    /// for the key.
    public let maxMessagesBack = DefaultsKey<Int>(
        id: "reply.maxMessagesBack",
        defaultValue: 5,
        userDefaultsKey: "replyMaxMessagesBack"
    )

    public init() {}
}
