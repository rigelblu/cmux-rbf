import CmuxAgentJournal
import Foundation
import CmuxFoundation

extension CMUXCLI {
    struct ConfigDoctorOptions {
        let paths: [String]
        let scope: CmuxConfigSemanticScope?
    }

    struct ConfigDoctorTarget {
        let label: String
        let displayPath: String
        let path: String
        let missingIsError: Bool
        let scope: CmuxConfigSemanticScope
    }

    struct ConfigDoctorFinding {
        let label: String
        let displayPath: String
        let path: String
        let status: String
        let message: String?
        let keys: [String]
        let byteCount: Int?
        let issues: [CmuxConfigSemanticIssue]
        /// The verdict on the `agentEvents` rows of the global file or a `--path` file. (#cm-124.5)
        var agentEvents: ConfigDoctorAgentEvents?
        /// A repo's own file holding `agentEvents`: cmux never reads rows from it. (#cm-124.5)
        var agentEventsIgnored = false

        init(
            label: String,
            displayPath: String,
            path: String,
            status: String,
            message: String?,
            keys: [String],
            byteCount: Int?,
            issues: [CmuxConfigSemanticIssue] = [],
            agentEvents: ConfigDoctorAgentEvents? = nil,
            agentEventsIgnored: Bool = false
        ) {
            self.label = label
            self.displayPath = displayPath
            self.path = path
            self.status = status
            self.message = message
            self.keys = keys
            self.byteCount = byteCount
            self.issues = issues
            self.agentEvents = agentEvents
            self.agentEventsIgnored = agentEventsIgnored
        }

        var isError: Bool { status == "error" }

        var payload: [String: Any] {
            var result: [String: Any] = [
                "label": label,
                "display_path": displayPath,
                "path": path,
                "status": status,
                "ok": !isError,
                "keys": keys,
            ]
            if let message {
                result["message"] = message
            }
            if let byteCount {
                result["bytes"] = byteCount
            }
            if !issues.isEmpty {
                result["issues"] = issues.map { ["path": $0.path, "message": $0.message] }
            }
            if let agentEvents {
                result["agent_events"] = agentEvents.payload // (#cm-124.5)
            }
            if agentEventsIgnored {
                result["agent_events_ignored"] = true // (#cm-124.5)
            }
            return result
        }

        /// The lines printed under the JSONC verdict, in order. (#cm-124.5)
        var agentEventsLines: [String] {
            if agentEventsIgnored {
                return ["agentEvents here is ignored; cmux reads rows only from ~/.config/cmux/cmux.json"]
            }
            guard let agentEvents else { return [] }
            if !agentEvents.issues.isEmpty {
                // (#cm-124.6) a valid row that does nothing still warns beside the bad ones (screen-designs/cm-124 render 15)
                return agentEvents.issues.map(\.englishMessage)
                    + agentEvents.warnings.map { "warning: " + $0.englishMessage }
                    + ["agentEvents: this edit isn't applied; cmux keeps the last valid rows"]
            }
            let summary = agentEvents.rows == 0
                ? "agentEvents: none; built-in rows only"
                : "agentEvents: \(agentEvents.rows) \(agentEvents.rows == 1 ? "row" : "rows"), valid"
            return [summary] + agentEvents.warnings.map { "warning: " + $0.englishMessage }
        }
    }

    /// What reading `agentEvents` gave, shared with the app's store through `AgentEventTable`. (#cm-124.5)
    struct ConfigDoctorAgentEvents {
        let rows: Int
        let issues: [AgentEventRowIssue]
        let warnings: [AgentEventRowWarning]

        var payload: [String: Any] {
            [
                "rows": rows,
                "valid": issues.isEmpty,
                "issues": issues.map { issue -> [String: Any] in
                    var item: [String: Any] = ["rule": issue.ruleName, "message": issue.englishMessage]
                    item["index"] = issue.index ?? NSNull()
                    item["value"] = issue.value ?? NSNull()
                    return item
                },
                "warnings": warnings.map { ["index": $0.index, "agent": $0.agent, "message": $0.englishMessage] },
            ]
        }
    }

    struct ConfigDoctorReport {
        let findings: [ConfigDoctorFinding]
        /// Types the running app recorded with no row; nil when it did not answer. (#cm-124.5)
        let unmappedTypes: [AgentUnmappedNotificationType]?

        var errorCount: Int {
            findings.filter(\.isError).count
        }

        var payload: [String: Any] {
            var result: [String: Any] = [
                "ok": errorCount == 0,
                "error_count": errorCount,
                "findings": findings.map(\.payload),
                "reload_command": "cmux reload-config",
                "docs_url": CMUXCLI.settingsDocsURL,
                "schema_url": CMUXCLI.settingsSchemaURL,
            ]
            // (#cm-124.5) null when no app answered
            if let unmappedTypes {
                result["unmapped_types"] = unmappedTypes.map {
                    ["agent": $0.agent, "type": $0.type, "count": $0.count, "last_seen_ms": $0.lastSeenMs]
                }
            } else {
                result["unmapped_types"] = NSNull()
            }
            return result
        }
    }

    func runConfigDoctor(
        arguments: [String],
        jsonOutput: Bool,
        commandName: String,
        socketPath: String?,
        explicitPassword: String?
    ) throws -> ConfigDoctorReport {
        let options = try parseConfigDoctorOptions(arguments, commandName: commandName)
        let targets = options.paths.isEmpty
            ? defaultConfigDoctorTargets()
            : options.paths.enumerated().map { index, rawPath in
                let path = Self.absoluteConfigPath(rawPath)
                return ConfigDoctorTarget(
                    label: "custom \(index + 1)",
                    displayPath: Self.tildePath(path),
                    path: path,
                    missingIsError: true,
                    scope: options.scope ?? configSemanticScope(for: path)
                )
            }
        let findings = targets.map(configDoctorFinding(for:))
        let report = ConfigDoctorReport(
            findings: findings,
            unmappedTypes: fetchUnmappedNotificationTypes(socketPath: socketPath, password: explicitPassword) // (#cm-124.5)
        )

        if jsonOutput {
            print(jsonString(report.payload))
        } else {
            printConfigDoctorReport(report, commandName: commandName)
        }
        return report
    }

    private func parseConfigDoctorOptions(
        _ arguments: [String],
        commandName: String
    ) throws -> ConfigDoctorOptions {
        var paths: [String] = []
        var scope: CmuxConfigSemanticScope?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--path" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw CLIError(
                        message: CmuxConfigValidationLocalization().format(
                            "config.validation.cli.pathRequired",
                            defaultValue: "cmux config %@ --path requires a path",
                            commandName
                        )
                    )
                }
                paths.append(arguments[nextIndex])
                index += 2
                continue
            }
            if argument.hasPrefix("--path=") {
                let rawPath = String(argument.dropFirst("--path=".count))
                guard !rawPath.isEmpty else {
                    throw CLIError(
                        message: CmuxConfigValidationLocalization().format(
                            "config.validation.cli.pathRequired",
                            defaultValue: "cmux config %@ --path requires a path",
                            commandName
                        )
                    )
                }
                paths.append(rawPath)
                index += 1
                continue
            }
            if argument == "--scope" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      let parsedScope = CmuxConfigSemanticScope(rawValue: arguments[nextIndex].lowercased()) else {
                    throw CLIError(
                        message: CmuxConfigValidationLocalization().format(
                            "config.validation.cli.scopeRequired",
                            defaultValue: "cmux config %@ --scope requires global or project",
                            commandName
                        )
                    )
                }
                scope = parsedScope
                index += 2
                continue
            }
            if argument.hasPrefix("--scope=") {
                let rawScope = String(argument.dropFirst("--scope=".count)).lowercased()
                guard let parsedScope = CmuxConfigSemanticScope(rawValue: rawScope) else {
                    throw CLIError(
                        message: CmuxConfigValidationLocalization().format(
                            "config.validation.cli.scopeRequired",
                            defaultValue: "cmux config %@ --scope requires global or project",
                            commandName
                        )
                    )
                }
                scope = parsedScope
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw CLIError(
                    message: CmuxConfigValidationLocalization().format(
                        "config.validation.cli.unknownOption",
                        defaultValue: "Unknown config %@ option '%@'",
                        commandName,
                        argument
                    )
                )
            }
            throw CLIError(
                message: CmuxConfigValidationLocalization().format(
                    "config.validation.cli.unknownArgument",
                    defaultValue: "Unknown config %@ argument '%@'. Use --path <path>.",
                    commandName,
                    argument
                )
            )
        }
        return ConfigDoctorOptions(paths: paths, scope: scope)
    }

    private func defaultConfigDoctorTargets() -> [ConfigDoctorTarget] {
        let primary = Self.absoluteConfigPath(Self.primarySettingsDisplayPath)
        var targets = [
            ConfigDoctorTarget(
                label: "primary",
                displayPath: Self.primarySettingsDisplayPath,
                path: primary,
                missingIsError: false,
                scope: .global
            )
        ]

        if let projectPath = findProjectConfigPath(), projectPath != primary {
            targets.append(
                ConfigDoctorTarget(
                    label: "project",
                    displayPath: Self.tildePath(projectPath),
                    path: projectPath,
                    missingIsError: false,
                    scope: .project
                )
            )
        }

        let optionalPaths = [
            ("legacy config", Self.legacySettingsDisplayPath),
            ("legacy app support", Self.fallbackSettingsDisplayPath),
        ]
        for (label, displayPath) in optionalPaths {
            let path = Self.absoluteConfigPath(displayPath)
            guard path != primary,
                  FileManager.default.fileExists(atPath: path),
                  !targets.contains(where: { $0.path == path }) else {
                continue
            }
            targets.append(
                ConfigDoctorTarget(
                    label: label,
                    displayPath: displayPath,
                    path: path,
                    missingIsError: false,
                    scope: .global
                )
            )
        }
        return targets
    }

    private func findProjectConfigPath() -> String? {
        let fileManager = FileManager.default
        let rawHomePath = ProcessInfo.processInfo.environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let homePath = URL(fileURLWithPath: rawHomePath).standardizedFileURL.path
        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL.path
        while true {
            if current == homePath {
                return nil
            }
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            for candidate in candidates {
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return URL(fileURLWithPath: candidate).standardizedFileURL.path
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                return nil
            }
            current = parent
        }
    }

    private func configDoctorFinding(for target: ConfigDoctorTarget) -> ConfigDoctorFinding {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            let message = target.missingIsError
                ? CmuxConfigValidationLocalization().string(
                    "config.validation.cli.doctor.fileNotFound",
                    defaultValue: "file not found"
                )
                : CmuxConfigValidationLocalization().string(
                    "config.validation.cli.doctor.missingDefaults",
                    defaultValue: "not found; cmux will use defaults until this file exists"
                )
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: target.missingIsError ? "error" : "missing",
                message: message,
                keys: [],
                byteCount: nil
            )
        }
        if isDirectory.boolValue {
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: "error",
                message: CmuxConfigValidationLocalization().string(
                    "config.validation.cli.doctor.pathIsDirectory",
                    defaultValue: "path is a directory, expected a file"
                ),
                keys: [],
                byteCount: nil
            )
        }

        var loadedData: Data?
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.path))
            loadedData = data
            guard !data.isEmpty else {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: CmuxConfigValidationLocalization().string(
                        "config.validation.cli.doctor.fileEmpty",
                        defaultValue: "file is empty"
                    ),
                    keys: [],
                    byteCount: 0
                )
            }
            let sanitized = try JSONCParser.preprocess(data: data)
            loadedData = sanitized
            let object = try JSONSerialization.jsonObject(with: sanitized)
            guard let dictionary = object as? [String: Any] else {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: CmuxConfigValidationLocalization().string(
                        "config.validation.cli.doctor.topLevelObject",
                        defaultValue: "top-level value must be a JSON object"
                    ),
                    keys: [],
                    byteCount: data.count
                )
            }
            var agentEvents: ConfigDoctorAgentEvents?
            var agentEventsIgnored = false
            if target.label == "primary" || target.label.hasPrefix("custom") {
                // (#cm-124.5) The same validator the app's store uses; a bad row makes the finding an error.
                let parsed = AgentEventTable.parse(dictionary["agentEvents"])
                agentEvents = ConfigDoctorAgentEvents(rows: parsed.rows.count, issues: parsed.issues, warnings: parsed.warnings)
            } else if target.label == "project", dictionary["agentEvents"] != nil {
                agentEventsIgnored = true
            }
            let validator = CmuxConfigSemanticValidator(scope: target.scope)
            let issues = try validator.validate(jsonData: sanitized)
            if !issues.isEmpty {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: CmuxConfigValidationLocalization().string(
                        "config.validation.cli.failed",
                        defaultValue: "semantic validation failed"
                    ),
                    keys: dictionary.keys.sorted(),
                    byteCount: data.count,
                    issues: issues,
                    agentEvents: agentEvents,
                    agentEventsIgnored: agentEventsIgnored
                )
            }
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: agentEvents?.issues.isEmpty == false ? "error" : "ok",
                message: CmuxConfigValidationLocalization().string(
                    "config.validation.cli.passed",
                    defaultValue: "JSONC syntax and semantic validation passed"
                ),
                keys: dictionary.keys.sorted(),
                byteCount: data.count,
                agentEvents: agentEvents,
                agentEventsIgnored: agentEventsIgnored
            )
        } catch {
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: "error",
                message: Self.configDoctorErrorMessage(
                    error,
                    data: loadedData,
                    displayPath: target.displayPath
                ),
                keys: [],
                byteCount: nil
            )
        }
    }

    private func printConfigDoctorReport(_ report: ConfigDoctorReport, commandName: String) {
        let localization = CmuxConfigValidationLocalization()
        let pathLabel = localization.string(
            "config.validation.cli.doctor.report.path",
            defaultValue: "path"
        )
        let bytesLabel = localization.string(
            "config.validation.cli.doctor.report.bytes",
            defaultValue: "bytes"
        )
        let keysLabel = localization.string(
            "config.validation.cli.doctor.report.keys",
            defaultValue: "keys"
        )
        print("cmux config \(commandName)")
        for finding in report.findings {
            let status = Self.localizedConfigDoctorStatus(finding.status)
            let label = Self.localizedConfigDoctorLabel(finding.label)
            print("\(status) \(label): \(finding.displayPath)")
            print("  \(pathLabel): \(finding.path)")
            if let byteCount = finding.byteCount {
                print("  \(bytesLabel): \(byteCount)")
            }
            if !finding.keys.isEmpty {
                print("  \(keysLabel): \(finding.keys.joined(separator: ", "))")
            }
            if let message = finding.message {
                print("  \(message)")
            }
            for issue in finding.issues {
                print("  \(issue.path): \(issue.message)")
            }
            for line in finding.agentEventsLines { // (#cm-124.5)
                print("  \(line)")
            }
        }
        print()
        for line in unmappedTypesLines(report.unmappedTypes) { // (#cm-124.5)
            print(line)
        }
        print()
        let docsLabel = localization.string(
            "config.validation.cli.doctor.report.docs",
            defaultValue: "Docs"
        )
        let schemaLabel = localization.string(
            "config.validation.cli.doctor.report.schema",
            defaultValue: "Schema"
        )
        let reloadLabel = localization.string(
            "config.validation.cli.doctor.report.reload",
            defaultValue: "Reload"
        )
        print("\(docsLabel): \(Self.settingsDocsURL)")
        print("\(schemaLabel): \(Self.settingsSchemaURL)")
        print("\(reloadLabel): cmux reload-config")
    }

    /// Asks the running app for the types it recorded with no row. One connection of its own, bounded at 2 s; nil when the app
    /// is not running, does not answer in time, or does not know the method. Doctor needs no socket without it. (#cm-124.5)
    private func fetchUnmappedNotificationTypes(socketPath: String?, password: String?) -> [AgentUnmappedNotificationType]? {
        guard let socketPath else { return nil }
        let bound: TimeInterval = 2
        let deadline = Date().addingTimeInterval(bound)
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        guard (try? client.connect(deadline: deadline)) != nil,
              (try? authenticateClientIfNeeded(
                  client, explicitPassword: password, socketPath: socketPath, responseTimeout: bound, deadline: deadline
              )) != nil,
              let payload = try? client.sendV2(
                  method: "agent_events.unmapped_types", responseTimeout: bound, deadline: deadline
              ),
              let types = payload["types"] as? [[String: Any]] else {
            return nil
        }
        return types.compactMap { item in
            guard let agent = item["agent"] as? String, let type = item["type"] as? String,
                  let count = (item["count"] as? NSNumber)?.intValue,
                  let lastSeenMs = (item["last_seen_ms"] as? NSNumber)?.int64Value else { return nil }
            return AgentUnmappedNotificationType(agent: agent, type: type, count: count, lastSeenMs: lastSeenMs)
        }
    }

    /// The doctor's block for the unmapped types: a padded list, newest first, then a row to paste. (#cm-124.5)
    private func unmappedTypesLines(_ types: [AgentUnmappedNotificationType]?) -> [String] {
        let heading = "Notification types with no row"
        guard let types else { return ["\(heading): cmux didn't answer, so this list isn't available"] }
        guard !types.isEmpty else { return ["\(heading): none seen"] }
        let sorted = types.sorted { $0.lastSeenMs > $1.lastSeenMs }
        let agentWidth = sorted.map(\.agent.count).max() ?? 0
        let typeWidth = sorted.map(\.type.count).max() ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["\(heading):"]
        for item in sorted {
            let agent = item.agent.padding(toLength: agentWidth, withPad: " ", startingAt: 0)
            let type = item.type.padding(toLength: typeWidth, withPad: " ", startingAt: 0)
            let seen = formatter.string(from: Date(timeIntervalSince1970: Double(item.lastSeenMs) / 1000))
            lines.append("  \(agent)  \(type)  \(item.count) \(item.count == 1 ? "time" : "times"), last seen \(seen)")
        }
        lines.append("To map one, add this under agentEvents in ~/.config/cmux/cmux.json:")
        let first = sorted[0]
        lines.append("{ \"agent\": \"\(first.agent)\", \"notification\": \"\(first.type)\", \"means\": \"question\" }")
        return lines
    }

    /// The rows in the global `~/.config/cmux/cmux.json`, read by the hook itself through doctor's parse; no socket call.
    /// No file, an unreadable or bad one gives the built-in table, so a hook never fails on the file. (#cm-124.6)
    static func agentEventTableFromGlobalFile() -> AgentEventTable {
        let path = absoluteConfigPath(primarySettingsDisplayPath)
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let object = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            return .builtIn
        }
        let parsed = AgentEventTable.parse(object["agentEvents"])
        return parsed.issues.isEmpty ? AgentEventTable(userRows: parsed.rows) : .builtIn
    }

    private static func localizedConfigDoctorStatus(_ status: String) -> String {
        let localization = CmuxConfigValidationLocalization()
        switch status {
        case "ok":
            return localization.string(
                "config.validation.cli.doctor.status.ok",
                defaultValue: "OK"
            )
        case "error":
            return localization.string(
                "config.validation.cli.doctor.status.error",
                defaultValue: "ERROR"
            )
        case "missing":
            return localization.string(
                "config.validation.cli.doctor.status.missing",
                defaultValue: "MISSING"
            )
        default:
            return status.uppercased()
        }
    }

    private static func localizedConfigDoctorLabel(_ label: String) -> String {
        let localization = CmuxConfigValidationLocalization()
        switch label {
        case "primary":
            return localization.string(
                "config.validation.cli.doctor.label.primary",
                defaultValue: "primary"
            )
        case "project":
            return localization.string(
                "config.validation.cli.doctor.label.project",
                defaultValue: "project"
            )
        case "legacy config":
            return localization.string(
                "config.validation.cli.doctor.label.legacyConfig",
                defaultValue: "legacy config"
            )
        case "legacy app support":
            return localization.string(
                "config.validation.cli.doctor.label.legacyAppSupport",
                defaultValue: "legacy app support"
            )
        default:
            guard label.hasPrefix("custom ") else { return label }
            let suffix = String(label.dropFirst("custom ".count))
            return localization.format(
                "config.validation.cli.doctor.label.custom",
                defaultValue: "custom %@",
                suffix
            )
        }
    }

    private func configSemanticScope(for path: String) -> CmuxConfigSemanticScope {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let globalPaths = [
            Self.primarySettingsDisplayPath,
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteConfigPath)
        if globalPaths.contains(normalized) {
            return .global
        }
        if let projectPath = findProjectConfigPath(),
           URL(fileURLWithPath: projectPath).standardizedFileURL.path == normalized {
            return .project
        }
        let parent = (normalized as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == ".cmux" {
            return .project
        }
        return .global
    }

    private static func absoluteConfigPath(_ rawPath: String) -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let expanded: String
        if rawPath == "~" {
            expanded = homePath
        } else if rawPath.hasPrefix("~/") {
            expanded = (homePath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else {
            expanded = rawPath
        }

        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    static func tildePath(_ path: String) -> String {
        let homePath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            .standardizedFileURL
            .path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == homePath {
            return "~"
        }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        if normalized.hasPrefix(prefix) {
            return "~/" + String(normalized.dropFirst(prefix.count))
        }
        return normalized
    }

    static func configDoctorErrorMessage(
        _ error: Error,
        data: Data? = nil,
        displayPath: String? = nil
    ) -> String {
        let nsError = error as NSError
        if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
            let trimmed = debug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Self.configDoctorLocationPrefix(error: error, data: data, displayPath: displayPath)
                    + trimmed
            }
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return Self.configDoctorLocationPrefix(error: error, data: data, displayPath: displayPath)
                + described
        }
        let localized = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            return Self.configDoctorLocationPrefix(error: error, data: data, displayPath: displayPath)
                + localized
        }
        return Self.configDoctorLocationPrefix(error: error, data: data, displayPath: displayPath)
            + CmuxConfigValidationLocalization().string(
            "config.validation.cli.doctor.unknownParseError",
            defaultValue: "unknown config parse error"
        )
    }

    private static func configDoctorLocationPrefix(
        error: Error,
        data: Data?,
        displayPath: String?
    ) -> String {
        guard let displayPath else { return "" }
        let line: Int
        if let data {
            let errorIndex = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int ?? 0
            let bounded = min(max(errorIndex, 0), data.count)
            line = data.prefix(bounded).reduce(into: 1) { count, byte in
                if byte == 0x0A { count += 1 }
            }
        } else {
            line = 1
        }
        return "\(displayPath):\(line): "
    }

}
