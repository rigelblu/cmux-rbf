/// The status list, in the file's order.
///
/// Not `Codable`: the stored copy of the last list that worked holds `entries` only.
public struct WorkspaceStatusList: Equatable, Sendable {
    /// Where the list in use came from.
    public enum Source: String, Sendable {
        /// Read from `cmux.json` by a load that worked.
        case file
        /// The app's stored copy of the last list that worked.
        case stored
        /// cmux's five: the app never loaded a list, or its last load that worked found no key.
        case cmux
    }

    /// The entries, in the file's order.
    public let entries: [WorkspaceStatusEntry]
    /// Where the list came from.
    public let source: Source

    /// Creates a list.
    public init(entries: [WorkspaceStatusEntry], source: Source) {
        self.entries = entries
        self.source = source
    }

    /// cmux's five statuses in cmux's order, as a list. Source `.cmux`.
    ///
    /// The entries carry no display names (`name` is `nil`): cmux's names are localized in the app, so a caller
    /// draws each entry's ``WorkspaceStatusEntry/label``, which says to draw cmux's own name.
    public static let cmuxFive = WorkspaceStatusList(
        entries: WorkspaceTaskStatus.allCases.map { WorkspaceStatusEntry(id: $0.rawValue, name: nil) },
        source: .cmux
    )

    /// The ids a status set accepts: the entries' ids in order, then cmux's ids the list has no entry for, in cmux's
    /// order, then `auto` and `none`. This is the order a refused id is answered with.
    public var acceptedIDs: [String] {
        let own = entries.map(\.id)
        let cmuxs = WorkspaceTaskStatus.allCases.map(\.rawValue).filter { !own.contains($0) }
        return own + cmuxs + ["auto", "none"]
    }

    /// The entry with this id, or `nil` when the list does not have it. Ids match exactly.
    public func entry(id: String) -> WorkspaceStatusEntry? {
        entries.first { $0.id == id }
    }

    /// The first entry from the top that extends this cmux status. One of cmux's five carries no `extends`,
    /// so it never answers.
    public func firstExtending(_ status: WorkspaceTaskStatus) -> WorkspaceStatusEntry? {
        entries.first { $0.extends == status }
    }
}
