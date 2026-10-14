/// Where a status set came from.
public enum WorkspaceStatusOrigin: Sendable {
    /// This Mac: a pick, a key, the palette, the CLI.
    case mac
    /// The phone. A status set from the phone writes no color.
    case phone

    /// The origin of the call in progress. This Mac unless a caller says otherwise.
    ///
    /// A task-local value is an ambient parameter; it is kept on purpose so the phone's call path needs no new
    /// parameter through the socket package's protocol.
    @TaskLocal public static var current: WorkspaceStatusOrigin = .mac
}
