public import Foundation
internal import CmuxSettings

/// Resolves explicit group status and color picks without changing the group's members or order.
public struct WorkspaceGroupStatusActions {
    /// The list in use for this mutation.
    public let list: WorkspaceStatusList
    /// Resolves a palette name to the hex currently available in this app.
    public let resolveColor: (String) -> String?

    /// Creates a writer with an explicit list and palette resolver.
    /// - Parameters:
    ///   - list: The status list in use.
    ///   - resolveColor: The current palette resolver; nil means the color is unavailable.
    public init(list: WorkspaceStatusList, resolveColor: @escaping (String) -> String?) {
        self.list = list
        self.resolveColor = resolveColor
    }

    /// Applies a status pick, returning false for an unknown status without changing the group.
    /// - Parameters:
    ///   - action: The explicit pick; Auto and None both clear a group's status and color.
    ///   - group: The group to update.
    /// - Returns: Whether the pick was accepted.
    @discardableResult
    public func apply(_ action: WorkspaceStatusPickAction, to group: inout WorkspaceGroup) -> Bool {
        switch action {
        case .auto, .hide:
            group.statusId = nil
            group.customColor = nil
        case .status(let id):
            let entry = list.entry(id: id)
            guard entry != nil || WorkspaceTaskStatus(rawValue: id) != nil else { return false }
            group.statusId = id
            group.customColor = entry?.color.flatMap(resolveColor).flatMap(WorkspaceColorHex.normalized)
        }
        return true
    }

    /// Applies a color pick: a status's color selects it, another color clears the status.
    /// - Parameters:
    ///   - hex: The picked color; nil means No Color.
    ///   - group: The group to update.
    public func applyColor(_ hex: String?, to group: inout WorkspaceGroup) {
        if let hex, !hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           WorkspaceColorHex.normalized(hex) == nil { return }
        let normalized = hex.flatMap(WorkspaceColorHex.normalized)
        group.customColor = normalized
        group.statusId = normalized.flatMap { picked in
            list.entries.first { entry in
                entry.color.flatMap(resolveColor).flatMap(WorkspaceColorHex.normalized) == picked
            }?.id
        }
    }
}
