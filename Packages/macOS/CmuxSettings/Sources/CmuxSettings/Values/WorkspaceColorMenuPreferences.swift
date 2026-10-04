import Foundation

/// Presentation preferences keyed by stable raw palette names, independent of assignments.
public struct WorkspaceColorMenuPreferences: SettingCodable {
    /// Saved chooser order. Unknown and repeated names are ignored when projected.
    public var orderedNames: [String]
    /// Palette identities omitted from workspace and group color menus.
    public var hiddenNames: [String]

    /// Creates preferences; empty arrays preserve the canonical order and show every entry.
    /// - Parameters:
    ///   - orderedNames: Raw palette identities in preferred order.
    ///   - hiddenNames: Raw palette identities to hide from choosers.
    public init(orderedNames: [String] = [], hiddenNames: [String] = []) {
        self.orderedNames = orderedNames
        self.hiddenNames = hiddenNames
    }

    /// Projects the saved sequence onto the full current palette, appending new entries.
    /// - Parameter canonicalNames: Built-ins followed by naturally sorted custom identities.
    /// - Returns: Every current identity exactly once, including hidden entries.
    public func order(canonicalNames: [String]) -> [String] {
        let available = Set(canonicalNames)
        var seen: Set<String> = []
        return (orderedNames + canonicalNames).filter { available.contains($0) && seen.insert($0).inserted }
    }

    /// Carries surviving chooser positions across a palette change and appends new entries.
    /// - Parameters:
    ///   - previousCanonicalNames: Full palette identities before the change.
    ///   - canonicalNames: Full palette identities after the change.
    /// - Returns: A saved complete chooser sequence with removed identities pruned.
    public func reconciled(
        previousCanonicalNames: [String],
        canonicalNames: [String]
    ) -> Self {
        let previous = Set(previousCanonicalNames)
        let current = Set(canonicalNames)
        let survivors = order(canonicalNames: previousCanonicalNames).filter { current.contains($0) }
        let added = canonicalNames.filter { !previous.contains($0) }
        return Self(
            orderedNames: survivors + added,
            hiddenNames: hiddenNames.filter { previous.contains($0) && current.contains($0) }
        )
    }

    /// Decodes one complete preference record, failing closed for malformed fields.
    /// - Parameter raw: A property-list dictionary with `order` and `hidden` arrays.
    /// - Returns: The decoded record or nil for malformed storage.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        guard let raw = raw as? [String: Any],
              let order = [String].decodeFromUserDefaults(raw["order"]),
              let hidden = [String].decodeFromUserDefaults(raw["hidden"]) else { return nil }
        return Self(orderedNames: order, hiddenNames: hidden)
    }

    /// Encodes order and visibility together as one property-list value.
    /// - Returns: The complete preference record.
    public func encodeForUserDefaults() -> Any { ["order": orderedNames, "hidden": hiddenNames] }

    /// Decodes the same complete record from JSON.
    /// - Parameter raw: A JSON dictionary.
    /// - Returns: The decoded record or nil when malformed.
    public static func decodeFromJSON(_ raw: Any?) -> Self? { decodeFromUserDefaults(raw) }

    /// Encodes the record as a JSON-compatible dictionary.
    /// - Returns: The complete preference record.
    public func encodeForJSON() -> Any { encodeForUserDefaults() }
}
