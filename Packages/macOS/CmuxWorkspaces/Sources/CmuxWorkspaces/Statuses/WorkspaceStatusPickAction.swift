/// What a pick, a key, a command or a script asks for. The one type every entrance passes.
public enum WorkspaceStatusPickAction: Hashable, Sendable {
    case auto
    /// None. Not named `none`: beside an optional action that would read as "no action".
    case hide
    case status(id: String)

    /// cmux's Done by id: what Mark Workspace as Done passes.
    public static let done: WorkspaceStatusPickAction = .status(id: WorkspaceTaskStatus.done.rawValue)
}
