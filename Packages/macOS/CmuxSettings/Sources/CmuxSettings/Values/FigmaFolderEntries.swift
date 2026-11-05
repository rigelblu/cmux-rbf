import Foundation

/// What `figma.folders` in `cmux.json` holds: a map from each key, as written,
/// to what the file says there. Every entry is kept, the ones that are not text
/// included, so a write for one directory never deletes another's.
///
/// A `[String: String]` would decode all or nothing
/// (`Dictionary+SettingCodable.swift`): one value that is not text, under any
/// key, would make every reader answer as if the object were empty. This keeps
/// each entry on its own. ``decodeFromJSON(_:)`` takes any JSON object; only a
/// value that is not an object at all is `nil`, which a reader takes as no
/// entries.
public struct FigmaFolderEntries: SettingCodable {
    /// One entry's value.
    public enum Entry: Equatable, Sendable {
        /// Text, to be checked by ``FigmaFolderLink/check(_:)`` where it matters.
        case link(String)
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
    public static let empty = FigmaFolderEntries()

    public static func decodeFromUserDefaults(_ raw: Any?) -> FigmaFolderEntries? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any { encodeForJSON() }

    public static func decodeFromJSON(_ raw: Any?) -> FigmaFolderEntries? {
        guard let object = raw as? [String: Any] else { return nil }
        var result: [String: Entry] = [:]
        result.reserveCapacity(object.count)
        for (key, value) in object {
            if let text = value as? String {
                result[key] = .link(text)
            } else {
                result[key] = .notText(rawJSON: rawJSON(of: value))
            }
        }
        return FigmaFolderEntries(result)
    }

    public func encodeForJSON() -> Any {
        var object: [String: Any] = [:]
        object.reserveCapacity(entries.count)
        for (key, entry) in entries {
            switch entry {
            case .link(let text):
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
