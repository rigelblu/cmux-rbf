public import Foundation

/// Identity and target rules shared by workflow command-palette integrations.
public enum JustRBFWorkflowCommandPalettePolicy {
    /// The namespace for canonical workflow command identifiers.
    public static let commandIDPrefix = "palette.workflow."

    /// Returns whether a command identifier belongs to a just-rbf workflow.
    public static func recognizes(commandID: String) -> Bool {
        commandID.hasPrefix(commandIDPrefix)
    }

    /// Resolves an activation only when the captured target remains the same local terminal.
    ///
    /// - Parameters:
    ///   - name: The canonical bare workflow name.
    ///   - targetWorkspaceId: The workspace captured when the palette opened.
    ///   - targetPanelId: The panel captured when the palette opened.
    ///   - resolvedWorkspaceId: The workspace found again at activation time.
    ///   - resolvedPanelId: The panel found again at activation time.
    ///   - resolvedPanelIsTerminal: Whether the resolved panel is still a terminal.
    ///   - resolvedPanelIsRemote: Whether the resolved panel is now remote.
    /// - Returns: Exact target and input data, or `nil` when revalidation fails.
    public static func activation(
        named name: String,
        targetWorkspaceId: UUID,
        targetPanelId: UUID,
        resolvedWorkspaceId: UUID?,
        resolvedPanelId: UUID?,
        resolvedPanelIsTerminal: Bool,
        resolvedPanelIsRemote: Bool
    ) -> JustRBFWorkflowActivation? {
        guard resolvedWorkspaceId == targetWorkspaceId,
              resolvedPanelId == targetPanelId,
              resolvedPanelIsTerminal,
              !resolvedPanelIsRemote else {
            return nil
        }
        return JustRBFWorkflowActivation(
            workspaceId: targetWorkspaceId,
            panelId: targetPanelId,
            input: name
        )
    }
}
