import AppKit
import CmuxSettings

@MainActor
func presentSidebarWorkspaceGroupRenamePrompt(
    tabManager: TabManager,
    groupId: UUID,
    currentName: String
) {
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workspaceGroup.rename.title",
        defaultValue: "Rename Group"
    )
    alert.informativeText = String(
        localized: "workspaceGroup.rename.message",
        defaultValue: "Enter a new name for this group."
    )
    alert.addButton(
        withTitle: String(localized: "workspaceGroup.rename.confirm", defaultValue: "Rename")
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = currentName
    input.placeholderString = String(
        localized: "workspaceGroup.rename.placeholder",
        defaultValue: "Group name"
    )
    alert.accessoryView = input

    let alertWindow = alert.window
    alertWindow.initialFirstResponder = input
    DispatchQueue.main.async {
        alertWindow.makeFirstResponder(input)
        input.selectText(nil)
    }

    let response = alert.runCmuxModal()
    guard response == .alertFirstButtonReturn else { return }
    tabManager.renameWorkspaceGroup(groupId: groupId, name: input.stringValue)
}

/// `#RRGGBB` entry for a group's colour, the twin of the workspace row's
/// **Choose Custom Color…**.
///
/// Deliberately hex-only, like `workspace.group.set_color`: it normalizes through
/// `addCustomColor`, which never resolves a palette name or a semantic label. A
/// typed label such as `GOAL` is an invalid colour here, and says so, rather than
/// quietly resolving — the group menu shows labels, but only ever passes hexes.
@MainActor
func presentSidebarWorkspaceGroupCustomColorPrompt(
    tabManager: TabManager,
    groupId: UUID,
    anchorWorkspaceId: UUID,
    currentHex: String?
) {
    let presentingWindow = AppDelegate.shared?.mainWindowContainingWorkspace(anchorWorkspaceId)
    let alert = NSAlert()
    alert.messageText = String(
        localized: "workspaceGroup.customColor.title",
        defaultValue: "Custom Group Color"
    )
    alert.informativeText = String(
        localized: "alert.customColor.message",
        defaultValue: "Enter a hex color in the format #RRGGBB."
    )
    let seed = currentHex ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
    let input = NSTextField(string: seed)
    input.placeholderString = "#1565C0"
    input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
    alert.accessoryView = input
    alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
    alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))
    let alertWindow = alert.window
    alertWindow.initialFirstResponder = input
    let response = alert.runCmuxModal(presentingWindow: presentingWindow) { _ in
        alertWindow.makeFirstResponder(input)
        input.selectText(nil)
    }
    guard response == .alertFirstButtonReturn else { return }
    guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
        presentInvalidWorkspaceColorAlert(input.stringValue, presentingWindow: presentingWindow)
        return
    }
    tabManager.setWorkspaceGroupColor(groupId: groupId, hex: normalized)
}

/// Shared "that is not a hex colour" alert for both custom-colour prompts.
@MainActor
func presentInvalidWorkspaceColorAlert(_ value: String, presentingWindow: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
    } else {
        alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
    }
    alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
    _ = alert.runCmuxModal(presentingWindow: presentingWindow)
}

/// Confirmation dialog for destructive group deletion.
@MainActor
func confirmDeleteWorkspaceGroup(groupName: String, memberCount: Int) -> Bool {
    let title = String(
        localized: "dialog.deleteGroup.title",
        defaultValue: "Delete this group?"
    )
    let message: String?
    if memberCount <= 0 {
        message = nil
    } else if memberCount == 1 {
        let format = String(
            localized: "dialog.deleteGroup.message.lone",
            defaultValue: "Delete the group \u{201C}%@\u{201D} and close its workspace?"
        )
        message = String.localizedStringWithFormat(format, groupName)
    } else if memberCount == 2 {
        let format = String(
            localized: "dialog.deleteGroup.message.one",
            defaultValue: "Delete the group \u{201C}%@\u{201D} and close its 2 workspaces?"
        )
        message = String.localizedStringWithFormat(format, groupName)
    } else {
        let format = String(
            localized: "dialog.deleteGroup.message.many",
            defaultValue: "Delete the group \u{201C}%1$@\u{201D} and close its %2$lld workspaces?"
        )
        message = String.localizedStringWithFormat(format, groupName, memberCount)
    }
    let alert = NSAlert()
    alert.messageText = title
    if let message {
        alert.informativeText = message
    }
    alert.alertStyle = .warning
    alert.addButton(
        withTitle: String(
            localized: "dialog.deleteGroup.confirm",
            defaultValue: "Delete"
        )
    )
    alert.addButton(
        withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
    )
    if let confirmButton = alert.buttons.first {
        confirmButton.keyEquivalent = "\r"
        confirmButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = confirmButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = confirmButton
    }
    if let cancelButton = alert.buttons.dropFirst().first {
        cancelButton.keyEquivalent = "\u{1b}"
    }
    return alert.runCmuxModal() == .alertFirstButtonReturn
}
