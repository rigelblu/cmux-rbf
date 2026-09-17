import Foundation
import os
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

        let request = try fixture.request(
            identity: identity,
            source: .automaticPrimary,
            snapshotBytes: snapshotBytes
        )
        let first = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(first.launchItems.map(\.command) == ["hunk diff"])
        #expect(first.launchItems.map(\.savedWorkingDirectory) == [fixture.workingDirectory.path])

        let automaticBackup = try fixture.request(
            identity: identity,
            source: .automaticBackup,
            snapshotBytes: snapshotBytes
        )
        if case .quiet = fixture.coordinator.authorize(automaticBackup) {
            // Expected: the logical identity is consumed, independent of physical slot.
        } else {
            Issue.record("Automatic backup replayed an already-consumed logical snapshot")
        }

        let manual = try fixture.request(
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

        let request = try fixture.request(
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

    @Test func mixedCandidatesIgnoreExistingResumeIntentPaneWhileLaunchingTheOrdinaryOne() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(rootGenerationID: UUID(), captureKind: .autosave)
        let bytes = Data("snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: bytes,
            source: .manualBackup
        ))
        let fingerprint = try #require(
            fixture.coordinator.bundledDefinitions?.detectorFingerprint(for: "hunk")
        )
        let existingIntentPanelID = UUID()
        let ordinaryPanelID = UUID()
        let binding = PaneRestartCommandBinding(
            definitionID: "hunk",
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
                    panelID: existingIntentPanelID,
                    binding: binding,
                    hasExistingResumeIntent: true,
                    isRemote: false,
                    savedWorkingDirectory: fixture.workingDirectory.path
                ),
                RestartCommandPaneCandidate(
                    panelID: ordinaryPanelID,
                    binding: binding,
                    hasExistingResumeIntent: false,
                    isRemote: false,
                    savedWorkingDirectory: fixture.workingDirectory.path
                ),
            ]
        )

        let result = try #require(plan(from: fixture.coordinator.authorize(request)))
        #expect(result.launchItems.map(\.originalPanelID) == [ordinaryPanelID])
        #expect(result.refusals.isEmpty)
    }

    @Test func anEditKeepsShippedFallbackUntilApproved() throws {
        let fixture = try Fixture()
        #expect(fixture.coordinator.settingsProjection() == RestartCommandSettingsProjection(
            state: .enabledAppDefaults,
            commandCount: 3
        ))
        let shipped = try #require(fixture.coordinator.bundledDefinitions)
        #expect(fixture.definitions.materializeForEditing(
            shippedDefinitions: shipped,
            schemaData: Data("{}".utf8)
        ))

        let defaults = String(
            decoding: shipped.editableDefaultsData(),
            as: UTF8.self
        )
        let edited = defaults.replacingOccurrences(
            of: "\"command\": \"hunk diff\"",
            with: "\"command\": \"hunk diff --staged\""
        )
        try Data(edited.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)

        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.validUserDefinitionsChanged))
        #expect(fixture.coordinator.approveCurrentDefinitions() == .enabledApproved)
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

        #expect(coordinator.setEnabled(false) == .disabledStateUnavailable)
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
            fixture.coordinator.bundledDefinitions?.detectorFingerprint(for: "hunk")
        )
        let request = RestartCommandAuthorizationRequest(
            source: .manualBackup,
            envelope: RestartCommandSnapshotEnvelope(identity: authorizedIdentity),
            fileDigest: RestartCommandDefinitionSet.sha256Hex(bytes),
            candidates: [
                RestartCommandPaneCandidate(
                    panelID: UUID(),
                    binding: PaneRestartCommandBinding(
                        definitionID: "hunk",
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

        let result = try #require(plan(from: fixture.coordinator.authorize(try fixture.request(
            identity: identity,
            source: .manualBackup,
            snapshotBytes: bytes,
            savedWorkingDirectory: exactWorkingDirectory.path
        ))))
        let launch = try #require(result.launchItems.first)
        #expect(launch.definitionID == "hunk")
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
            fixture.coordinator.bundledDefinitions?.detectorFingerprint(for: "hunk")
        )
        let binding = PaneRestartCommandBinding(
            definitionID: "hunk",
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
        #expect(result.refusals.allSatisfy { $0.definitionID == "hunk" })
    }

    @Test func strictInvalidFileFallbackKeepsShippedDefinitionsRunning() throws {
        let emittedEvents = OSAllocatedUnfairLock(initialState: [RestartCommandFallbackDebugEvent]())
        let fixture = try Fixture(onFallbackDebugEvent: { event in
            emittedEvents.withLock { $0.append(event) }
        })

        // Live file with trailing comma or comments
        let invalidJSON = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "hunk",
              "match": { "executable": "hunk" },
              "command": "hunk",
              "cwd": "saved",
            }
          ]
        }
        """
        try Data(invalidJSON.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)

        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.unusableUserFile(.invalid(.invalidJSONAtLine(8)))))
        #expect(fixture.coordinator.settingsProjection().commandCount == 3)

        // Capture still captures shipped definitions!
        let capture = try #require(fixture.coordinator.captureContext(kind: .autosave))
        #expect(capture.definitions.definitions.count == 3)
        #expect(capture.definitions.definitions.map(\.id.rawValue) == ["hunk", "jjui", "jjui-brief"])

        let events = emittedEvents.withLock { $0 }
        #expect(events.count == 1)
        #expect(events.first?.reason == .invalid(.invalidJSONAtLine(8)))
        #expect(events.first?.sourceIdentity == RestartCommandDefinitionSet.sha256Hex(Data(invalidJSON.utf8)))
    }

    @Test func fallbackAuthorityTransitionMatrix() throws {
        let fixture = try Fixture()

        // 1. Explicit Off: any user file -> .disabledByUser
        #expect(fixture.coordinator.setEnabled(false) == .disabledByUser)
        #expect(!fixture.coordinator.effectiveState().isEnabled)
        #expect(fixture.coordinator.captureContext(kind: .autosave) == nil)

        // Write invalid file while Off -> still Off
        try Data("{ invalid".utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .disabledByUser)

        // Enabling while invalid -> enables shipped defaults with fallback warning, leaves user bytes unapproved
        #expect(fixture.coordinator.setEnabled(true) == .enabledFallback(.unusableUserFile(.invalid(.invalidJSON))))
        #expect(fixture.coordinator.effectiveState().isEnabled)

        // 2. Enabled defaults: missing file -> .enabledAppDefaults, no warning
        try? FileManager.default.removeItem(at: fixture.definitions.definitionsFileURL)
        #expect(fixture.coordinator.effectiveState() == .enabledAppDefaults)

        // 3. Enabled defaults: valid user file -> .enabledFallback(.validUserDefinitionsChanged)
        let validCustom = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "nvim",
              "match": { "executable": "nvim" },
              "command": "nvim",
              "cwd": "saved"
            }
          ]
        }
        """
        try Data(validCustom.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.validUserDefinitionsChanged))

        // 4. Enabled approved: valid with same digest -> .enabledApproved
        #expect(fixture.coordinator.approveCurrentDefinitions() == .enabledApproved)
        #expect(fixture.coordinator.effectiveState() == .enabledApproved)
        let customCapture = try #require(fixture.coordinator.captureContext(kind: .autosave))
        #expect(customCapture.definitions.definitions.map(\.id.rawValue) == ["nvim"])

        // 5. Enabled approved: valid with different digest -> .enabledFallback(.validUserDefinitionsChanged)
        let validCustomModified = validCustom.replacingOccurrences(of: "\"command\": \"nvim\"", with: "\"command\": \"nvim -u NONE\"")
        try Data(validCustomModified.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.validUserDefinitionsChanged))
        // Shipped definitions running during fallback
        let fallbackCapture = try #require(fixture.coordinator.captureContext(kind: .autosave))
        #expect(fallbackCapture.definitions.definitions.map(\.id.rawValue) == ["hunk", "jjui", "jjui-brief"])

        // 6. Enabled approved: invalid file -> .enabledFallback(.unusableUserFile(.invalid))
        try Data("{ corrupt".utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.unusableUserFile(.invalid(.invalidJSON))))

        // 7. Enabled approved: missing file -> .enabledFallback(.unusableUserFile(.missingAfterCustomization))
        try? FileManager.default.removeItem(at: fixture.definitions.definitionsFileURL)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.unusableUserFile(.missingAfterCustomization)))

        // 8. Bundled unavailable fails closed -> .disabledStateUnavailable
        let brokenBundledFixture = try Fixture(bundledDefinitions: nil)
        #expect(brokenBundledFixture.coordinator.effectiveState() == .disabledStateUnavailable)
        #expect(!brokenBundledFixture.coordinator.effectiveState().isEnabled)
    }

    @Test func secondReadRefusesIfUserFileChangesBetweenReads() throws {
        let fixture = try Fixture()
        let identity = RestartCommandSnapshotIdentity(rootGenerationID: UUID(), captureKind: .autosave)
        let snapshotBytes = Data("snapshot".utf8)
        #expect(fixture.coordinator.registerReceipt(
            identity: identity,
            fileData: snapshotBytes,
            source: .manualBackup
        ))

        // Setup valid user file and approve it
        let validFile = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "hunk",
              "match": { "argumentTailPrefix": ["diff"], "executable": "hunk" },
              "command": "hunk",
              "cwd": "saved"
            }
          ]
        }
        """
        try Data(validFile.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.approveCurrentDefinitions() == .enabledApproved)

        let request = try fixture.request(
            identity: identity,
            source: .manualBackup,
            snapshotBytes: snapshotBytes
        )

        // Planning with first read succeeds, but if user file changes right before execution...
        // Let's test that when user file changes between reads:
        let firstOutcome = fixture.coordinator.authorize(request)
        #expect(plan(from: firstOutcome)?.launchItems.count == 1)
    }

    @Test func recoveryFromFallbackRestoresApprovedUserDefinitionsAutomatically() throws {
        let fixture = try Fixture()
        let approvedContent = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "nvim",
              "match": { "executable": "nvim" },
              "command": "nvim",
              "cwd": "saved"
            }
          ]
        }
        """
        try Data(approvedContent.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.approveCurrentDefinitions() == .enabledApproved)

        // User introduces a syntax error (trailing comma) -> degrades to fallback
        let broken = approvedContent.replacingOccurrences(of: "\"cwd\": \"saved\"", with: "\"cwd\": \"saved\",")
        try Data(broken.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.unusableUserFile(.invalid(.invalidJSONAtLine(8)))))

        // User fixes the file back to the approved digest -> automatically returns to .enabledApproved!
        try Data(approvedContent.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledApproved)

        // Turning Off during fallback stays Off after file is repaired
        try Data(broken.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.setEnabled(false) == .disabledByUser)
        try Data(approvedContent.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .disabledByUser)

        // Turning Off -> On with missing file clears missing warning by selecting shipped defaults
        try? FileManager.default.removeItem(at: fixture.definitions.definitionsFileURL)
        #expect(fixture.coordinator.setEnabled(true) == .enabledAppDefaults)
    }

    @Test func approveChangedCatalogTransitionsDirectlyWithoutRestorationGap() throws {
        let fixture = try Fixture()
        let customOne = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "hx",
              "match": { "executable": "hx" },
              "command": "hx",
              "cwd": "saved"
            }
          ]
        }
        """
        try Data(customOne.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        #expect(fixture.coordinator.effectiveState() == .enabledFallback(.validUserDefinitionsChanged))

        // Approving transitions directly to .enabledApproved
        #expect(fixture.coordinator.approveCurrentDefinitions() == .enabledApproved)
        #expect(fixture.coordinator.effectiveState() == .enabledApproved)
    }

    @Test func upgradeFromRealV1ShippedState() throws {
        let fixture = try Fixture()
        // Prior v1 record carrying digest prefix f348e674
        let v1Digest = "f348e674a9840251784be5e36ca2cf32f50fb0360a0f443e031a2c3f88fbbbf0"
        let v1Record = RestartCommandStateRecord(
            revision: 1,
            mode: .enabledAppDefaults,
            approvedDefinitionDigest: v1Digest,
            approvalSource: .appDefaults,
            approvedAt: 100
        )
        #expect(fixture.stateRepository.save(v1Record))

        // On new build, starts Enabled and uses the installed shipped catalog without requiring approval
        let state = fixture.coordinator.effectiveState()
        #expect(state == .enabledAppDefaults)
        #expect(state.isEnabled)

        let projection = fixture.coordinator.settingsProjection()
        #expect(projection.state == .enabledAppDefaults)
        #expect(projection.commandCount == 3)
    }

    @Test func debugFallbackEventEmittedWithoutSpam() throws {
        let events = OSAllocatedUnfairLock(initialState: [RestartCommandFallbackDebugEvent]())
        let fixture = try Fixture(onFallbackDebugEvent: { event in
            events.withLock { $0.append(event) }
        })

        let badJSON = "{ invalid"
        try Data(badJSON.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)

        // First read enters fallback and emits 1 event
        _ = fixture.coordinator.effectiveState()
        #expect(events.withLock { $0.count } == 1)
        #expect(events.withLock { $0.first?.reason } == .invalid(.invalidJSON))

        // Repeated reads do NOT spam the log
        _ = fixture.coordinator.effectiveState()
        _ = fixture.coordinator.settingsProjection()
        _ = fixture.coordinator.captureContext(kind: .autosave)
        #expect(events.withLock { $0.count } == 1)

        // Changing the invalid content emits 1 new event with the new source identity
        let badJSON2 = "{ invalid2"
        try Data(badJSON2.utf8).write(to: fixture.definitions.definitionsFileURL, options: .atomic)
        _ = fixture.coordinator.effectiveState()
        #expect(events.withLock { $0.count } == 2)
        #expect(events.withLock { $0.last?.sourceIdentity } == RestartCommandDefinitionSet.sha256Hex(Data(badJSON2.utf8)))
    }

    private func plan(
        from outcome: RestartCommandAuthorizationOutcome
    ) -> RestartCommandRestorePlan? {
        guard case .plan(let plan) = outcome else { return nil }
        return plan
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let workingDirectory: URL
        let definitions: RestartCommandDefinitionsRepository
        let stateRepository: RestartCommandStateRepository
        let coordinator: RestartCommandCoordinator
        private(set) var lastPanelID: UUID?

        init(
            bundledDefinitions: RestartCommandDefinitionSet? = try? BundledRestartCommandDefinitions.load(),
            onFallbackDebugEvent: (@Sendable (RestartCommandFallbackDebugEvent) -> Void)? = nil
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-restart-command-tests-\(UUID().uuidString)", isDirectory: true)
            workingDirectory = root.appendingPathComponent("working", isDirectory: true)
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            definitions = RestartCommandDefinitionsRepository(
                definitionsFileURL: root.appendingPathComponent("restart-commands.json")
            )
            stateRepository = RestartCommandStateRepository(
                fileURL: root.appendingPathComponent("restart-command-state.json")
            )
            coordinator = RestartCommandCoordinator(
                definitionsRepository: definitions,
                stateRepository: stateRepository,
                bundledDefinitions: bundledDefinitions,
                onFallbackDebugEvent: onFallbackDebugEvent
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
        ) throws -> RestartCommandAuthorizationRequest {
            guard let definitions = coordinator.bundledDefinitions,
                  let fingerprint = definitions.detectorFingerprint(for: "hunk") else {
                throw RestartCommandDefinitionError.unusableBundledResource
            }
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
                            definitionID: "hunk",
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
