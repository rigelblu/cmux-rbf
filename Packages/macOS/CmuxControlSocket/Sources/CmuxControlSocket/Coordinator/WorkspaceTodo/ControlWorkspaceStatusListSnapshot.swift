public import Foundation

/// A read-only snapshot of the list of workspace statuses in use, as the app target exposes it to
/// ``ControlCommandCoordinator`` for `workspace.status.list` (#cm-109). Plain values only: no app type and no
/// `CmuxWorkspaces` type crosses the seam (``ControlWorkspaceTodoContext``'s own rule).
public struct ControlWorkspaceStatusListSnapshot: Sendable, Equatable {
    /// Where the list in use came from.
    public enum Source: String, Sendable {
        /// His `cmux.json`.
        case file
        /// The copy of the last list that worked.
        case stored
        /// cmux's own five.
        case cmux
    }

    /// One status of the list, in the list's order.
    public struct Status: Sendable, Equatable {
        /// The status's id.
        public let id: String
        /// His word for it, or `nil` for one of cmux's five that has no word of his.
        public let name: String?
        /// The cmux status it extends (a cmux id), or `nil` for one of cmux's five.
        public let extends: String?
        /// The color as he typed it, or `nil`.
        public let color: String?
        /// The color as this app resolves it (`#RRGGBB`), or `nil` when the entry has no color or this app cannot
        /// resolve it.
        public let colorHex: String?

        /// Creates a status row.
        public init(id: String, name: String?, extends: String?, color: String?, colorHex: String?) {
            self.id = id
            self.name = name
            self.extends = extends
            self.color = color
            self.colorHex = colorHex
        }
    }

    /// One problem the list has. `code` is a fixed word; the sentence is built from it in the coordinator.
    public struct Problem: Sendable, Equatable {
        /// `file_not_read`, `not_a_list`, `entry_not_an_object`, `no_id`, `reserved_id`, `repeated_id`, `no_name`,
        /// `no_extends`, `unknown_extends` or `color_not_in_this_app`.
        public let code: String
        /// The 1-based place of the entry in the file, or `nil`.
        public let entry: Int?
        /// The entry's id, or `nil`.
        public let id: String?
        /// The text that was refused (`unknown_extends`, `color_not_in_this_app`), or the reader's detail for
        /// `file_not_read`; `nil` when there is none.
        public let value: String?
        /// For `file_not_read`: whether the file is missing. It changes the sentence and is not a field of the
        /// answer.
        public let fileMissing: Bool

        /// Creates a problem.
        public init(code: String, entry: Int?, id: String?, value: String?, fileMissing: Bool = false) {
            self.code = code
            self.entry = entry
            self.id = id
            self.value = value
            self.fileMissing = fileMissing
        }
    }

    /// Whether the status controls are on.
    public let controlsEnabled: Bool
    /// Where the list in use came from.
    public let source: Source
    /// The statuses, in the list's order.
    public let statuses: [Status]
    /// The problems, in the order the pill shows them.
    public let problems: [Problem]

    /// Creates a list snapshot.
    public init(controlsEnabled: Bool, source: Source, statuses: [Status], problems: [Problem]) {
        self.controlsEnabled = controlsEnabled
        self.source = source
        self.statuses = statuses
        self.problems = problems
    }

    /// What a context that has no list answers: controls off, cmux's own source, nothing in it.
    public static let empty = ControlWorkspaceStatusListSnapshot(
        controlsEnabled: false, source: .cmux, statuses: [], problems: []
    )
}
