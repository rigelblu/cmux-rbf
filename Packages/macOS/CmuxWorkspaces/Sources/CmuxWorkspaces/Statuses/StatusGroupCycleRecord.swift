public import Foundation

/// What the previous press of the cycle key opened (#cm-110.14): one status group, and whose press it was. The next press
/// folds that group back only if the same workspace or group is cycled and the group is still open, so a group he opened
/// himself, or opened again by hand, is never folded back.
public struct StatusGroupCycleRecord: Equatable, Sendable {
    /// The workspace, or the workspace group, the press moved.
    public let subject: UUID
    /// The status group the press opened.
    public let statusId: String

    /// Creates a record.
    public init(subject: UUID, statusId: String) {
        self.subject = subject
        self.statusId = statusId
    }

    /// The status group a press folds back before it opens its own, or nil.
    public func foldBack(subject: UUID, collapsedStatusIds: Set<String>) -> String? {
        guard subject == self.subject, !collapsedStatusIds.contains(statusId) else { return nil }
        return statusId
    }

    /// The record a press leaves: the one status group it opened, or nil when it opened none or more than one.
    public static func recording(subject: UUID, before: Set<String>, after: Set<String>) -> StatusGroupCycleRecord? {
        let opened = before.subtracting(after)
        guard opened.count == 1, let statusId = opened.first else { return nil }
        return StatusGroupCycleRecord(subject: subject, statusId: statusId)
    }
}
