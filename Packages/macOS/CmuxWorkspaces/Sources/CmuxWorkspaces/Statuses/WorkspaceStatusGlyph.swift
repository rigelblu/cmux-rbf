/// The glyph a status entry draws: either one of cmux's eight shapes, or an SF Symbol.
///
/// Encodable only, like ``WorkspaceStatusEntry``: the app's stored copy of the list is written from it as a single string,
/// either the shape's raw value or the symbol's name.
public enum WorkspaceStatusGlyph: Hashable, Sendable, Encodable {
    case shape(WorkspaceStatusIcon)
    case symbol(String)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .shape(let icon):
            try container.encode(icon.rawValue)
        case .symbol(let name):
            try container.encode(name)
        }
    }
}
