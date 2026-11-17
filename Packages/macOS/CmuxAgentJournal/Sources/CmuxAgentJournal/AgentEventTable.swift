internal import Foundation

/// What a notification type means to cmux. (cm-124.5)
public enum AgentEventMeaning: String, Sendable, Equatable, CaseIterable {
    /// The agent asks a question: raises the hand.
    case question
    /// The agent waits for an approval: raises the hand.
    case approval
    /// A typed question was answered: retires the wait it raised.
    case resolved
    /// Informational: gives no banner and no hand.
    case ignore
    /// The agent is idle. Built-in only: a user's row cannot write it.
    case idle

    /// The words a user's row may write.
    public static let userWords: [AgentEventMeaning] = [.question, .approval, .resolved, .ignore]
}

/// One row of the table: an agent's slug (or `*`), a notification type, and what it means. (cm-124.5)
public struct AgentEventRow: Sendable, Equatable {
    /// An agent's slug, such as `claude`, or `*` for every agent.
    public let agent: String
    /// The type exactly as the agent sends it, such as `worker_permission_prompt`.
    public let notification: String
    /// What the next notification of that type does.
    public let means: AgentEventMeaning

    /// Creates a row.
    public init(agent: String, notification: String, means: AgentEventMeaning) {
        self.agent = agent
        self.notification = notification
        self.means = means
    }
}

/// Why one row of an edit was rejected. Carries the row's index, the rule and the bad value, never payload text.
public struct AgentEventRowIssue: Error, Sendable, Equatable {
    /// A field of a row.
    public enum Field: String, Sendable, Equatable {
        case agent, notification, means
    }

    /// The rule a row broke.
    public enum Rule: Sendable, Equatable {
        /// `agentEvents` is not a list.
        case notAList
        /// A row is not an object.
        case rowNotAnObject
        /// A field is missing or an empty string.
        case missingField(Field)
        /// A field is not text.
        case fieldNotText(Field)
        /// `means` is not one of the four words (`idle` included).
        case unknownMeaning
        /// A row holds a key other than `agent`, `notification` and `means`.
        case unknownKey
        /// A row repeats an earlier row's agent and notification.
        case duplicateRow(firstIndex: Int)
    }

    /// The row's index in the list; nil when the list itself is wrong.
    public let index: Int?
    /// The rule broken.
    public let rule: Rule
    /// The bad value, when the rule has one: the meaning word, the unknown key, the non-text value.
    public let value: String?

    /// Creates an issue.
    public init(index: Int?, rule: Rule, value: String? = nil) {
        self.index = index
        self.rule = rule
        self.value = value
    }
}

extension AgentEventRowIssue {
    /// The rule's stable name, for `cmux config doctor --json`.
    public var ruleName: String {
        switch rule {
        case .notAList: "notList"
        case .rowNotAnObject: "rowNotObject"
        case .missingField(let field): "missing" + field.rawValue.prefix(1).uppercased() + field.rawValue.dropFirst()
        case .fieldNotText: "notText"
        case .unknownMeaning: "badMeaning"
        case .unknownKey: "unknownKey"
        case .duplicateRow: "duplicateRow"
        }
    }

    /// The line `cmux config doctor` prints, in English: the row, the bad value and the fix. Never payload text.
    public var englishMessage: String {
        let row = index.map { "agentEvents[\($0)]" } ?? "agentEvents"
        switch rule {
        case .notAList:
            return "\(row): must be a list of rows"
        case .rowNotAnObject:
            return "\(row): a row must be an object"
        case .missingField(.agent):
            return "\(row): \"agent\" is missing; name one, such as \"claude\", or \"*\""
        case .missingField(.notification):
            return "\(row): \"notification\" is missing; name a type, such as \"idle_prompt\""
        case .missingField(.means):
            return "\(row): \"means\" is missing; use question, approval, resolved or ignore"
        case .fieldNotText(let field):
            let example = switch field {
            case .agent: "claude"
            case .notification: "idle_prompt"
            case .means: "ignore"
            }
            return "\(row): \"\(field.rawValue)\" must be text, such as \"\(example)\""
        case .unknownMeaning:
            return "\(row): means \"\(value ?? "")\": use question, approval, resolved or ignore"
        case .unknownKey:
            return "\(row): \"\(value ?? "")\" isn't a row key; a row has agent, notification, means"
        case .duplicateRow(let first):
            return "\(row): same agent and notification as agentEvents[\(first)]; keep one"
        }
    }
}

/// A valid row that cannot take effect, because its agent's notifications never reach the table. (cm-124.5)
public struct AgentEventRowWarning: Sendable, Equatable {
    /// The row's index in the list.
    public let index: Int
    /// The row's agent.
    public let agent: String

    /// Creates a warning.
    public init(index: Int, agent: String) {
        self.index = index
        self.agent = agent
    }

    /// The line `cmux config doctor` prints under the row's verdict, in English.
    public var englishMessage: String { "agentEvents[\(index)] does nothing: \(agent)'s notifications never reach it" }
}

/// What reading an `agentEvents` value produced. `rows` is empty whenever `issues` is not: an edit applies whole or not at all.
public struct AgentEventTableParse: Sendable, Equatable {
    /// The decoded rows of a valid edit.
    public let rows: [AgentEventRow]
    /// One issue per bad row, or one for a list that is not a list; empty when the edit is valid.
    public let issues: [AgentEventRowIssue]
    /// Valid rows that do nothing.
    public let warnings: [AgentEventRowWarning]
}

/// The built-in rows plus the user's rows, and the one validator for both the app and `cmux config doctor`. (cm-124.5)
///
/// His row beats a built-in row for the same agent and type; an exact agent beats `*`. The reconciler never reads this:
/// the CLI decides what a type means, and the reconciler decides only what the marker on the journal row allows.
public struct AgentEventTable: Sendable, Equatable {
    /// Agents whose notifications never reach the table: a row for one is valid and does nothing.
    public static let unreachableAgents: Set<String> = ["pi", "copilot", "codebuddy", "factory", "hermes-agent"]

    /// Every built-in row, all for `*`, because today's table is one table for every agent.
    public static let builtInRows: [AgentEventRow] = [
        .init(agent: "*", notification: "permission_prompt", means: .approval),
        .init(agent: "*", notification: "idle_prompt", means: .idle),
        .init(agent: "*", notification: "elicitation_dialog", means: .question),
        .init(agent: "*", notification: "elicitation_url_dialog", means: .question),
        .init(agent: "*", notification: "elicitation_response", means: .resolved),
        .init(agent: "*", notification: "elicitation_complete", means: .resolved),
        .init(agent: "*", notification: "push_notification", means: .ignore),
        .init(agent: "*", notification: "auth_success", means: .ignore),
        .init(agent: "*", notification: "agent_completed", means: .ignore),
        .init(agent: "*", notification: "quota_auto_resume_fired", means: .ignore),
        .init(agent: "*", notification: "quota_auto_resume_scheduled", means: .ignore),
        .init(agent: "*", notification: "quota_auto_resume_started", means: .ignore),
        .init(agent: "*", notification: "quota_auto_resume_stale", means: .ignore),
        .init(agent: "*", notification: "quota_auto_resume_disabled", means: .ignore),
        .init(agent: "*", notification: "computer_use_enter", means: .ignore),
        .init(agent: "*", notification: "computer_use_exit", means: .ignore),
    ]

    /// The table with no user rows; what a hook falls back to when the app cannot be reached.
    public static let builtIn = AgentEventTable()

    /// The user's rows, from the global `cmux.json`.
    public let userRows: [AgentEventRow]

    /// Creates a table over the built-in rows and the given user rows.
    public init(userRows: [AgentEventRow] = []) {
        self.userRows = userRows
    }

    /// What a type means for an agent.
    ///
    /// The order is his exact row, his `*` row, the built-in exact row, the built-in `*` row.
    /// - Returns: The meaning, or nil when no row maps the type.
    public func meaning(agent: String, notification: String) -> AgentEventMeaning? {
        resolve(agent: agent, notification: notification)?.means
    }

    /// The winning row's meaning, and whether it is one of his.
    func resolve(agent: String, notification: String) -> (means: AgentEventMeaning, fromUserRow: Bool)? {
        for (rows, fromUserRow) in [(userRows, true), (Self.builtInRows, false)] {
            for wanted in [agent, "*"] {
                if let row = rows.first(where: { $0.agent == wanted && $0.notification == notification }) {
                    return (row.means, fromUserRow)
                }
            }
        }
        return nil
    }

    private static let rowKeys: Set<String> = ["agent", "notification", "means"]

    /// Reads a decoded `agentEvents` value (the output of `JSONSerialization`), whole or not at all.
    ///
    /// - Parameter rawRows: The value under `agentEvents`; nil when the key is absent, which means no user rows.
    public static func parse(_ rawRows: Any?) -> AgentEventTableParse {
        guard let rawRows else { return AgentEventTableParse(rows: [], issues: [], warnings: []) }
        guard let list = rawRows as? [Any] else {
            return AgentEventTableParse(rows: [], issues: [.init(index: nil, rule: .notAList)], warnings: [])
        }
        var rows: [AgentEventRow] = []
        var issues: [AgentEventRowIssue] = []
        var warnings: [AgentEventRowWarning] = []
        var firstIndexByMatch: [String: Int] = [:]
        for (index, raw) in list.enumerated() {
            switch row(from: raw, index: index) {
            case .failure(let issue):
                issues.append(issue)
            case .success(let row):
                let match = "\(row.agent.utf8.count):\(row.agent)\(row.notification)"
                if let first = firstIndexByMatch[match] {
                    issues.append(.init(index: index, rule: .duplicateRow(firstIndex: first)))
                    continue
                }
                firstIndexByMatch[match] = index
                rows.append(row)
                if unreachableAgents.contains(row.agent) { warnings.append(.init(index: index, agent: row.agent)) }
            }
        }
        return AgentEventTableParse(rows: issues.isEmpty ? rows : [], issues: issues, warnings: warnings)
    }

    /// The issues of an `agentEvents` value; empty when it is valid.
    public static func validate(_ rawRows: Any?) -> [AgentEventRowIssue] {
        parse(rawRows).issues
    }

    /// Applies an edit: a valid one replaces the user rows, a bad one changes nothing.
    /// - Returns: The table now in force, and what reading the edit produced.
    public func applying(_ rawRows: Any?) -> (table: AgentEventTable, parse: AgentEventTableParse) {
        let parsed = Self.parse(rawRows)
        return (parsed.issues.isEmpty ? AgentEventTable(userRows: parsed.rows) : self, parsed)
    }

    private static func row(from raw: Any, index: Int) -> Result<AgentEventRow, AgentEventRowIssue> {
        guard let object = raw as? [String: Any] else {
            return .failure(.init(index: index, rule: .rowNotAnObject))
        }
        if let key = object.keys.filter({ !rowKeys.contains($0) }).sorted().first {
            return .failure(.init(index: index, rule: .unknownKey, value: key))
        }
        var text: [AgentEventRowIssue.Field: String] = [:]
        for field in [AgentEventRowIssue.Field.agent, .notification, .means] {
            guard let value = object[field.rawValue] else {
                return .failure(.init(index: index, rule: .missingField(field)))
            }
            guard let string = value as? String else {
                return .failure(.init(index: index, rule: .fieldNotText(field), value: describe(value)))
            }
            guard !string.isEmpty else { return .failure(.init(index: index, rule: .missingField(field))) }
            text[field] = string
        }
        guard let word = text[.means], let means = AgentEventMeaning.userWords.first(where: { $0.rawValue == word }),
              let agent = text[.agent], let notification = text[.notification] else {
            return .failure(.init(index: index, rule: .unknownMeaning, value: text[.means]))
        }
        return .success(AgentEventRow(agent: agent, notification: notification, means: means))
    }

    private static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if value is NSNull { return "null" }
        return String(String(describing: value).prefix(60))
    }
}

/// The marker a typed notification carries in a journal row's `detail`: `notification-type:<type>`. (cm-124.5)
///
/// The CLI writes it on an unmapped observation and on a typed question or answer, never on an `ignore`, `approval`
/// or `idle` row. A bare type would be ambiguous: `detail` on a state-changed row already holds restore suppression,
/// `cursor-shell-*`, `stale-turn-corrected`, `grok-internal-notification` and `approval-response`. Journal rows persist
/// and `cmux config doctor` counts from them, so the prefix never changes.
public enum AgentNotificationTypeMarker {
    /// The prefix of every marked `detail`.
    public static let prefix = "notification-type:"

    /// The marked `detail` for a type.
    public static func detail(forType type: String) -> String { prefix + type }

    /// The type a marked `detail` names; nil for an unmarked `detail`, a nil one, or a marker with no type.
    public static func type(inDetail detail: String?) -> String? {
        guard let detail, detail.hasPrefix(prefix) else { return nil }
        let type = String(detail.dropFirst(prefix.count))
        return type.isEmpty ? nil : type
    }
}

/// What a typed notification does, decided once from the table. (cm-124.5)
public struct AgentTypedNotificationDecision: Sendable, Equatable {
    /// The type as the agent sent it.
    public let type: String
    /// The row's meaning; nil when no row maps the type.
    public let meaning: AgentEventMeaning?
    /// The journal kind.
    public let kind: AgentJournalEventKind
    /// The `notification-type:<type>` marker for a `question`, a `resolved` and an unmapped type; nil otherwise.
    public let detail: String?
    /// Whether no row, built-in or his, maps the type.
    public var isUnmapped: Bool { meaning == nil }
    /// Whether one of HIS rows decided it, not a built-in row. A built-in row keeps today's behaviour exactly.
    public let isFromUserRow: Bool
}

extension AgentEventTable {
    /// Decides what an agent's typed notification means: the kind the journal row gets and the marker it carries.
    ///
    /// The marker goes on a `question`, a `resolved` and an unmapped type, never on an `ignore`, an `approval` or an
    /// `idle` row. An unmapped type is an observation: it raises nothing, and the reconciler pings it once.
    public func decide(agent: String, type: String) -> AgentTypedNotificationDecision {
        let resolved = resolve(agent: agent, notification: type)
        let meaning = resolved?.means
        let his = resolved?.fromUserRow ?? false
        let marker = AgentNotificationTypeMarker.detail(forType: type)
        switch meaning {
        case .question?: return .init(type: type, meaning: meaning, kind: .questionRequested, detail: marker, isFromUserRow: his)
        case .approval?: return .init(type: type, meaning: meaning, kind: .approvalRequested, detail: nil, isFromUserRow: his)
        case .resolved?: return .init(type: type, meaning: meaning, kind: .attentionResolved, detail: marker, isFromUserRow: his)
        case .ignore?: return .init(type: type, meaning: meaning, kind: .stateChanged, detail: nil, isFromUserRow: his)
        case .idle?: return .init(type: type, meaning: meaning, kind: .idleObserved, detail: nil, isFromUserRow: his)
        case nil: return .init(type: type, meaning: nil, kind: .stateChanged, detail: marker, isFromUserRow: false)
        }
    }
}
