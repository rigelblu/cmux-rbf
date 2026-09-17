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

/// Structured fallback event emitted when entering degraded fallback mode.
public struct RestartCommandFallbackDebugEvent: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case invalid(RestartCommandDefinitionError)
        case unreadable
        case missingAfterCustomization
    }

    public let reason: Reason
    public let sourceIdentity: String?

    public init(reason: Reason, sourceIdentity: String? = nil) {
        self.reason = reason
        self.sourceIdentity = sourceIdentity
    }
}

/// One synchronous authority coordinator shared by lifecycle, Settings, and restore.
public final class RestartCommandCoordinator: @unchecked Sendable {
    public let definitionsRepository: RestartCommandDefinitionsRepository
    public let stateRepository: RestartCommandStateRepository
    public let bundledDefinitions: RestartCommandDefinitionSet?
    public let onFallbackDebugEvent: (@Sendable (RestartCommandFallbackDebugEvent) -> Void)?
    private let coordinationLock = OSAllocatedUnfairLock(initialState: ())
    private let now: @Sendable () -> TimeInterval
    private let directoryExists: @Sendable (String) -> Bool

    private struct InternalState {
        var lastEmittedFallbackEvent: RestartCommandFallbackDebugEvent?
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())

    public init(
        definitionsRepository: RestartCommandDefinitionsRepository,
        stateRepository: RestartCommandStateRepository,
        bundledDefinitions: RestartCommandDefinitionSet? = try? BundledRestartCommandDefinitions.load(),
        onFallbackDebugEvent: (@Sendable (RestartCommandFallbackDebugEvent) -> Void)? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.definitionsRepository = definitionsRepository
        self.stateRepository = stateRepository
        self.bundledDefinitions = bundledDefinitions
        self.onFallbackDebugEvent = onFallbackDebugEvent
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
                commandCount: projection.definitions?.definitions.count ?? bundledDefinitions?.definitions.count ?? 0
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
                definitions: definitions
            )
        }
    }

    /// Persists the one app-owned global on/off decision.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> RestartCommandAllowlistState {
        coordinationLock.withLock {
            guard let bundled = self.bundledDefinitions else {
                return .disabledStateUnavailable
            }
            let existing: RestartCommandStateRecord? = switch stateRepository.load() {
            case .record(let record): record.isStructurallyValid ? record : nil
            case .missing, .unavailable: nil
            }
            var record = existing ?? RestartCommandStateRecord.enabledDefaults(
                definitionDigest: bundled.approvalDigest,
                at: now()
            )
            if enabled {
                record.setEnabled(
                    true,
                    definitionsAreAppDefaults: true,
                    definitionDigest: bundled.approvalDigest,
                    at: now()
                )
            } else {
                record.setEnabled(
                    false,
                    definitionsAreAppDefaults: true,
                    definitionDigest: record.approvedDefinitionDigest,
                    at: now()
                )
            }
            guard stateRepository.save(record) else {
                return .disabledStateUnavailable
            }
            return effectiveStateUnserialized().state
        }
    }

    /// Approves the current valid user definitions file and switches authority directly to it.
    @discardableResult
    public func approveCurrentDefinitions() -> RestartCommandAllowlistState {
        coordinationLock.withLock {
            guard let bundled = self.bundledDefinitions else {
                return .disabledStateUnavailable
            }
            let userRead = definitionsRepository.read()
            guard case .snapshot(let snapshot) = userRead else {
                return effectiveStateUnserialized().state
            }
            let existing: RestartCommandStateRecord? = switch stateRepository.load() {
            case .record(let record): record.isStructurallyValid ? record : nil
            case .missing, .unavailable: nil
            }
            var record = existing ?? RestartCommandStateRecord.enabledDefaults(
                definitionDigest: bundled.approvalDigest,
                at: now()
            )
            record.setEnabled(
                true,
                definitionsAreAppDefaults: false,
                definitionDigest: snapshot.definitions.approvalDigest,
                at: now()
            )
            guard stateRepository.save(record) else {
                return .disabledStateUnavailable
            }
            return effectiveStateUnserialized().state
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
            _ = stateRepository.save(record)
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
            let firstProjection = effectiveStateUnserialized()
            switch firstProjection.state {
            case .disabledByUser:
                return .quiet
            case .disabledStateUnavailable:
                return .plan(refusalPlan(
                    request: request,
                    candidates: boundCandidates,
                    reason: .approvalUnavailable
                ))
            case .enabledAppDefaults, .enabledFallback, .enabledApproved:
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
                definitions: firstDefinitions
            )

            let secondUserRead = definitionsRepository.read()
            let secondUserObservationIdentity: String
            switch secondUserRead {
            case .missing:
                secondUserObservationIdentity = "<missing>"
            case .unavailable:
                secondUserObservationIdentity = "<unavailable>"
            case .invalid(_, let sourceIdentity):
                secondUserObservationIdentity = sourceIdentity
            case .snapshot(let snapshot):
                secondUserObservationIdentity = snapshot.sourceIdentity
            }

            guard secondUserObservationIdentity == firstProjection.userObservationIdentity,
                  case .record(var secondRecord) = stateRepository.load(),
                  secondRecord.isStructurallyValid,
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
        let definitions: RestartCommandDefinitionSet?
        let record: RestartCommandStateRecord?
        let userObservationIdentity: String
    }

    private func effectiveStateUnserialized() -> Projection {
        guard let bundled = self.bundledDefinitions else {
            return Projection(
                state: .disabledStateUnavailable,
                definitions: nil,
                record: nil,
                userObservationIdentity: ""
            )
        }
        let userRead = definitionsRepository.read()
        let userObservationIdentity: String = switch userRead {
        case .missing: "<missing>"
        case .unavailable: "<unavailable>"
        case .invalid(_, let sourceIdentity): sourceIdentity
        case .snapshot(let snapshot): snapshot.sourceIdentity
        }

        let stateLoad = stateRepository.load()
        let record: RestartCommandStateRecord
        switch stateLoad {
        case .unavailable:
            return Projection(
                state: .disabledStateUnavailable,
                definitions: nil,
                record: nil,
                userObservationIdentity: userObservationIdentity
            )
        case .missing:
            let initial = RestartCommandStateRecord.enabledDefaults(
                definitionDigest: bundled.approvalDigest,
                at: now()
            )
            guard stateRepository.save(initial) else {
                return Projection(
                    state: .disabledStateUnavailable,
                    definitions: nil,
                    record: nil,
                    userObservationIdentity: userObservationIdentity
                )
            }
            record = initial
        case .record(let loadedRecord):
            guard loadedRecord.isStructurallyValid else {
                return Projection(
                    state: .disabledStateUnavailable,
                    definitions: nil,
                    record: nil,
                    userObservationIdentity: userObservationIdentity
                )
            }
            record = loadedRecord
        }

        let state = RestartCommandAuthority.effectiveState(
            record: record,
            bundledDefinitions: bundled,
            userFileObservation: userRead
        )

        switch state {
        case .disabledByUser, .disabledStateUnavailable:
            internalState.withLock { $0.lastEmittedFallbackEvent = nil }
            return Projection(
                state: state,
                definitions: nil,
                record: record,
                userObservationIdentity: userObservationIdentity
            )
        case .enabledAppDefaults:
            internalState.withLock { $0.lastEmittedFallbackEvent = nil }
            return Projection(
                state: state,
                definitions: bundled,
                record: record,
                userObservationIdentity: userObservationIdentity
            )
        case .enabledApproved:
            internalState.withLock { $0.lastEmittedFallbackEvent = nil }
            guard case .snapshot(let snapshot) = userRead else {
                return Projection(
                    state: .disabledStateUnavailable,
                    definitions: nil,
                    record: record,
                    userObservationIdentity: userObservationIdentity
                )
            }
            return Projection(
                state: state,
                definitions: snapshot.definitions,
                record: record,
                userObservationIdentity: userObservationIdentity
            )
        case .enabledFallback(let warning):
            switch warning {
            case .validUserDefinitionsChanged:
                internalState.withLock { $0.lastEmittedFallbackEvent = nil }
            case .unusableUserFile(let reason):
                let debugReason: RestartCommandFallbackDebugEvent.Reason = switch reason {
                case .invalid(let error): .invalid(error)
                case .unreadable: .unreadable
                case .missingAfterCustomization: .missingAfterCustomization
                }
                let sourceIdentity: String? = switch userRead {
                case .invalid(_, let id): id
                default: nil
                }
                emitFallbackDebugEvent(reason: debugReason, sourceIdentity: sourceIdentity)
            }
            return Projection(
                state: state,
                definitions: bundled,
                record: record,
                userObservationIdentity: userObservationIdentity
            )
        }
    }

    private func emitFallbackDebugEvent(
        reason: RestartCommandFallbackDebugEvent.Reason,
        sourceIdentity: String?
    ) {
        let event = RestartCommandFallbackDebugEvent(reason: reason, sourceIdentity: sourceIdentity)
        let shouldEmit = internalState.withLock { state in
            if state.lastEmittedFallbackEvent != event {
                state.lastEmittedFallbackEvent = event
                return true
            }
            return false
        }
        if shouldEmit {
            onFallbackDebugEvent?(event)
        }
    }

    private func authorizeZeroBindingPlanIfPossible(
        _ request: RestartCommandAuthorizationRequest
    ) -> RestartCommandAuthorizationOutcome {
        let firstProjection = effectiveStateUnserialized()
        guard firstProjection.state.isEnabled,
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

        let secondUserRead = definitionsRepository.read()
        let secondUserObservationIdentity: String
        switch secondUserRead {
        case .missing:
            secondUserObservationIdentity = "<missing>"
        case .unavailable:
            secondUserObservationIdentity = "<unavailable>"
        case .invalid(_, let sourceIdentity):
            secondUserObservationIdentity = sourceIdentity
        case .snapshot(let snapshot):
            secondUserObservationIdentity = snapshot.sourceIdentity
        }

        guard secondUserObservationIdentity == firstProjection.userObservationIdentity,
              case .record(var record) = stateRepository.load(),
              record.isStructurallyValid,
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
                refusals.append(.init(panelID: candidate.panelID, definitionID: nil, reason: .invalidBinding))
                continue
            }
            guard let definition = definitions.definition(id: definitionID),
                  let fingerprint = definitions.detectorFingerprint(for: definitionID) else {
                refusals.append(.init(panelID: candidate.panelID, definitionID: definitionID, reason: .definitionRemoved))
                continue
            }
            guard fingerprint == binding.detectorFingerprint else {
                refusals.append(.init(panelID: candidate.panelID, definitionID: definitionID, reason: .detectorChanged))
                continue
            }
            guard !candidate.isRemote else {
                refusals.append(.init(panelID: candidate.panelID, definitionID: definitionID, reason: .paneBecameRemote))
                continue
            }
            guard let workingDirectory = candidate.savedWorkingDirectory,
                  !workingDirectory.isEmpty,
                  directoryExists(workingDirectory) else {
                refusals.append(.init(panelID: candidate.panelID, definitionID: definitionID, reason: .missingWorkingDirectory))
                continue
            }
            launchItems.append(RestartCommandLaunchItem(
                originalPanelID: candidate.panelID,
                definitionID: definitionID,
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
                    panelID: candidate.panelID,
                    definitionID: request.envelope.flatMap { envelope in
                        candidate.binding?.validatedDefinitionID(envelope: envelope)
                    },
                    reason: reason
                )
            }
        )
    }
}
