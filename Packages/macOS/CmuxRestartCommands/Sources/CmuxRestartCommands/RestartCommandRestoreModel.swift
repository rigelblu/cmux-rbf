public import Foundation

/// Why and when a pane-command observation was captured.
public enum RestartCommandCaptureKind: String, Codable, Sendable {
    case autosave
    case pendingTermination
    case terminationCandidate
}

/// Logical identity shared by primary and re-encoded backup representations.
public struct RestartCommandSnapshotIdentity: Codable, Equatable, Hashable, Sendable {
    public let rootGenerationID: UUID
    public let captureKind: RestartCommandCaptureKind

    public init(rootGenerationID: UUID, captureKind: RestartCommandCaptureKind) {
        self.rootGenerationID = rootGenerationID
        self.captureKind = captureKind
    }
}

/// Root metadata required before an ordinary command can be eligible.
public struct RestartCommandSnapshotEnvelope: Codable, Equatable, Sendable {
    public let rootGenerationID: UUID
    public let captureKind: String

    public init(identity: RestartCommandSnapshotIdentity) {
        rootGenerationID = identity.rootGenerationID
        captureKind = identity.captureKind.rawValue
    }

    public var validatedIdentity: RestartCommandSnapshotIdentity? {
        guard let kind = RestartCommandCaptureKind(rawValue: captureKind) else { return nil }
        return RestartCommandSnapshotIdentity(rootGenerationID: rootGenerationID, captureKind: kind)
    }
}

/// Minimal persisted pane binding. It contains no command, argv, environment, cwd, or secret.
public struct PaneRestartCommandBinding: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let definitionID: String
    public let detectorFingerprint: String
    public let observedAt: TimeInterval
    public let snapshotGenerationID: UUID
    public let captureKind: String

    public init(
        definitionID: RestartCommandDefinitionID,
        detectorFingerprint: String,
        observedAt: TimeInterval,
        snapshotIdentity: RestartCommandSnapshotIdentity
    ) {
        version = Self.currentVersion
        self.definitionID = definitionID.rawValue
        self.detectorFingerprint = detectorFingerprint
        self.observedAt = observedAt
        snapshotGenerationID = snapshotIdentity.rootGenerationID
        captureKind = snapshotIdentity.captureKind.rawValue
    }

    public func validatedDefinitionID(
        envelope: RestartCommandSnapshotEnvelope
    ) -> RestartCommandDefinitionID? {
        guard version == Self.currentVersion,
              detectorFingerprint.count == 64,
              detectorFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              observedAt.isFinite,
              observedAt >= 0,
              snapshotGenerationID == envelope.rootGenerationID,
              captureKind == envelope.captureKind else {
            return nil
        }
        return RestartCommandDefinitionID(rawValue: definitionID)
    }
}

/// Workspace/panel identity supplied by cmux rather than inferred from child environment.
public struct RestartCommandPanelKey: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: UUID
    public let panelID: UUID

    public init(workspaceID: UUID, panelID: UUID) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}

/// Exact persisted-file proof for one primary or manual-backup slot.
public struct RestartCommandSnapshotReceipt: Codable, Equatable, Sendable {
    public let identity: RestartCommandSnapshotIdentity
    public let fileDigest: String

    public init(identity: RestartCommandSnapshotIdentity, fileDigest: String) {
        self.identity = identity
        self.fileDigest = fileDigest
    }

    public var isStructurallyValid: Bool {
        fileDigest.count == 64 && fileDigest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Which registered snapshot file a restore operation selected.
public enum RestartCommandRestoreSource: String, Codable, Sendable {
    case automaticPrimary
    case automaticBackup
    case manualBackup

    public var isAutomatic: Bool {
        switch self {
        case .automaticPrimary, .automaticBackup: true
        case .manualBackup: false
        }
    }
}

/// A copied command authorized for exactly one restored pane in one operation.
public struct RestartCommandLaunchItem: Equatable, Sendable {
    public let originalPanelID: UUID
    public let definitionID: RestartCommandDefinitionID
    public let command: String
    public let savedWorkingDirectory: String

    public init(
        originalPanelID: UUID,
        definitionID: RestartCommandDefinitionID,
        command: String,
        savedWorkingDirectory: String
    ) {
        self.originalPanelID = originalPanelID
        self.definitionID = definitionID
        self.command = command
        self.savedWorkingDirectory = savedWorkingDirectory
    }
}

/// Closed restore-time failures safe to present without persisting process evidence.
public enum RestartCommandRestoreRefusalReason: String, Codable, Equatable, Sendable {
    case definitionsNeedApproval
    case definitionRemoved
    case detectorChanged
    case missingWorkingDirectory
    case paneBecameRemote
    case ineligibleSnapshot
    case approvalUnavailable
    case invalidBinding
}

/// One refusal before duplicate definition/reason rows are grouped for presentation.
public struct RestartCommandRestoreRefusal: Equatable, Sendable {
    public let panelID: UUID?
    public let definitionID: RestartCommandDefinitionID?
    public let reason: RestartCommandRestoreRefusalReason

    public init(
        panelID: UUID? = nil,
        definitionID: RestartCommandDefinitionID?,
        reason: RestartCommandRestoreRefusalReason
    ) {
        self.panelID = panelID
        self.definitionID = definitionID
        self.reason = reason
    }
}

/// Immutable result of one authorization linearization point.
public struct RestartCommandRestorePlan: Equatable, Sendable {
    public let operationID: UUID
    public let launchItems: [RestartCommandLaunchItem]
    public let refusals: [RestartCommandRestoreRefusal]

    public init(
        operationID: UUID,
        launchItems: [RestartCommandLaunchItem],
        refusals: [RestartCommandRestoreRefusal]
    ) {
        self.operationID = operationID
        self.launchItems = launchItems
        self.refusals = refusals
    }
}

/// Prevents two delivery paths from launching the same pane in one restore operation.
public struct RestartCommandLaunchClaim: Hashable, Sendable {
    public let operationID: UUID
    public let panelID: UUID

    public init(operationID: UUID, panelID: UUID) {
        self.operationID = operationID
        self.panelID = panelID
    }
}
