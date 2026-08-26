public import Foundation

/// Localized editor schema materialized beside the dedicated definitions file.
public enum RestartCommandSchema {
    public static func materializedData() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "restart-commands.schema.template",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        var source = String(data: data, encoding: .utf8) else {
            return nil
        }
        let replacements: [String: String] = [
            "__TITLE__": String(
                localized: "restartCommands.schema.title",
                defaultValue: "cmux restart commands"
            ),
            "__ROOT_DESCRIPTION__": String(
                localized: "restartCommands.schema.description",
                defaultValue: "Approved command definitions cmux may restart in restored local terminal panes."
            ),
            "__MATCH_DESCRIPTION__": String(
                localized: "restartCommands.schema.match.description",
                defaultValue: "Process evidence required while cmux saves the pane."
            ),
            "__COMMAND_DESCRIPTION__": String(
                localized: "restartCommands.schema.command.description",
                defaultValue: "Canonical command cmux starts after restoring an eligible pane. Maximum 1,000 UTF-8 bytes."
            ),
            "__CWD_DESCRIPTION__": String(
                localized: "restartCommands.schema.cwd.description",
                defaultValue: "Run the canonical command in the pane’s saved local working directory."
            ),
        ]
        for (token, value) in replacements {
            source = source.replacingOccurrences(
                of: token,
                with: escapedJSONStringContent(value)
            )
        }
        guard let result = source.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: result)) != nil else {
            return nil
        }
        return result
    }

    private static func escapedJSONStringContent(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let source = String(data: data, encoding: .utf8),
              source.count >= 4 else {
            return ""
        }
        return String(source.dropFirst(2).dropLast(2))
    }
}
