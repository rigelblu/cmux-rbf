import Foundation

/// `cmux workspace-color` (`#cm-11`) — read-only discovery of the effective workspace
/// color palette.
///
/// The noun is `workspace-color`, not the shorter `color`, because cmux also has terminal
/// colors and theme colors; four extra characters cost less than the ambiguity. Modelled
/// on the global `layout` noun.
///
/// There are deliberately no mutating verbs. Labels are edited in Settings and
/// `cmux.json` only, so cmux keeps one durable owner of what a color means — adding
/// `workspace-color set-label` here would create a second.
extension CMUXCLI {
    static func workspaceColorHelpText() -> String {
        """
        Usage: cmux workspace-color <subcommand> [flags]

        Inspect the workspace color palette and the labels layered over it.

        Subcommands:
          list [--json]    Every effective palette entry: name, label, display name, hex

        Assignment lives on the workspace: any of the three columns below is accepted
        wherever a color is, so `set-color` takes a label, a raw name, or a hex.

        Examples:
          cmux workspace-color list
          cmux workspace-color list --json
          cmux workspace-action set-color "GOAL: Primary"
          cmux workspace-action set-color Teal
          cmux workspace-action set-color '#006B6B'
          cmux workspace-action clear-color        # the automation spelling of No Color

        Labels are edited in Settings → Workspace Colors, or in cmux.json under
        `workspaceColors.labels`. This command never writes.
        """
    }

    func runWorkspaceColorNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "workspace-color requires a subcommand. Try: list")
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "list":
            try runWorkspaceColorList(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "Unknown workspace-color subcommand: \(subcommand). Try: list")
        }
    }

    private func runWorkspaceColorList(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "workspace-color list: unknown flag '\(unknown)'")
        }
        let effectiveJSONOutput = jsonOutput || hasFlag(commandArgs, name: "--json")
        let payload = try client.sendV2(method: "workspace.color.list")
        if effectiveJSONOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let colors = payload["colors"] as? [[String: Any]] ?? []
        if colors.isEmpty {
            print("No workspace colors")
            return
        }
        print("NAME\tLABEL\tDISPLAY NAME\tHEX")
        for color in colors {
            let name = color["name"] as? String ?? ""
            // An absent label prints empty rather than repeating the name, so the
            // tab-separated output stays diffable and a reader can see which entries
            // carry meaning.
            let label = color["label"] as? String ?? ""
            let displayName = color["display_name"] as? String ?? name
            let hex = color["hex"] as? String ?? ""
            print("\(name)\t\(label)\t\(displayName)\t\(hex)")
        }
    }
}
