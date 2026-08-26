public import Foundation

/// An exact local-terminal activation accepted for one workflow command.
public struct JustRBFWorkflowActivation: Sendable, Equatable {
    /// The captured workspace that owns the destination terminal.
    public let workspaceId: UUID
    /// The captured panel that receives the workflow input.
    public let panelId: UUID
    /// The canonical workflow name, without a trailing newline.
    public let input: String

    /// Creates a validated activation for an exact captured terminal target.
    public init(workspaceId: UUID, panelId: UUID, input: String) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.input = input
    }
}
