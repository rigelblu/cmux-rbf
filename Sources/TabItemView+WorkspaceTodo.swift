import AppKit
import CmuxCommandPalette
import CmuxWorkspaces
import SwiftUI

// MARK: - Context menu section

/// The workspace-todo entries of the sidebar row's context menu. Lives in
/// its own file because `Sources/ContentView.swift` sits at its file-length
/// budget; the menu builder runs on demand using values frozen in the
/// parent-built context-menu snapshot.
extension TabItemView {
    @ViewBuilder
    var workspaceTodoContextMenuSection: some View {
        if WorkspaceTodoFeature.isEnabled {
            let isMulti = contextMenuWorkspaceIds.count > 1
            let markDoneLabel = isMulti
                ? String(localized: "contextMenu.markWorkspacesDone", defaultValue: "Mark Workspaces as Done")
                : String(localized: "contextMenu.markWorkspaceDone", defaultValue: "Mark Workspace as Done")
            let markWorkspaceDoneShortcut = KeyboardShortcutSettings.shortcut(for: .markWorkspaceDone)

            // The lane list is shared with the todo pane's status popover (one
            // model, one apply path) so both surfaces stay in lockstep.
            let statusLanes = snapshot.contextMenu.todoStatusLanes
            Menu(String(localized: "contextMenu.workspaceStatus", defaultValue: "Status")) {
                ForEach(statusLanes) { lane in
                    // Divider before the None row (separates opt-out from lanes).
                    if lane.isNone {
                        Divider()
                    }
                    workspaceTodoStatusMenuButton(
                        title: lane.title,
                        isSelected: lane.isSelected,
                        status: lane.status, // (#cm-109.3)
                        icon: lane.icon, // (#cm-109.3)
                        colorHex: lane.colorHex, // (#cm-109.3)
                        isEnabled: lane.action != nil
                    ) {
                        if lane.isNone {
                            actions.hideTodoStatus(contextMenuWorkspaceIds)
                        } else if let action = lane.action {
                            actions.applyTodoStatus(action, contextMenuWorkspaceIds) // (#cm-109)
                        }
                    }
                    // Divider after the Auto row (the row whose action is Auto). (#cm-109)
                    if lane.action == .auto {
                        Divider()
                    }
                }
            }

            if let key = markWorkspaceDoneShortcut.keyEquivalent {
                Button(markDoneLabel) {
                    actions.applyTodoStatus(.done, contextMenuWorkspaceIds)
                }
                .keyboardShortcut(key, modifiers: markWorkspaceDoneShortcut.eventModifiers)
            } else {
                Button(markDoneLabel) {
                    actions.applyTodoStatus(.done, contextMenuWorkspaceIds)
                }
            }

            Button(String(localized: "contextMenu.addChecklistItem", defaultValue: "Add Checklist Item…")) {
            actions.requestChecklistAdd()
            }
        }
    }

    private func workspaceTodoStatusMenuButton(
        title: String,
        isSelected: Bool,
        status: WorkspaceTaskStatus? = nil, // (#cm-109.3)
        icon: WorkspaceStatusGlyph? = nil, // (#cm-109.6)
        colorHex: String? = nil, // (#cm-109)
        isEnabled: Bool = true, // (#cm-109)
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let status, WorkspaceStatusMenuImage.shows(icon: icon, colorHex: colorHex) { // (#cm-109.6)
                // (#cm-109) A row with a color draws a mark the way the Workspace Color menu draws its swatch.
                // (#cm-109.3) The mark is the glyph of the status, with his icon when it names one: it takes the dot's place.
                Label {
                    Text(title)
                } icon: {
                    HStack(spacing: 3) {
                        // (#cm-109) As the Workspace Color menu draws its check slot: hidden, not transparent.
                        if isSelected {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "checkmark").hidden()
                        }
                        Image(nsImage: WorkspaceStatusMenuImage.make( // (#cm-109.3)
                            status: status, icon: icon, colorHex: colorHex, isDark: colorScheme == .dark // (#cm-109.6)
                        )) // (#cm-109.3)
                    }
                }
            } else if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(!isEnabled) // (#cm-109) the greyed row cannot be chosen
    }
}

// MARK: - Command palette entries

/// Palette contributions and handlers for the workspace-todo actions. Split
/// out of `commandPaletteCommandContributions()` so the ContentView delta
/// stays a two-line append/register.
@MainActor
enum WorkspaceTodoPaletteCommands {
    static let markWorkspaceDoneCommandId = "palette.markWorkspaceDone"
    private static let statusAutoCommandId = "palette.workspaceStatusAuto"
    private static let addChecklistItemCommandId = "palette.addWorkspaceChecklistItem"
    private static let openTodoPaneCommandId = "palette.openWorkspaceTodoPane"

    /// The command palette's contributions. The status entries are one for each entry of `list` in the file's order
    /// (cmux's five when the list is cmux's own); `list` and `controlsEnabled` default to the app's, and a test passes
    /// its own. (#cm-109)
    static func contributions(
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        list: WorkspaceStatusList? = nil,
        controlsEnabled: Bool? = nil
    ) -> [CommandPaletteCommandContribution] {
        let list = list ?? AppDelegate.statusListInUse
        let hasWorkspace: (CommandPaletteContextSnapshot) -> Bool = {
            $0.bool(CommandPaletteContextKeys.hasWorkspace)
        }
        var contributions: [CommandPaletteCommandContribution] = []
        if controlsEnabled ?? WorkspaceTodoFeature.isEnabled {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: statusAutoCommandId,
                    title: { _ in
                        String(
                            localized: "command.workspaceStatusAuto.title",
                            defaultValue: "Workspace Status: Auto"
                        )
                    },
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "status", "todo", "auto", "inferred", "clear"],
                    when: hasWorkspace
                )
            )
            for entry in list.entries {
                contributions.append(
                    CommandPaletteCommandContribution(
                        commandId: WorkspaceStatusPresentation.paletteStatusCommandID(entry.id),
                        title: { _ in WorkspaceStatusPresentation.paletteStatusTitle(entry) },
                        subtitle: workspaceSubtitle,
                        keywords: ["workspace", "status", "todo", "lane", entry.id],
                        when: hasWorkspace
                    )
                )
            }
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: markWorkspaceDoneCommandId,
                    title: { _ in
                        String(
                            localized: "command.markWorkspaceDone.title",
                            defaultValue: "Mark Workspace as Done"
                        )
                    },
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "done", "complete", "finish", "todo", "status"],
                    when: hasWorkspace
                )
            )
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: addChecklistItemCommandId,
                    title: { _ in
                        String(
                            localized: "command.addWorkspaceChecklistItem.title",
                            defaultValue: "Add Checklist Item…"
                        )
                    },
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "checklist", "todo", "task", "add", "item"],
                    when: hasWorkspace
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: openTodoPaneCommandId,
                title: { _ in
                    String(
                        localized: "command.openWorkspaceTodoPane.title",
                        defaultValue: "Open Todo Pane"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "todo", "todos", "checklist", "pane", "open"],
                when: hasWorkspace
            )
        )
        return contributions
    }

    /// Registers the palette's handlers. `list`, `controlsEnabled` and `apply` default to the app's (the list in use,
    /// the status controls' gate, `WorkspaceTodoActions.applyStatusOverride`); a test passes its own. (#cm-109)
    static func registerHandlers(
        in registry: inout CommandPaletteHandlerRegistry,
        tabManager: TabManager,
        list: WorkspaceStatusList? = nil,
        controlsEnabled: Bool? = nil,
        apply: ((WorkspaceStatusPickAction, [Workspace]) -> Void)? = nil
    ) {
        let list = list ?? AppDelegate.statusListInUse
        let isEnabled: () -> Bool = { controlsEnabled ?? WorkspaceTodoFeature.isEnabled }
        let applyStatus: (WorkspaceStatusPickAction, [Workspace]) -> Void = apply ?? {
            WorkspaceTodoActions.applyStatusOverride($0, to: $1)
        }
        func withSelectedWorkspace(_ body: @escaping (Workspace) -> Void) -> () -> Void {
            {
                guard let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                body(workspace)
            }
        }
        registry.register(
            commandId: statusAutoCommandId,
            handler: withSelectedWorkspace { workspace in
                guard isEnabled() else {
                    NSSound.beep()
                    return
                }
                applyStatus(.auto, [workspace])
            }
        )
        for entry in list.entries {
            registry.register(
                commandId: WorkspaceStatusPresentation.paletteStatusCommandID(entry.id),
                handler: withSelectedWorkspace { workspace in
                    guard isEnabled() else {
                        NSSound.beep()
                        return
                    }
                    applyStatus(.status(id: entry.id), [workspace])
                }
            )
        }
        registry.register(
            commandId: markWorkspaceDoneCommandId,
            handler: withSelectedWorkspace { workspace in
                guard isEnabled() else {
                    NSSound.beep()
                    return
                }
                applyStatus(.done, [workspace])
            }
        )
        registry.register(
            commandId: addChecklistItemCommandId,
            handler: withSelectedWorkspace { workspace in
                guard WorkspaceTodoFeature.isEnabled else {
                    NSSound.beep()
                    return
                }
                WorkspaceTodoActions.requestChecklistAddField(workspaceId: workspace.id)
            }
        )
        registry.register(
            commandId: openTodoPaneCommandId,
            handler: withSelectedWorkspace { workspace in
                if WorkspaceTodoActions.openTodoPane(for: workspace) == nil {
                    NSSound.beep()
                }
            }
        )
    }
}
