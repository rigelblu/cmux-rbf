/// One entry of the status list, after checking.
///
/// The list is Tom's own, typed in `cmux.json` under `workspaceStatuses`. An entry is either one of cmux's five
/// statuses named by its id (`todo`, `working`, `needs-attention`, `review`, `done`), or one of his own, which
/// must say which of the five it behaves as.
///
/// Encodable only: the app's stored copy is written from it and read back through `WorkspaceStatusListParser`, so
/// an entry is never built with a field missing.
public struct WorkspaceStatusEntry: Equatable, Sendable, Encodable {
    /// What a workspace stores.
    public let id: String
    /// What he reads, from his file. `nil` only for one of cmux's five in a list from cmux, which carries no display
    /// names. Not public: a caller draws ``label``, never this. (No test can pin the access level: the tests
    /// use `@testable import`.)
    let name: String?
    /// The cmux status this entry behaves as. `nil` only for one of cmux's five.
    public let extends: WorkspaceTaskStatus?
    /// The color as typed. It is resolved when a status is set, never here.
    public let color: String?

    /// Creates an entry.
    public init(id: String, name: String?, extends: WorkspaceTaskStatus? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.extends = extends
        self.color = color
    }

    /// What to draw for this entry: his word when it has one, else cmux's own name for the status it behaves as.
    public var label: WorkspaceStatusLabel {
        name.map(WorkspaceStatusLabel.named) ?? .cmux(behavesAs)
    }

    /// Whether this entry is one of cmux's five, named by its id.
    public var isCmuxOwn: Bool {
        WorkspaceTaskStatus(rawValue: id) != nil
    }

    /// The cmux status this entry behaves as: itself for one of cmux's five, else `extends`.
    ///
    /// An entry of his own with no `extends` cannot come out of the parser; if one is built by hand it
    /// behaves as `todo`, the status cmux shows for a workspace with nothing going on.
    public var behavesAs: WorkspaceTaskStatus {
        WorkspaceTaskStatus(rawValue: id) ?? extends ?? .todo
    }
}
