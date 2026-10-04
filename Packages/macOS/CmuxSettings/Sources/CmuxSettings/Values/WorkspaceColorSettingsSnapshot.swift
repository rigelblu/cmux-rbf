import Foundation

/// The saved palette and its presentation metadata, excluding workspace/group assignments.
public struct WorkspaceColorSettingsSnapshot: Equatable, Sendable {
    /// One completed Settings action; moves name the destination identity, never a stale index.
    public enum Action: Equatable, Sendable {
        case move(name: String, before: String?)
        case visibility(name: String, visible: Bool)
        case restoreOrder
        case resetPalette
    }

    /// Rejection before publication, either a stale snapshot or an unsuccessful save.
    public enum SaveError: Error, Equatable {
        case stale
        case failed
    }

    /// Full effective palette, including hidden entries.
    public var palette: [String: String]
    /// Custom display names keyed by raw identity.
    public var displayNames: [String: String]
    /// Semantic labels keyed by raw identity.
    public var labels: [String: String]
    /// Chooser presentation only.
    public var preferences: WorkspaceColorMenuPreferences

    /// Captures the complete saved color-settings state.
    /// - Parameters:
    ///   - palette: Full effective palette.
    ///   - displayNames: Raw custom display-name metadata.
    ///   - labels: Raw semantic-label metadata.
    ///   - preferences: Saved chooser preferences.
    public init(
        palette: [String: String],
        displayNames: [String: String] = [:],
        labels: [String: String] = [:],
        preferences: WorkspaceColorMenuPreferences = WorkspaceColorMenuPreferences()
    ) {
        self.palette = palette
        self.displayNames = displayNames
        self.labels = labels
        self.preferences = preferences
    }

    /// Computes one complete result without writing or changing assignments.
    /// - Parameters:
    ///   - action: Completed move, visibility change or recovery action.
    ///   - canonicalNames: Current authoritative palette order.
    ///   - defaultPalette: Built-in entries restored by broad reset.
    /// - Returns: The resulting complete snapshot.
    /// - Throws: `SaveError.stale` if a row or destination no longer exists.
    public func applying(
        _ action: Action,
        canonicalNames: [String],
        defaultPalette: [String: String]
    ) throws -> Self {
        var result = self
        switch action {
        case let .move(name, before):
            guard palette[name] != nil,
                  before.map({ palette[$0] != nil }) ?? true else { throw SaveError.stale }
            guard before != name else { return self }
            var names = preferences.order(canonicalNames: canonicalNames)
            names.removeAll { $0 == name }
            let index = before.flatMap { names.firstIndex(of: $0) } ?? names.endIndex
            names.insert(name, at: index)
            result.preferences.orderedNames = names
        case let .visibility(name, visible):
            guard palette[name] != nil else { throw SaveError.stale }
            result.preferences.hiddenNames = preferences.hiddenNames.filter {
                $0 != name && palette[$0] != nil
            }
            if !visible { result.preferences.hiddenNames.append(name) }
        case .restoreOrder:
            result.preferences.orderedNames = []
        case .resetPalette:
            result.palette = defaultPalette
            result.displayNames = [:]
            result.labels = labels.filter { defaultPalette[$0.key] != nil }
            result.preferences = WorkspaceColorMenuPreferences()
        }
        return result
    }
}
