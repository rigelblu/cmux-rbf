import Foundation
import CmuxRestartCommands

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
                ttyDeviceBindings: ttyDeviceBindings,
                restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
                restartCommandCaptureContext: restartCommandCaptureContext
            )
        }.value
    }

    /// Loads current hook stores and captures an uncached process snapshot off-main.
    static func loadFresh(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadFreshSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                ttyDeviceBindings: ttyDeviceBindings,
                restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
                restartCommandCaptureContext: restartCommandCaptureContext
            )
        }.value
    }

    /// Loads fresh process state with a bounded lifecycle deadline.
    @MainActor
    static func loadFreshWithDeadline(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil,
        deadline: Duration = .seconds(5),
        onWorkerCreated: @escaping @MainActor @Sendable (
            Task<ProcessDetectedResumeIndexes, Never>
        ) -> Void = { _ in },
        sleepUntilDeadline: @escaping @Sendable (Duration) async -> Bool = { duration in
            do {
                // Genuine recovery deadline; cancellation returns the fail-closed result.
                try await ContinuousClock().sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) async -> ProcessDetectedResumeIndexes? {
        let (workerFinished, workerFinishedContinuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached(priority: .utility) {
            let result = loadFreshSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                ttyDeviceBindings: ttyDeviceBindings,
                restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
                restartCommandCaptureContext: restartCommandCaptureContext
            )
            workerFinishedContinuation.yield(())
            return result
        }
        onWorkerCreated(worker)
        return await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var iterator = workerFinished.makeAsyncIterator()
                _ = await iterator.next()
                return 0
            }
            group.addTask { await sleepUntilDeadline(deadline) ? 1 : 2 }
            let winner = await group.next() ?? 2
            workerFinishedContinuation.finish()
            group.cancelAll()
            guard winner == 0 else { worker.cancel(); return nil }
            return await worker.value
        }
    }

    static func loadFreshSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil
    ) -> ProcessDetectedResumeIndexes {
        loadSynchronously(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            ttyDeviceBindings: ttyDeviceBindings,
            restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
            restartCommandCaptureContext: restartCommandCaptureContext
        )
    }

    /// Bounded fallback without process capture. Process-backed bindings fail closed.
    static func cached(
        restorableAgentIndex: RestorableAgentSessionIndex
    ) -> ProcessDetectedResumeIndexes {
        ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: .empty
        )
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        cachedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
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
        let restorableAgentIndex: RestorableAgentSessionIndex
        if let cachedRestorableAgentIndex {
            restorableAgentIndex = cachedRestorableAgentIndex.revalidatingCachedProcesses(
                against: processSnapshot
            )
        } else {
            let registry = CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: capturedAt
            )
            restorableAgentIndex = RestorableAgentSessionIndex.load(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: detectedSnapshots
            )
        }
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            ttyDeviceBindings: ttyDeviceBindings
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
