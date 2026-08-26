import Foundation
import Testing
@testable import CmuxRestartCommands

@Suite("Restart command coordinator")
struct RestartCommandCoordinatorTests {
    @Test func automaticIdentityRunsOnceAcrossPrimaryAndBackupWhileManualRestoreIsReusable() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(
            rootGenerationID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            captureKind: .pendingTermination
        )
        let snapshotBytes = Data("exact encoded snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: snapshotBytes,
            source: .automaticPrimary
        ))
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: snapshotBytes,
            source: .manualBackup
        ))

        let request = fixture.request(
            identity: identity,
            source: .automaticPrimary,
            snapshotBytes: snapshotBytes
        )
        let first = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(first.launchItems.map(\.command) == ["hunk"])
        #expect(first.launchItems.map(\.savedWorkingDirectory) == [fixture.workingDirectory.path])

        let automaticBackup = fixture.request(
            identity: identity,
            source: .automaticBackup,
            snapshotBytes: snapshotBytes
        )
        if case .quiet = fixture.coordinator.authorize(automaticBackup) {
            // Expected: the logical identity is consumed, independent of physical slot.
        } else {
            Issue.record("Automatic backup replayed an already-consumed logical snapshot")
        }

        let manual = fixture.request(
            identity: identity,
            source: .manualBackup,
            snapshotBytes: snapshotBytes
        )
        #expect(plan(from: fixture.coordinator.authorize(manual))?.launchItems.count == 1)
        #expect(plan(from: fixture.coordinator.authorize(manual))?.launchItems.count == 1)
    }

    @Test func existingResumeIntentWinsAndStillConsumesAutomaticIdentity() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(rootGenerationID: UUID(), captureKind: .autosave)
        let bytes = Data("snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: bytes,
            source: .automaticPrimary
        ))

        let request = fixture.request(
            identity: identity,
            source: .automaticPrimary,
            snapshotBytes: bytes,
            hasExistingResumeIntent: true
        )
        let result = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(result.launchItems.isEmpty)
        #expect(result.refusals.isEmpty)
        if case .quiet = fixture.coordinator.authorize(request) {
            // Expected: a zero-launch operation is also consumed once.
        } else {
            Issue.record("Automatic zero-launch plan was not consumed")
        }
    }

    @Test func anEditDisablesTheGlobalAuthorityUntilOneReenable() throws {
        let fixture = try Fixture()
        #expect(fixture.coordinator.settingsProjection() == RestartCommandSettingsProjection(
            state: .enabledAppDefaults,
            commandCount: 3
        ))
        #expect(fixture.definitions.materializeForEditing(schemaData: Data("{}".utf8)))

        let defaults = String(
            decoding: RestartCommandDefinitionSet.appDefaults.editableDefaultsData(),
            as: UTF8.self
        )
        let edited = defaults.replacingOccurrences(
            of: "\"command\": \"hunk\"",
            with: "\"command\": \"hunk --staged\""
        )
        try Data(edited.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)

        #expect(fixture.coordinator.effectiveState() == .disabledNeedsApproval(.definitionsChanged))
        #expect(fixture.coordinator.setEnabled(true) == .enabledApproved)
        #expect(fixture.coordinator.settingsProjection() == RestartCommandSettingsProjection(
            state: .enabledApproved,
            commandCount: 3
        ))
    }

    @Test func stateWriteFailureCanBeRetriedAfterStorageRecovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restart-command-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let coordinator = RestartCommandCoordinator(
            definitionsRepository: RestartCommandDefinitionsRepository(
                definitionsFileURL: root.appendingPathComponent("restart-commands.json")
            ),
            stateRepository: RestartCommandStateRepository(
                fileURL: blockedParent.appendingPathComponent("state.json")
            )
        )

        #expect(coordinator.setEnabled(false) == .disabledNeedsApproval(.stateUnavailable))
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        #expect(coordinator.setEnabled(false) == .disabledByUser)
    }

    @Test func invalidBindingDoesNotLeakUnvalidatedDefinitionIdentity() throws {
        let fixture = try Fixture()
        let authorizedIdentity = RestartCommandSnapshotIdentity(
            rootGenerationID: UUID(),
            captureKind: .autosave
        )
        let otherIdentity = RestartCommandSnapshotIdentity(
            rootGenerationID: UUID(),
            captureKind: .autosave
        )
        let bytes = Data("snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: authorizedIdentity,
            fileData: bytes,
            source: .manualBackup
        ))
        let fingerprint = try #require(
            RestartCommandDefinitionSet.appDefaults.detectorFingerprint(for: .hunk)
        )
        let request = RestartCommandAuthorizationRequest(
            source: .manualBackup,
            envelope: RestartCommandSnapshotEnvelope(identity: authorizedIdentity),
            fileDigest: RestartCommandDefinitionSet.sha256Hex(bytes),
            candidates: [
                RestartCommandPaneCandidate(
                    panelID: UUID(),
                    binding: PaneRestartCommandBinding(
                        definitionID: .hunk,
                        detectorFingerprint: fingerprint,
                        observedAt: 100,
                        snapshotIdentity: otherIdentity
                    ),
                    hasExistingResumeIntent: false,
                    isRemote: false,
                    savedWorkingDirectory: fixture.workingDirectory.path
                ),
            ]
        )

        let result = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(result.refusals.count == 1)
        #expect(result.refusals.first?.definitionID == nil)
        #expect(result.refusals.first?.reason == .invalidBinding)
        #expect(result.refusals.first?.panelID == request.candidates.first?.panelID)
    }

    @Test func launchPreservesExactWorkingDirectoryAndValidatedDefinitionIdentity() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(rootGenerationID: UUID(), captureKind: .autosave)
        let bytes = Data("snapshot".utf8)
        let exactWorkingDirectory = fixture.root.appendingPathComponent(" working ", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exactWorkingDirectory,
            withIntermediateDirectories: true
        )
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: bytes,
            source: .manualBackup
        ))

        let result = try #require(plan(from: fixture.coordinator.authorize(fixture.request(
            identity: identity,
            source: .manualBackup,
            snapshotBytes: bytes,
            savedWorkingDirectory: exactWorkingDirectory.path
        ))))
        let launch = try #require(result.launchItems.first)
        #expect(launch.definitionID == .hunk)
        #expect(launch.savedWorkingDirectory == exactWorkingDirectory.path)
        #expect(launch.originalPanelID == fixture.lastPanelID)
    }

    @Test func remoteAndMissingWorkingDirectoryCandidatesRefuseWithPaneProvenance() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(rootGenerationID: UUID(), captureKind: .autosave)
        let bytes = Data("snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: bytes,
            source: .manualBackup
        ))
        let remotePanelID = UUID()
        let missingDirectoryPanelID = UUID()
        let fingerprint = try #require(
            RestartCommandDefinitionSet.appDefaults.detectorFingerprint(for: .hunk)
        )
        let binding = PaneRestartCommandBinding(
            definitionID: .hunk,
            detectorFingerprint: fingerprint,
            observedAt: 100,
            snapshotIdentity: identity
        )
        let request = RestartCommandAuthorizationRequest(
            source: .manualBackup,
            envelope: RestartCommandSnapshotEnvelope(identity: identity),
            fileDigest: RestartCommandDefinitionSet.sha256Hex(bytes),
            candidates: [
                RestartCommandPaneCandidate(
                    panelID: remotePanelID,
                    binding: binding,
                    hasExistingResumeIntent: false,
                    isRemote: true,
                    savedWorkingDirectory: fixture.workingDirectory.path
                ),
                RestartCommandPaneCandidate(
                    panelID: missingDirectoryPanelID,
                    binding: binding,
                    hasExistingResumeIntent: false,
                    isRemote: false,
                    savedWorkingDirectory: fixture.root.appendingPathComponent("missing").path
                ),
            ]
        )

        let result = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(result.launchItems.isEmpty)
        #expect(Set(result.refusals.compactMap(\.panelID)) == Set([remotePanelID, missingDirectoryPanelID]))
        #expect(Set(result.refusals.map(\.reason)) == Set([.paneBecameRemote, .missingWorkingDirectory]))
        #expect(result.refusals.allSatisfy { $0.definitionID == .hunk })
    }

    private func plan(
        from outcome: RestartCommandAuthorizationOutcome
    ) -> RestartCommandRestorePlan? {
        guard case .plan(let plan) = outcome else { return nil }
        return plan
    }

    private final class Fixture {
        let root: URL
        let workingDirectory: URL
        let definitions: RestartCommandDefinitionsRepository
        let coordinator: RestartCommandCoordinator
        private(set) var lastPanelID: UUID?

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-restart-command-tests-\(UUID().uuidString)", isDirectory: true)
            workingDirectory = root.appendingPathComponent("working", isDirectory: true)
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            definitions = RestartCommandDefinitionsRepository(
                definitionsFileURL: root.appendingPathComponent("restart-commands.json")
            )
            coordinator = RestartCommandCoordinator(
                definitionsRepository: definitions,
                stateRepository: RestartCommandStateRepository(
                    fileURL: root.appendingPathComponent("restart-command-state.json")
                )
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func request(
            identity: RestartCommandSnapshotIdentity,
            source: RestartCommandRestoreSource,
            snapshotBytes: Data,
            hasExistingResumeIntent: Bool = false,
            savedWorkingDirectory: String? = nil
        ) -> RestartCommandAuthorizationRequest {
            let fingerprint = RestartCommandDefinitionSet.appDefaults.detectorFingerprint(for: .hunk)!
            let panelID = UUID()
            lastPanelID = panelID
            return RestartCommandAuthorizationRequest(
                source: source,
                envelope: RestartCommandSnapshotEnvelope(identity: identity),
                fileDigest: RestartCommandDefinitionSet.sha256Hex(snapshotBytes),
                candidates: [
                    RestartCommandPaneCandidate(
                        panelID: panelID,
                        binding: PaneRestartCommandBinding(
                            definitionID: .hunk,
                            detectorFingerprint: fingerprint,
                            observedAt: 100,
                            snapshotIdentity: identity
                        ),
                        hasExistingResumeIntent: hasExistingResumeIntent,
                        isRemote: false,
                        savedWorkingDirectory: savedWorkingDirectory ?? workingDirectory.path
                    ),
                ]
            )
        }
    }
}
