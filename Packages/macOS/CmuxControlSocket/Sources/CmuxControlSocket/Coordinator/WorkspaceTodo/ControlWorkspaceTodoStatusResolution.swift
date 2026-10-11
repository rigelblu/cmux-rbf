public import Foundation

/// The app-side resolution of `workspace.status.get` / `workspace.status.set`.
public enum ControlWorkspaceTodoStatusResolution: Sendable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// The `status` param was not a known lane (the string is echoed back).
    case invalidStatus(String)
    /// The `status` param is neither in the list in use nor one of cmux's lanes (#cm-109). `accepted` is what a set
    /// takes, in the order a refusal names them. The app no longer answers ``invalidStatus(_:)``.
    case unknownStatus(String, accepted: [String])
    /// The status snapshot after the read/mutation, with the owning window.
    case resolved(windowID: UUID?, status: ControlWorkspaceTodoStatusSnapshot)
}
