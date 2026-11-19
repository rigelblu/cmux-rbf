import Foundation

/// What `agentPane.names` in `cmux.json` holds: a map from an agent's slug (or `*`),
/// as written, to the name the file gives that agent's Agent Pane.
///
/// cmux-rbf #cm-126.15. Kept raw the way ``FigmaFolderEntries`` is: a `[String: String]`
/// would decode all or nothing, so one value that is not text would hide every other
/// entry. This keeps each entry on its own. ``decodeFromJSON(_:)`` takes any JSON object;
/// only a value that is not an object at all is `nil`, which a reader takes as no names.
public struct AgentPaneNameEntries: SettingCodable {
    /// One entry's value.
    public enum Entry: Equatable, Sendable {
        /// Text, which may still be empty once trimmed.
        case name(String)
        /// Anything else the file held there, as the JSON text it was read from.
        case notText(rawJSON: String)
    }

    /// Each key exactly as the file wrote it.
    public var entries: [String: Entry]

    /// Creates the entries from a map.
    public init(_ entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// No entries: the shipped default.
    public static let empty = AgentPaneNameEntries()

    /// The usable names: key lowercased and trimmed, value trimmed, an entry whose value is
    /// not text, or is empty once trimmed, or whose key is empty, left out. Two keys that
    /// normalize alike resolve by sorted original key, so the answer never depends on
    /// dictionary order.
    public var usableNames: [String: String] {
        var result: [String: String] = [:]
        for key in entries.keys.sorted() {
            guard case .name(let text)? = entries[key] else { continue }
            let slug = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if slug.isEmpty || name.isEmpty { continue }
            if result[slug] == nil { result[slug] = name }
        }
        return result
    }

    public static func decodeFromUserDefaults(_ raw: Any?) -> AgentPaneNameEntries? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any { encodeForJSON() }

    public static func decodeFromJSON(_ raw: Any?) -> AgentPaneNameEntries? {
        guard let object = raw as? [String: Any] else { return nil }
        var result: [String: Entry] = [:]
        result.reserveCapacity(object.count)
        for (key, value) in object {
            if let text = value as? String {
                result[key] = .name(text)
            } else {
                result[key] = .notText(rawJSON: rawJSON(of: value))
            }
        }
        return AgentPaneNameEntries(result)
    }

    public func encodeForJSON() -> Any {
        var object: [String: Any] = [:]
        object.reserveCapacity(entries.count)
        for (key, entry) in entries {
            switch entry {
            case .name(let text):
                object[key] = text
            case .notText(let rawJSON):
                object[key] = Self.value(fromRawJSON: rawJSON)
            }
        }
        return object
    }

    // MARK: - Raw JSON

    private static func rawJSON(of value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func value(fromRawJSON text: String) -> Any {
        guard let value = try? JSONSerialization.jsonObject(
            with: Data(text.utf8),
            options: [.fragmentsAllowed]
        ) else { return NSNull() }
        return value
    }
}
