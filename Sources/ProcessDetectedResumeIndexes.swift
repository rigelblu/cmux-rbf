import Foundation
import CmuxRestartCommands

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
                restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
                restartCommandCaptureContext: restartCommandCaptureContext
            )
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil,
        restartCommandProcessBytes: @Sendable (Int) -> [UInt8]? = {
            CmuxTopProcessSnapshot.kernProcArgsBytes(for: $0)
        }
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let detectedRestartCommandBindings = restartCommandCaptureContext.map { context in
            restartCommandBindings(
                processSnapshot: processSnapshot,
                panelTTYDevices: restartCommandPanelTTYDevices,
                context: context,
                capturedAt: capturedAt,
                processBytes: restartCommandProcessBytes
            )
        } ?? [:]
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                bindingsByPanel: detectedBindings.mapValues(\.binding),
                restartCommandBindingsByPanel: detectedRestartCommandBindings
            )
        )
    }

    static func restartCommandBindings(
        processSnapshot: CmuxTopProcessSnapshot,
        panelTTYDevices: [RestartCommandPanelKey: Int64],
        context: RestartCommandCaptureContext,
        capturedAt: TimeInterval,
        processBytes: @Sendable (Int) -> [UInt8]?
    ) -> [RestartCommandPanelKey: PaneRestartCommandBinding] {
        guard !panelTTYDevices.isEmpty else { return [:] }
        let matcher = RestartCommandMatcher(definitions: context.definitions)
        let environmentKeys = Set(context.definitions.definitions.flatMap {
            $0.match.environment.map { Array($0.keys) } ?? []
        })
        let decoder = RestartCommandProcessEvidenceDecoder()
        var evidenceByPID: [Int: RestartCommandProcessEvidence] = [:]
        var unavailablePIDs: Set<Int> = []
        var bindings: [RestartCommandPanelKey: PaneRestartCommandBinding] = [:]

        for (panelKey, ttyDevice) in panelTTYDevices {
            let leaders = processSnapshot.pids(forTTYDevice: ttyDevice)
                .compactMap(processSnapshot.process(pid:))
                .filter { process in
                    process.isTerminalForegroundProcessGroup && process.processGroupID == process.pid
                }
                .sorted { $0.pid < $1.pid }
            guard leaders.count == 1, let process = leaders.first else { continue }

            let evidence: RestartCommandProcessEvidence
            if let cached = evidenceByPID[process.pid] {
                evidence = cached
            } else {
                guard !unavailablePIDs.contains(process.pid),
                      let bytes = processBytes(process.pid),
                      let decoded = decoder.decode(bytes, environmentKeys: environmentKeys) else {
                    unavailablePIDs.insert(process.pid)
                    continue
                }
                evidenceByPID[process.pid] = decoded
                evidence = decoded
            }
            guard let match = matcher.match(evidence) else { continue }
            bindings[panelKey] = PaneRestartCommandBinding(
                definitionID: match.definitionID,
                detectorFingerprint: match.detectorFingerprint,
                observedAt: capturedAt,
                snapshotIdentity: context.identity
            )
        }
        return bindings
    }
}
