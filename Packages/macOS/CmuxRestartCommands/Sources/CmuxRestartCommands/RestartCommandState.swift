public import Foundation

/// App-owned stored mode. Editable definitions cannot set this value.
public enum RestartCommandStoredMode: String, Codable, Sendable {
    case enabledAppDefaults
    case enabledApproved
    case disabledByUser
}

/// Provenance recorded when a definition digest becomes approved.
public enum RestartCommandApprovalSource: String, Codable, Sendable {
    case appDefaults
    case userReview
}

/// Durable state colocated with bundle-specific session snapshots.
public struct RestartCommandStateRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var revision: UInt64
    public var mode: RestartCommandStoredMode
    public var approvedDefinitionDigest: String
    public var approvalSource: RestartCommandApprovalSource
    public var approvedAt: TimeInterval
    public var primaryReceipt: RestartCommandSnapshotReceipt?
    public var manualBackupReceipt: RestartCommandSnapshotReceipt?
    public var automaticallyConsumedIdentities: [RestartCommandSnapshotIdentity]

    public init(
        revision: UInt64,
        mode: RestartCommandStoredMode,
        approvedDefinitionDigest: String,
        approvalSource: RestartCommandApprovalSource,
        approvedAt: TimeInterval,
        primaryReceipt: RestartCommandSnapshotReceipt? = nil,
        manualBackupReceipt: RestartCommandSnapshotReceipt? = nil,
        automaticallyConsumedIdentities: [RestartCommandSnapshotIdentity] = []
    ) {
        version = Self.currentVersion
        self.revision = revision
        self.mode = mode
        self.approvedDefinitionDigest = approvedDefinitionDigest
        self.approvalSource = approvalSource
        self.approvedAt = approvedAt
        self.primaryReceipt = primaryReceipt
        self.manualBackupReceipt = manualBackupReceipt
        self.automaticallyConsumedIdentities = automaticallyConsumedIdentities
    }

    /// Initial default-on state; it deliberately carries no historical receipts.
    public static func enabledDefaults(at time: TimeInterval) -> RestartCommandStateRecord {
        RestartCommandStateRecord(
            revision: 1,
            mode: .enabledAppDefaults,
            approvedDefinitionDigest: RestartCommandDefinitionSet.appDefaults.approvalDigest,
            approvalSource: .appDefaults,
            approvedAt: time
        )
    }

    /// Rejects corrupted or over-bounded state before any authority is derived.
    public var isStructurallyValid: Bool {
        guard version == Self.currentVersion,
              revision > 0,
              approvedDefinitionDigest.count == 64,
              approvedDefinitionDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              approvedAt.isFinite,
              approvedAt >= 0,
              automaticallyConsumedIdentities.count <= 2,
              Set(automaticallyConsumedIdentities).count == automaticallyConsumedIdentities.count,
              primaryReceipt?.isStructurallyValid != false,
              manualBackupReceipt?.isStructurallyValid != false else {
            return false
        }
        let referenced = Set([primaryReceipt?.identity, manualBackupReceipt?.identity].compactMap { $0 })
        return Set(automaticallyConsumedIdentities).isSubset(of: referenced)
    }

    /// Returns the selected exact receipt when its logical and physical identities match.
    public func matchingReceipt(
        source: RestartCommandRestoreSource,
        identity: RestartCommandSnapshotIdentity,
        fileDigest: String
    ) -> RestartCommandSnapshotReceipt? {
        let receipt: RestartCommandSnapshotReceipt? = switch source {
        case .automaticPrimary: primaryReceipt
        case .automaticBackup, .manualBackup: manualBackupReceipt
        }
        guard let receipt,
              receipt.identity == identity,
              receipt.fileDigest == fileDigest else {
            return nil
        }
        return receipt
    }

    /// Adds a successful slot receipt and retains consumed identities still referenced by a slot.
    public mutating func register(
        _ receipt: RestartCommandSnapshotReceipt,
        source: RestartCommandRestoreSource
    ) {
        switch source {
        case .automaticPrimary:
            primaryReceipt = receipt
        case .automaticBackup, .manualBackup:
            manualBackupReceipt = receipt
        }
        revision &+= 1
        pruneConsumedIdentities()
    }

    public mutating func clearPrimaryReceipt() {
        primaryReceipt = nil
        revision &+= 1
        pruneConsumedIdentities()
    }

    public mutating func clearManualBackupReceipt() {
        manualBackupReceipt = nil
        revision &+= 1
        pruneConsumedIdentities()
    }

    /// Approves the complete current definition set or deliberately turns it off.
    public mutating func setEnabled(
        _ enabled: Bool,
        definitionsAreAppDefaults: Bool,
        definitionDigest: String,
        at time: TimeInterval
    ) {
        consumeCurrentReceiptIdentities()
        revision &+= 1
        approvedAt = time
        approvedDefinitionDigest = definitionDigest
        if enabled {
            mode = definitionsAreAppDefaults ? .enabledAppDefaults : .enabledApproved
            approvalSource = definitionsAreAppDefaults ? .appDefaults : .userReview
        } else {
            mode = .disabledByUser
        }
    }

    /// Atomically consumes a logical automatic snapshot identity, including zero-launch plans.
    public mutating func consumeAutomatically(_ identity: RestartCommandSnapshotIdentity) -> Bool {
        guard !automaticallyConsumedIdentities.contains(identity) else { return false }
        automaticallyConsumedIdentities.append(identity)
        revision &+= 1
        pruneConsumedIdentities()
        return automaticallyConsumedIdentities.contains(identity)
    }

    private mutating func consumeCurrentReceiptIdentities() {
        let identities = [primaryReceipt?.identity, manualBackupReceipt?.identity].compactMap { $0 }
        automaticallyConsumedIdentities = Array(Set(automaticallyConsumedIdentities + identities))
        pruneConsumedIdentities()
    }

    private mutating func pruneConsumedIdentities() {
        let referenced = Set([primaryReceipt?.identity, manualBackupReceipt?.identity].compactMap { $0 })
        automaticallyConsumedIdentities = automaticallyConsumedIdentities
            .filter { referenced.contains($0) }
            .sorted {
                if $0.rootGenerationID.uuidString != $1.rootGenerationID.uuidString {
                    return $0.rootGenerationID.uuidString < $1.rootGenerationID.uuidString
                }
                return $0.captureKind.rawValue < $1.captureKind.rawValue
            }
    }
}

/// Effective state shared by restore and Settings.
public enum RestartCommandAllowlistState: Equatable, Sendable {
    public enum DisabledReason: Equatable, Sendable {
        case definitionsChanged
        case invalidDefinitions(RestartCommandDefinitionError)
        case stateUnavailable
    }

    case enabledAppDefaults
    case enabledApproved
    case disabledByUser
    case disabledNeedsApproval(DisabledReason)

    public var isEnabled: Bool {
        switch self {
        case .enabledAppDefaults, .enabledApproved: true
        case .disabledByUser, .disabledNeedsApproval: false
        }
    }
}

/// Pure authority projection over one state/definition snapshot pair.
public enum RestartCommandAuthority {
    public static func effectiveState(
        record: RestartCommandStateRecord,
        definitions: RestartCommandDefinitionSet,
        definitionsAreAppDefaults: Bool
    ) -> RestartCommandAllowlistState {
        guard record.isStructurallyValid else {
            return .disabledNeedsApproval(.stateUnavailable)
        }
        if record.mode == .disabledByUser {
            return .disabledByUser
        }
        guard record.approvedDefinitionDigest == definitions.approvalDigest else {
            return .disabledNeedsApproval(.definitionsChanged)
        }
        switch record.mode {
        case .enabledAppDefaults:
            return definitionsAreAppDefaults ? .enabledAppDefaults : .disabledNeedsApproval(.definitionsChanged)
        case .enabledApproved:
            return definitionsAreAppDefaults ? .disabledNeedsApproval(.definitionsChanged) : .enabledApproved
        case .disabledByUser:
            return .disabledByUser
        }
    }
}
