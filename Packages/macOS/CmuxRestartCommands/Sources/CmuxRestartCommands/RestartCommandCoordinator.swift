public import Foundation
internal import os

/// Immutable authority handed to one foreground-observation scan.
public struct RestartCommandCaptureContext: Sendable {
    public let identity: RestartCommandSnapshotIdentity
    public let definitions: RestartCommandDefinitionSet

    public init(identity: RestartCommandSnapshotIdentity, definitions: RestartCommandDefinitionSet) {
        self.identity = identity
        self.definitions = definitions
    }
}

/// Minimal pane facts the app target projects from a selected session snapshot.
public struct RestartCommandPaneCandidate: Sendable {
    public let panelID: UUID
    public let binding: PaneRestartCommandBinding?
    public let hasExistingResumeIntent: Bool
    public let isRemote: Bool
    public let savedWorkingDirectory: String?

    public init(
        panelID: UUID,
        binding: PaneRestartCommandBinding?,
        hasExistingResumeIntent: Bool,
        isRemote: Bool,
        savedWorkingDirectory: String?
    ) {
        self.panelID = panelID
        self.binding = binding
        self.hasExistingResumeIntent = hasExistingResumeIntent
        self.isRemote = isRemote
        self.savedWorkingDirectory = savedWorkingDirectory
    }
}

/// Exact request for one startup or explicit restore authorization.
public struct RestartCommandAuthorizationRequest: Sendable {
    public let operationID: UUID
    public let source: RestartCommandRestoreSource
    public let envelope: RestartCommandSnapshotEnvelope?
    public let fileDigest: String
    public let candidates: [RestartCommandPaneCandidate]

    public init(
        operationID: UUID = UUID(),
        source: RestartCommandRestoreSource,
        envelope: RestartCommandSnapshotEnvelope?,
        fileDigest: String,
        candidates: [RestartCommandPaneCandidate]
    ) {
        self.operationID = operationID
        self.source = source
        self.envelope = envelope
        self.fileDigest = fileDigest
        self.candidates = candidates
    }
}

/// Outcome distinguishes quiet control states from a completed, possibly all-refused plan.
public enum RestartCommandAuthorizationOutcome: Sendable {
    case quiet
    case plan(RestartCommandRestorePlan)
}

/// The single authority projection consumed by Settings presentation.
public struct RestartCommandSettingsProjection: Equatable, Sendable {
    public let state: RestartCommandAllowlistState
    public let commandCount: Int

    public init(state: RestartCommandAllowlistState, commandCount: Int) {
        self.state = state
        self.commandCount = commandCount
    }
}

/// One synchronous authority coordinator shared by lifecycle, Settings, and restore.
public final class RestartCommandCoordinator: @unchecked Sendable {
    public let definitionsRepository: RestartCommandDefinitionsRepository
    public let stateRepository: RestartCommandStateRepository
    private let coordinationLock = OSAllocatedUnfairLock(initialState: ())
    private let processExecutionAvailable = OSAllocatedUnfairLock(initialState: true)
    private let now: @Sendable () -> TimeInterval
    private let directoryExists: @Sendable (String) -> Bool

    public init(
        definitionsRepository: RestartCommandDefinitionsRepository,
        stateRepository: RestartCommandStateRepository,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.definitionsRepository = definitionsRepository
        self.stateRepository = stateRepository
        self.now = now
        self.directoryExists = directoryExists
    }

    /// Shared current projection. Missing state initializes default-on only beside absent definitions.
    public func effectiveState() -> RestartCommandAllowlistState {
        coordinationLock.withLock { effectiveStateUnserialized().state }
    }

    /// Keeps Settings count and status on the same synchronized authority read.
    public func settingsProjection() -> RestartCommandSettingsProjection {
        coordinationLock.withLock {
            let projection = effectiveStateUnserialized()
            return RestartCommandSettingsProjection(
                state: projection.state,
                commandCount: projection.definitions?.definitions.definitions.count ?? 0
            )
        }
    }

    /// Creates one generation only when current definitions and state are enabled.
    public func captureContext(
        kind: RestartCommandCaptureKind,
        generationID: UUID = UUID()
    ) -> RestartCommandCaptureContext? {
        coordinationLock.withLock {
            let projection = effectiveStateUnserialized()
            guard projection.state.isEnabled, let definitions = projection.definitions else { return nil }
            return RestartCommandCaptureContext(
                identity: RestartCommandSnapshotIdentity(
                    rootGenerationID: generationID,
                    captureKind: kind
                ),
                definitions: definitions.definitions
            )
        }
    }

    /// Persists the one app-owned global on/off decision.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> RestartCommandAllowlistState {
        coordinationLock.withLock {
            guard processExecutionAvailable.withLock({ $0 }) else {
                return .disabledNeedsApproval(.stateUnavailable)
            }
            let definitionRead = definitionsRepository.read()
            let definitionSnapshot: RestartCommandDefinitionSnapshot?
            switch definitionRead {
            case .snapshot(let snapshot):
                definitionSnapshot = snapshot
            case .invalid(let error):
                guard !enabled else { return .disabledNeedsApproval(.invalidDefinitions(error)) }
                definitionSnapshot = nil
            case .unavailable:
                guard !enabled else { return .disabledNeedsApproval(.stateUnavailable) }
                definitionSnapshot = nil
            }

            let existing: RestartCommandStateRecord? = switch stateRepository.load() {
            case .record(let record): record
            case .missing, .unavailable: nil
            }
            let digest = definitionSnapshot?.definitions.approvalDigest
                ?? existing?.approvedDefinitionDigest
                ?? RestartCommandDefinitionSet.appDefaults.approvalDigest
            var record = existing ?? RestartCommandStateRecord.enabledDefaults(at: now())
            record.setEnabled(
                enabled,
                definitionsAreAppDefaults: definitionSnapshot?.definitions == .appDefaults,
                definitionDigest: digest,
                at: now()
            )
            guard stateRepository.save(record) else {
                processExecutionAvailable.withLock { $0 = false }
                return .disabledNeedsApproval(.stateUnavailable)
            }
            guard let definitionSnapshot else { return .disabledByUser }
            return RestartCommandAuthority.effectiveState(
                record: record,
                definitions: definitionSnapshot.definitions,
                definitionsAreAppDefaults: definitionSnapshot.definitions == .appDefaults
            )
        }
    }

    /// Registers exact bytes only after a session slot write succeeds.
    @discardableResult
    public func registerReceipt(
        identity: RestartCommandSnapshotIdentity,
        fileData: Data,
        source: RestartCommandRestoreSource
    ) -> Bool {
        coordinationLock.withLock {
            guard processExecutionAvailable.withLock({ $0 }) else { return false }
            let projection = effectiveStateUnserialized()
            guard var record = projection.record else { return false }
            record.register(
                RestartCommandSnapshotReceipt(
                    identity: identity,
                    fileDigest: RestartCommandDefinitionSet.sha256Hex(fileData)
                ),
                source: source
            )
            guard stateRepository.save(record) else {
                processExecutionAvailable.withLock { $0 = false }
                return false
            }
            return true
        }
    }

    /// Clears one physical-slot receipt after its corresponding file is absent.
    public func clearReceipt(source: RestartCommandRestoreSource) {
        coordinationLock.withLock {
            guard case .record(var record) = stateRepository.load() else { return }
            switch source {
            case .automaticPrimary:
                record.clearPrimaryReceipt()
            case .automaticBackup, .manualBackup:
                record.clearManualBackupReceipt()
            }
            if !stateRepository.save(record) {
                processExecutionAvailable.withLock { $0 = false }
            }
        }
    }

    /// Plans, re-reads definitions/state, validates the exact receipt, and consumes automatic identity.
    public func authorize(
        _ request: RestartCommandAuthorizationRequest
    ) -> RestartCommandAuthorizationOutcome {
        coordinationLock.withLock {
            let boundCandidates = request.candidates.filter { $0.binding != nil && !$0.hasExistingResumeIntent }
            guard !boundCandidates.isEmpty else {
                return authorizeZeroBindingPlanIfPossible(request)
            }
            guard processExecutionAvailable.withLock({ $0 }) else {
                return .plan(refusalPlan(
                    request: request,
                    candidates: boundCandidates,
                    reason: .approvalUnavailable
                ))
            }

            let firstProjection = effectiveStateUnserialized()
            switch firstProjection.state {
            case .disabledByUser:
                return .quiet
            case .disabledNeedsApproval(let reason):
                let refusal: RestartCommandRestoreRefusalReason = switch reason {
                case .stateUnavailable: .approvalUnavailable
                case .definitionsChanged, .invalidDefinitions: .definitionsNeedApproval
                }
                return .plan(refusalPlan(request: request, candidates: boundCandidates, reason: refusal))
            case .enabledAppDefaults, .enabledApproved:
                break
            }
            guard let firstDefinitions = firstProjection.definitions,
                  let firstRecord = firstProjection.record,
                  let envelope = request.envelope,
                  let identity = envelope.validatedIdentity,
                  firstRecord.matchingReceipt(
                      source: request.source,
                      identity: identity,
                      fileDigest: request.fileDigest
                  ) != nil else {
                return .plan(refusalPlan(
                    request: request,
                    candidates: boundCandidates,
                    reason: .ineligibleSnapshot
                ))
            }
            if request.source.isAutomatic,
               firstRecord.automaticallyConsumedIdentities.contains(identity) {
                return .quiet
            }

            let plan = buildPlan(
                request: request,
                envelope: envelope,
                definitions: firstDefinitions.definitions
            )

            guard case .snapshot(let secondDefinitions) = definitionsRepository.read(),
                  secondDefinitions.revision == firstDefinitions.revision,
                  secondDefinitions.sourceIdentity == firstDefinitions.sourceIdentity,
                  case .record(var secondRecord) = stateRepository.load(),
                  secondRecord.revision == firstRecord.revision,
                  secondRecord.mode == firstRecord.mode,
                  secondRecord.approvedDefinitionDigest == firstRecord.approvedDefinitionDigest,
                  secondRecord.matchingReceipt(
                      source: request.source,
                      identity: identity,
                      fileDigest: request.fileDigest
                  ) != nil else {
                return .plan(refusalPlan(
                    request: request,
                    candidates: boundCandidates,
                    reason: .definitionsNeedApproval
                ))
            }

            if request.source.isAutomatic {
                guard secondRecord.consumeAutomatically(identity),
                      stateRepository.save(secondRecord) else {
                    processExecutionAvailable.withLock { $0 = false }
                    return .plan(refusalPlan(
                        request: request,
                        candidates: boundCandidates,
                        reason: .approvalUnavailable
                    ))
                }
            }
            return .plan(plan)
        }
    }

    private struct Projection {
        let state: RestartCommandAllowlistState
        let definitions: RestartCommandDefinitionSnapshot?
        let record: RestartCommandStateRecord?
    }

    private func effectiveStateUnserialized() -> Projection {
        guard processExecutionAvailable.withLock({ $0 }) else {
            return Projection(
                state: .disabledNeedsApproval(.stateUnavailable),
                definitions: nil,
                record: nil
            )
        }
        let definitionRead = definitionsRepository.read()
        switch definitionRead {
        case .invalid(let error):
            return Projection(
                state: .disabledNeedsApproval(.invalidDefinitions(error)),
                definitions: nil,
                record: nil
            )
        case .unavailable:
            return Projection(
                state: .disabledNeedsApproval(.stateUnavailable),
                definitions: nil,
                record: nil
            )
        case .snapshot(let definitions):
            switch stateRepository.load() {
            case .record(let record):
                return Projection(
                    state: RestartCommandAuthority.effectiveState(
                        record: record,
                        definitions: definitions.definitions,
                        definitionsAreAppDefaults: definitions.definitions == .appDefaults
                    ),
                    definitions: definitions,
                    record: record
                )
            case .missing:
                guard definitions.definitions == .appDefaults else {
                    return Projection(
                        state: .disabledNeedsApproval(.definitionsChanged),
                        definitions: definitions,
                        record: nil
                    )
                }
                let record = RestartCommandStateRecord.enabledDefaults(at: now())
                guard stateRepository.save(record) else {
                    processExecutionAvailable.withLock { $0 = false }
                    return Projection(
                        state: .disabledNeedsApproval(.stateUnavailable),
                        definitions: definitions,
                        record: nil
                    )
                }
                return Projection(state: .enabledAppDefaults, definitions: definitions, record: record)
            case .unavailable:
                return Projection(
                    state: .disabledNeedsApproval(.stateUnavailable),
                    definitions: definitions,
                    record: nil
                )
            }
        }
    }

    private func authorizeZeroBindingPlanIfPossible(
        _ request: RestartCommandAuthorizationRequest
    ) -> RestartCommandAuthorizationOutcome {
        guard processExecutionAvailable.withLock({ $0 }) else { return .quiet }
        let firstProjection = effectiveStateUnserialized()
        guard firstProjection.state.isEnabled,
              let firstDefinitions = firstProjection.definitions,
              let firstRecord = firstProjection.record,
              let envelope = request.envelope,
              let identity = envelope.validatedIdentity,
              firstRecord.matchingReceipt(
                  source: request.source,
                  identity: identity,
                  fileDigest: request.fileDigest
              ) != nil else {
            return .quiet
        }
        if request.source.isAutomatic,
           firstRecord.automaticallyConsumedIdentities.contains(identity) {
            return .quiet
        }
        guard case .snapshot(let secondDefinitions) = definitionsRepository.read(),
              secondDefinitions.revision == firstDefinitions.revision,
              secondDefinitions.sourceIdentity == firstDefinitions.sourceIdentity,
              case .record(var record) = stateRepository.load(),
              record.revision == firstRecord.revision,
              record.mode == firstRecord.mode,
              record.approvedDefinitionDigest == firstRecord.approvedDefinitionDigest,
              record.matchingReceipt(
                  source: request.source,
                  identity: identity,
                  fileDigest: request.fileDigest
              ) != nil else {
            return .quiet
        }
        if request.source.isAutomatic {
            guard record.consumeAutomatically(identity), stateRepository.save(record) else {
                processExecutionAvailable.withLock { $0 = false }
                return .quiet
            }
        }
        return .plan(RestartCommandRestorePlan(
            operationID: request.operationID,
            launchItems: [],
            refusals: []
        ))
    }

    private func buildPlan(
        request: RestartCommandAuthorizationRequest,
        envelope: RestartCommandSnapshotEnvelope,
        definitions: RestartCommandDefinitionSet
    ) -> RestartCommandRestorePlan {
        var launchItems: [RestartCommandLaunchItem] = []
        var refusals: [RestartCommandRestoreRefusal] = []
        for candidate in request.candidates {
            guard let binding = candidate.binding,
                  !candidate.hasExistingResumeIntent else {
                continue
            }
            guard let definitionID = binding.validatedDefinitionID(envelope: envelope) else {
                refusals.append(.init(definitionID: nil, reason: .invalidBinding))
                continue
            }
            guard let definition = definitions.definition(id: definitionID),
                  let fingerprint = definitions.detectorFingerprint(for: definitionID) else {
                refusals.append(.init(definitionID: definitionID, reason: .definitionRemoved))
                continue
            }
            guard fingerprint == binding.detectorFingerprint else {
                refusals.append(.init(definitionID: definitionID, reason: .detectorChanged))
                continue
            }
            guard !candidate.isRemote else {
                refusals.append(.init(definitionID: definitionID, reason: .paneBecameRemote))
                continue
            }
            guard let workingDirectory = candidate.savedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !workingDirectory.isEmpty,
                  directoryExists(workingDirectory) else {
                refusals.append(.init(definitionID: definitionID, reason: .missingWorkingDirectory))
                continue
            }
            launchItems.append(RestartCommandLaunchItem(
                originalPanelID: candidate.panelID,
                command: definition.command,
                savedWorkingDirectory: workingDirectory
            ))
        }
        return RestartCommandRestorePlan(
            operationID: request.operationID,
            launchItems: launchItems,
            refusals: refusals
        )
    }

    private func refusalPlan(
        request: RestartCommandAuthorizationRequest,
        candidates: [RestartCommandPaneCandidate],
        reason: RestartCommandRestoreRefusalReason
    ) -> RestartCommandRestorePlan {
        RestartCommandRestorePlan(
            operationID: request.operationID,
            launchItems: [],
            refusals: candidates.map { candidate in
                RestartCommandRestoreRefusal(
                    definitionID: candidate.binding.flatMap {
                        RestartCommandDefinitionID(rawValue: $0.definitionID)
                    },
                    reason: reason
                )
            }
        )
    }
}
