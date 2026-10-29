import Foundation

extension CMUXCLI {
    static let claudeEditorModePayloadKey = "_cmux_claude_editor_mode"

    /// Captures settings where Claude runs, before relay replay loses filesystem context.
    func captureClaudeEditorMode(_ rawPayload: String, agent: String, subcommand: String,
                                 environment: [String: String]) -> String {
        guard agent == "claude", subcommand == "session-start" else { return rawPayload }
        return injecting(Self.claudeEditorModePayloadKey, { _ in
            claudeEditorMode(cwd: parseClaudeHookInput(rawInput: rawPayload).cwd, environment: environment)
        }, into: rawPayload)
    }

    /// Adds one string field, computed from the parsed object, to a JSON-object hook payload before queue admission
    /// compacts it. A payload that isn't an object, or a value that comes out nil, leaves the payload unchanged. (cm-128.1)
    func injecting(_ key: String, _ value: ([String: Any]) -> String?, into rawPayload: String) -> String {
        guard let data = rawPayload.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let injected = value(object) else { return rawPayload }
        object[key] = injected
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return rawPayload }
        return String(decoding: encoded, as: UTF8.self)
    }

    func claudeEditorMode(cwd: String?, environment: [String: String]) -> String {
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var files = [home.appendingPathComponent(".claude.json"), config.appendingPathComponent("settings.json")]
        if let cwd {
            let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
            files += [project.appendingPathComponent("settings.json"), project.appendingPathComponent("settings.local.json")]
        }
        var mode = "default"
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["editorMode"] as? String else { continue }
            mode = value
        }
        return mode
    }
}
