public import Foundation

/// One grouped, structured reason in a restore summary.
public struct RestartCommandRestoreSummaryRow: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let definitionID: RestartCommandDefinitionID?
    public let reason: RestartCommandRestoreRefusalReason
    public let paneCount: Int

    public init(
        id: UUID = UUID(),
        definitionID: RestartCommandDefinitionID?,
        reason: RestartCommandRestoreRefusalReason,
        paneCount: Int
    ) {
        self.id = id
        self.definitionID = definitionID
        self.reason = reason
        self.paneCount = paneCount
    }

    /// Accessible display text for exactly one row.
    public var displayText: String {
        guard let definitionID else {
            return String(
                localized: "notifications.restartCommands.invalidRecord",
                defaultValue: "A saved pane command wasn’t restarted because its restore record was invalid."
            )
        }
        let name: String
        if paneCount > 1 {
            let count = String.localizedStringWithFormat(
                String(
                    localized: "notifications.restartCommands.paneCount",
                    defaultValue: "%lld panes"
                ),
                Int64(paneCount)
            )
            name = "\(definitionID.displayName) (\(count))"
        } else {
            name = definitionID.displayName
        }
        let explanation: String = switch reason {
        case .definitionsNeedApproval:
            String(
                localized: "notifications.restartCommands.reason.approval",
                defaultValue: "Its command changes haven’t been approved."
            )
        case .definitionRemoved:
            String(
                localized: "notifications.restartCommands.reason.removed",
                defaultValue: "Its command definition is no longer available."
            )
        case .detectorChanged:
            String(
                localized: "notifications.restartCommands.reason.detectorChanged",
                defaultValue: "Its detection rule changed after this pane was saved."
            )
        case .missingWorkingDirectory:
            String(
                localized: "notifications.restartCommands.reason.missingFolder",
                defaultValue: "Its saved folder is no longer available."
            )
        case .paneBecameRemote:
            String(
                localized: "notifications.restartCommands.reason.remote",
                defaultValue: "This pane is now remote."
            )
        case .ineligibleSnapshot:
            String(
                localized: "notifications.restartCommands.reason.ineligibleSnapshot",
                defaultValue: "Its saved session couldn’t be verified."
            )
        case .approvalUnavailable:
            String(
                localized: "notifications.restartCommands.reason.stateUnavailable",
                defaultValue: "cmux couldn’t read the current approval."
            )
        case .invalidBinding:
            String(
                localized: "notifications.restartCommands.reason.invalidRecord",
                defaultValue: "Its restore record was invalid."
            )
        }
        return "\(name) — \(explanation)"
    }
}

/// One durable, Mac-only summary emitted after a restore operation closes.
public struct RestartCommandRestoreSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let createdAt: Date
    public var isRead: Bool
    public let rows: [RestartCommandRestoreSummaryRow]
    public let overflowCount: Int

    public init(
        id: UUID = UUID(),
        operationID: UUID,
        createdAt: Date,
        isRead: Bool = false,
        rows: [RestartCommandRestoreSummaryRow],
        overflowCount: Int
    ) {
        self.id = id
        self.operationID = operationID
        self.createdAt = createdAt
        self.isRead = isRead
        self.rows = rows
        self.overflowCount = overflowCount
    }

    public var title: String {
        String(
            localized: "notifications.restartCommands.title",
            defaultValue: "Some commands weren’t restarted"
        )
    }

    public var overflowText: String? {
        guard overflowCount > 0 else { return nil }
        return String.localizedStringWithFormat(
            String(
                localized: "notifications.restartCommands.overflow",
                defaultValue: "And %lld more."
            ),
            Int64(overflowCount)
        )
    }

    /// Groups duplicate definition/reason refusals in first-occurrence order and bounds display rows to five.
    public static func make(
        operationID: UUID,
        refusals: [RestartCommandRestoreRefusal],
        createdAt: Date
    ) -> RestartCommandRestoreSummary? {
        guard !refusals.isEmpty else { return nil }
        struct GroupKey: Hashable {
            let definitionID: RestartCommandDefinitionID?
            let reason: RestartCommandRestoreRefusalReason
        }
        var order: [GroupKey] = []
        var counts: [GroupKey: Int] = [:]
        for refusal in refusals {
            let key = GroupKey(definitionID: refusal.definitionID, reason: refusal.reason)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let visible = Array(order.prefix(5))
        let rows = visible.map { key in
            RestartCommandRestoreSummaryRow(
                definitionID: key.definitionID,
                reason: key.reason,
                paneCount: counts[key, default: 1]
            )
        }
        return RestartCommandRestoreSummary(
            operationID: operationID,
            createdAt: createdAt,
            rows: rows,
            overflowCount: max(0, order.count - visible.count)
        )
    }
}

/// In-memory union used only by Mac notification presentation.
public enum MacNotificationFeedItem<TerminalItem: Identifiable & Sendable>: Identifiable, Sendable
where TerminalItem.ID == UUID {
    case terminal(TerminalItem, createdAt: Date, isRead: Bool)
    case restartSummary(RestartCommandRestoreSummary)

    public var id: UUID {
        switch self {
        case .terminal(let item, _, _): item.id
        case .restartSummary(let summary): summary.id
        }
    }

    public var createdAt: Date {
        switch self {
        case .terminal(_, let createdAt, _): createdAt
        case .restartSummary(let summary): summary.createdAt
        }
    }

    public var isRead: Bool {
        switch self {
        case .terminal(_, _, let isRead): isRead
        case .restartSummary(let summary): summary.isRead
        }
    }
}

/// Pure deterministic merge for the two Mac-only feed surfaces.
public enum MacNotificationFeedMerge {
    public static func merge<TerminalItem>(
        terminal: [(item: TerminalItem, createdAt: Date, isRead: Bool)],
        summaries: [RestartCommandRestoreSummary]
    ) -> [MacNotificationFeedItem<TerminalItem>]
    where TerminalItem: Identifiable & Sendable, TerminalItem.ID == UUID {
        let items = terminal.map {
            MacNotificationFeedItem<TerminalItem>.terminal(
                $0.item,
                createdAt: $0.createdAt,
                isRead: $0.isRead
            )
        } + summaries.map(MacNotificationFeedItem.restartSummary)
        return items.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
