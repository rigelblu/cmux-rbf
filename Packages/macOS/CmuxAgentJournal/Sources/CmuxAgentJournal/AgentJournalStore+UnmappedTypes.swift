public import Foundation
internal import SQLite3

/// A notification type an agent sent that no row mapped, as the journal recorded it. (cm-124.5)
///
/// Carries the agent, the type, how many notifications came and when the last one did, never a notification's text.
public struct AgentUnmappedNotificationType: Sendable, Equatable {
    /// The agent's slug, such as `claude`.
    public let agent: String
    /// The type exactly as the agent sent it.
    public let type: String
    /// How many notifications of that type came: one per hook event, not per journal row.
    public let count: Int
    /// When the last one was journaled, in milliseconds since 1970.
    public let lastSeenMs: Int64

    /// Creates a record.
    public init(agent: String, type: String, count: Int, lastSeenMs: Int64) {
        self.agent = agent
        self.type = type
        self.count = count
        self.lastSeenMs = lastSeenMs
    }
}

extension AgentJournalStore {
    /// Every type an agent sent with the `notification-type:` marker, grouped by agent and type, newest first.
    ///
    /// Counts the state-changed rows that carry the marker and have no notification in their attention context. A hook
    /// event writes two such rows when it has a body, the CLI's emit row and the banner row, and only the emit row has no
    /// notification, so the count is one per hook event. A type a row later maps is not filtered here; see
    /// ``AgentEventTable/unmapped(_:)``.
    ///
    /// - Throws: A storage error.
    public func unmappedNotificationTypes() throws -> [AgentUnmappedNotificationType] {
        let prefix = AgentNotificationTypeMarker.prefix
        let skip = prefix.utf8.count + 1
        return try withDatabase { database in
            let statement = try database.prepare(
                """
                SELECT j.source, substr(j.detail, \(skip)) AS type, COUNT(*), MAX(j.committed_at_ms) AS last_seen
                FROM agent_journal j
                LEFT JOIN agent_attention_context a ON a.event_id = j.event_id
                WHERE j.kind = ?1
                  AND substr(j.detail, 1, \(prefix.utf8.count)) = ?2
                  AND length(j.detail) > \(prefix.utf8.count)
                  AND (a.context IS NULL OR json_extract(a.context, '$.notification') IS NULL)
                GROUP BY j.source, type
                ORDER BY last_seen DESC, j.source ASC, type ASC;
                """
            )
            defer { sqlite3_finalize(statement) }
            try database.bind(statement: statement, parameters: [
                .text(AgentJournalEventKind.stateChanged.rawValue),
                .text(prefix),
            ])
            var found: [AgentUnmappedNotificationType] = []
            while database.step(statement) == SQLITE_ROW {
                guard let agent = database.columnText(statement, 0),
                      let type = database.columnText(statement, 1) else { continue }
                found.append(AgentUnmappedNotificationType(
                    agent: agent,
                    type: type,
                    count: Int(database.columnInt64(statement, 2)),
                    lastSeenMs: database.columnInt64(statement, 3)
                ))
            }
            return found
        }
    }
}

extension AgentEventTable {
    /// The recorded types no row in this table maps, in the order given: built-in `ignore` rows and his rows both take a
    /// type off the list. (cm-124.5)
    public func unmapped(_ recorded: [AgentUnmappedNotificationType]) -> [AgentUnmappedNotificationType] {
        recorded.filter { meaning(agent: $0.agent, notification: $0.type) == nil }
    }
}
