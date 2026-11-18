import CmuxAgentJournal
import CmuxFoundation
import Combine
import Foundation
import os

/// The app's one copy of the agent event table: the built-in rows plus the rows in the global `~/.config/cmux/cmux.json`.
///
/// cmux-rbf (#cm-124.5). `CmuxConfigStore` can't own it, because the app makes one per window, each with its own watcher.
/// This store keeps one watcher on the global file, reads only `agentEvents`, applies an edit whole or not at all, keeps the
/// last valid rows when an edit is bad, and answers the two socket methods a hook process and `cmux config doctor` ask.
/// Rows come from the global file only: a repo's own `.cmux/cmux.json` is never read here.
///
/// Concurrency: the live table is an immutable value behind a lock, so the socket worker reads it without hopping to the
/// main actor; the watcher task swaps it on the main actor.
final class AgentEventTableStore: @unchecked Sendable {
    /// The app-wide store. A test seam: tests swap it for one over a temporary file.
    nonisolated(unsafe) static var shared = AgentEventTableStore()

    /// What reading the file produced: the table now in force and one issue per bad row.
    struct Evaluation: Equatable {
        let table: AgentEventTable
        let issues: [CmuxConfigIssue]
    }

    /// The global file this store reads.
    let path: String

    private let live = OSAllocatedUnfairLock<AgentEventTable>(initialState: .builtIn)
    private let recordedUnmappedTypes: @Sendable () -> [AgentUnmappedNotificationType]?
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?

    /// The issues of the last edit, one per bad row, for every window's palette. Written on the main actor only.
    let issues = CurrentValueSubject<[CmuxConfigIssue], Never>([])

    /// - Parameters:
    ///   - path: The global `cmux.json`.
    ///   - recordedUnmappedTypes: The types the journal recorded with no row; nil when the journal is unavailable.
    init(
        path: String = CmuxConfigStore.defaultGlobalConfigPath(),
        recordedUnmappedTypes: @escaping @Sendable () -> [AgentUnmappedNotificationType]? = {
            AgentJournalLifecycleCenter.shared.recordedUnmappedNotificationTypes()
        }
    ) {
        self.path = path
        self.recordedUnmappedTypes = recordedUnmappedTypes
    }

    deinit {
        watchTask?.cancel()
    }

    /// The table in force. Safe from any thread.
    var table: AgentEventTable { live.withLock { $0 } }

    // MARK: Reading the file

    /// Reads the file's `agentEvents` against the table in force.
    ///
    /// No file, or an empty one, means no rows of his. A file that won't parse, or a top level that isn't an object, keeps
    /// the table in force and reports nothing: `CmuxConfigStore` already shows that error. A bad `agentEvents` keeps it
    /// too, and reports one issue per bad row. An app started with a bad file runs on the built-in rows, because the table
    /// in force at launch is the built-in one.
    nonisolated static func evaluate(data: Data?, path: String, previous: AgentEventTable) -> Evaluation {
        guard let data, !data.isEmpty else { return Evaluation(table: .builtIn, issues: []) }
        guard let sanitized = try? JSONCParser.preprocess(data: data),
              let object = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            return Evaluation(table: previous, issues: [])
        }
        let applied = previous.applying(object["agentEvents"])
        return Evaluation(
            table: applied.table,
            issues: applied.parse.issues.map { Self.configIssue($0, path: path) }
        )
    }

    /// One palette issue per bad row. `settingName` is the row (`agentEvents[1]`), `message` the rule, `commandName` the
    /// bad value, the field or the first row a duplicate repeats.
    nonisolated static func configIssue(_ issue: AgentEventRowIssue, path: String) -> CmuxConfigIssue {
        let setting = issue.index.map { "agentEvents[\($0)]" } ?? "agentEvents"
        let rule: String
        var detail = issue.value
        switch issue.rule {
        case .notAList: rule = "notList"
        case .rowNotAnObject: rule = "rowNotObject"
        case .missingField(let field):
            switch field {
            case .agent: rule = "missingAgent"
            case .notification: rule = "missingNotification"
            case .tool: rule = "missingTool" // (#cm-124.6)
            case .means: rule = "missingMeans"
            }
        case .fieldNotText(let field):
            rule = "notText"
            detail = field.rawValue
        case .unknownMeaning: rule = "badMeaning"
        case .bothMatchKeys: rule = "bothMatchKeys" // (#cm-124.6)
        case .noMatchKey: rule = "noMatchKey" // (#cm-124.6)
        case .meaningNotForTool: rule = "badToolMeaning" // (#cm-124.6)
        case .missingToolMeans: rule = "missingToolMeans" // (#cm-124.6)
        case .duplicateToolRow(let first): // (#cm-124.6)
            rule = "duplicateToolRow"
            detail = String(first)
        case .unknownKey: rule = "unknownKey"
        case .duplicateRow(let first):
            rule = "duplicateRow"
            detail = String(first)
        }
        return CmuxConfigIssue(
            kind: .agentEventsRow, settingName: setting, commandName: detail, sourcePath: path, message: rule
        )
    }

    /// The palette's one line for a bad row, localized. (#cm-124.5)
    static func paletteDetail(_ issue: CmuxConfigIssue) -> String {
        let row = issue.settingName
        let value = issue.commandName ?? ""
        switch issue.message {
        case "badMeaning":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.badMeaning.detail",
                defaultValue: "%@: means \"%@\": use question, approval, resolved or ignore"), row, value)
        case "badToolMeaning": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.badToolMeaning.detail",
                defaultValue: "%@: means \"%@\" on a tool row: use question or plan-review"), row, value)
        case "bothMatchKeys": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.bothMatchKeys.detail",
                defaultValue: "%@: a row has \"notification\" or \"tool\", not both"), row)
        case "duplicateToolRow": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.duplicateToolRow.detail",
                defaultValue: "%@: same agent and tool as agentEvents[%@]; keep one"), row, value)
        case "missingTool": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.missingTool.detail",
                defaultValue: "%@: \"tool\" is missing; name a Claude tool, like \"AskUserQuestion\""), row)
        case "missingToolMeans": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.missingToolMeans.detail",
                defaultValue: "%@: \"means\" is missing; use question or plan-review"), row)
        case "noMatchKey": // (#cm-124.6)
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.noMatchKey.detail",
                defaultValue: "%@: a row needs \"notification\" (a type) or \"tool\" (a Claude tool)"), row)
        case "duplicateRow":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.duplicateRow.detail",
                defaultValue: "%@: same agent and notification as agentEvents[%@]; keep one"), row, value)
        case "missingAgent":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.missingAgent.detail",
                defaultValue: "%@: \"agent\" is missing; name one, such as \"claude\", or \"*\""), row)
        case "missingMeans":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.missingMeans.detail",
                defaultValue: "%@: \"means\" is missing; use question, approval, resolved or ignore"), row)
        case "missingNotification":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.missingNotification.detail",
                defaultValue: "%@: \"notification\" is missing; name a type, such as \"idle_prompt\""), row)
        case "notList":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.notList.detail",
                defaultValue: "%@: must be a list of rows"), row)
        case "notText":
            let example = ["agent": "claude", "notification": "idle_prompt", "tool": "AskUserQuestion", "means": "ignore"][value] ?? "claude" // (#cm-124.6) tool
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.notText.detail",
                defaultValue: "%@: \"%@\" must be text, such as \"%@\""), row, value, example)
        case "rowNotObject":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.rowNotObject.detail",
                defaultValue: "%@: a row must be an object"), row)
        case "unknownKey":
            return String(format: String(localized: "command.cmuxConfig.issue.agentEvents.unknownKey.detail",
                defaultValue: "%@: \"%@\" is not a key: use agent, notification or tool, means"), row, value) // (#cm-124.6)
        default:
            return row
        }
    }

    // MARK: Watching the file

    /// Reads the file now and on every change. Idempotent.
    @MainActor
    func start() {
        stop()
        reload()
        let watcher = FileWatcher(path: path)
        self.watcher = watcher
        let events = watcher.events
        watchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.reload()
            }
        }
    }

    @MainActor
    func stop() {
        watchTask?.cancel()
        watchTask = nil
        watcher = nil
    }

    /// Applies the file's current `agentEvents`: swaps the live table and publishes the issues. Takes effect on the next
    /// notification, with no relaunch.
    @MainActor
    func reload() {
        let evaluation = Self.evaluate(
            data: FileManager.default.contents(atPath: path), path: path, previous: table
        )
        live.withLock { $0 = evaluation.table }
        if issues.value != evaluation.issues { issues.send(evaluation.issues) }
    }

    // MARK: The two socket methods

    /// `agent_events.rows`: his rows. The built-in rows live in code, so a hook adds them itself.
    nonisolated func rowsPayload() -> [String: Any] {
        // (#cm-124.6) a tool row carries `tool` in place of `notification`
        ["rows": table.userRows.map { row -> [String: String] in
            var object = ["agent": row.agent, "means": row.means.rawValue]
            if let notification = row.notification { object["notification"] = notification }
            if let tool = row.tool { object["tool"] = tool }
            return object
        }]
    }

    /// `agent_events.unmapped_types`: every type the journal recorded that no row maps now, with agent, count and last seen.
    /// Never a notification's text. Nil when the journal is unavailable.
    nonisolated func unmappedTypesPayload() -> [String: Any]? {
        guard let recorded = recordedUnmappedTypes() else { return nil }
        let types: [[String: Any]] = table.unmapped(recorded).map {
            ["agent": $0.agent, "type": $0.type, "count": $0.count, "last_seen_ms": $0.lastSeenMs]
        }
        return ["types": types]
    }
}
