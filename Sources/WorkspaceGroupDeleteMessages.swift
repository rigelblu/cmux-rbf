import CmuxWorkspaces
import Foundation

/// The delete message for a group that holds groups (#cm-106): one sentence for each
/// combination of one group or several groups inside, and no workspace, one workspace or several to close.
func deleteMessageForGroupsInside(groupName: String, inside: Int, workspaces: Int) -> String {
    if inside == 1 {
        switch workspaces {
        case 0:
            let format = String(
                localized: "dialog.deleteGroup.message.group.none",
                defaultValue: "Delete the group \u{201C}%@\u{201D} and the group inside it?"
            )
            return String.localizedStringWithFormat(format, groupName)
        case 1:
            let format = String(
                localized: "dialog.deleteGroup.message.group.lone",
                defaultValue: "Delete the group \u{201C}%@\u{201D}, the group inside it, and close their workspace?"
            )
            return String.localizedStringWithFormat(format, groupName)
        default:
            let format = String(
                localized: "dialog.deleteGroup.message.group.many",
                defaultValue: "Delete the group \u{201C}%1$@\u{201D}, the group inside it, and close their %2$lld workspaces?"
            )
            return String.localizedStringWithFormat(format, groupName, workspaces)
        }
    }
    switch workspaces {
    case 0:
        let format = String(
            localized: "dialog.deleteGroup.message.groups.none",
            defaultValue: "Delete the group \u{201C}%1$@\u{201D} and the %2$lld groups inside it?"
        )
        return String.localizedStringWithFormat(format, groupName, inside)
    case 1:
        let format = String(
            localized: "dialog.deleteGroup.message.groups.lone",
            defaultValue: "Delete the group \u{201C}%1$@\u{201D}, the %2$lld groups inside it, and close their workspace?"
        )
        return String.localizedStringWithFormat(format, groupName, inside)
    default:
        let format = String(
            localized: "dialog.deleteGroup.message.groups.many",
            defaultValue: "Delete the group \u{201C}%1$@\u{201D}, the %2$lld groups inside it, and close their %3$lld workspaces?"
        )
        return String.localizedStringWithFormat(format, groupName, inside, workspaces)
    }
}

/// What the Delete Group dialog asks (#cm-106): the group's name, how many workspaces close, and how
/// many groups are inside. `nil` from `deleteGroupAsk` means no dialog shows and the group is deleted.
struct DeleteGroupAsk: Equatable {
    let groupName: String
    let memberCount: Int
    let groupsInside: Int
}

/// Whether Delete Group asks, and with which numbers. A pinned group asks, a group with workspaces
/// inside asks, and a group that holds groups asks even when no workspace would close.
func deleteGroupAsk(isPinned: Bool, confirmation: WorkspaceGroupDeletionConfirmation) -> DeleteGroupAsk? {
    guard isPinned || confirmation.containedWorkspaceCount > 0 || confirmation.containedGroupCount > 0 else {
        return nil
    }
    return DeleteGroupAsk(
        groupName: confirmation.groupName,
        memberCount: confirmation.memberCount,
        groupsInside: confirmation.containedGroupCount
    )
}
