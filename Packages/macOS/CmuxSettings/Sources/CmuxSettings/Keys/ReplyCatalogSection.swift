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

    /// The labels shipped when neither Settings nor `cmux.json` has set any.
    ///
    /// Three, most-used first, since a narrow panel keeps only the first few
    /// as chips (Tom, 2026-09-11). Not localized: the agent receives the label's
    /// text verbatim as the note.
    public static let defaultLabels = ["lgtm", "why?", "redline"]

    /// The quick labels offered above an open note, in order — `cm-69.3`.
    ///
    /// As many as fit the panel are chips; the rest sit in the `⌄` menu. **An empty
    /// array means no labels**, not the defaults: Settings can remove every
    /// row, and falling back would bring the defaults back. The defaults live here and
    /// nowhere else — the `cmux.json` parser writes nothing when the key is
    /// absent, so an unset key reaches this value only when Settings has
    /// stored nothing either.
    public let labels = DefaultsKey<[String]>(
        id: "reply.labels",
        defaultValue: ReplyCatalogSection.defaultLabels,
        userDefaultsKey: "replyLabels"
    )

    /// Cleans a raw label list from `cmux.json` or the Settings editor.
    ///
    /// Trims whitespace, drops blank entries, and skips anything that is not a
    /// string **while keeping the rest** — unlike the file store's shared
    /// `jsonStringArray`, which rejects the whole list on the first bad entry.
    public static func normalizedLabels(_ raw: [Any]) -> [String] {
        raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public init() {}
}
