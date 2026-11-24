import CmuxFoundation
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
        await loadOnWorker(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            maximumSnapshotAge: 5,
            ttyDeviceBindings: ttyDeviceBindings,
            restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
            restartCommandCaptureContext: restartCommandCaptureContext
        )
    }

    /// Loads current hook stores and captures an uncached process snapshot off-main.
    static func loadFresh(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await loadFreshOnWorker(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            ttyDeviceBindings: ttyDeviceBindings,
            restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
            restartCommandCaptureContext: restartCommandCaptureContext
        )
    }

    /// Loads fresh process state with a bounded lifecycle deadline.
    @MainActor
    static func loadFreshWithDeadline(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil,
        processSnapshotService: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>? = nil,
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
            let result = await loadFreshOnWorker(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                ttyDeviceBindings: ttyDeviceBindings,
                restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
                restartCommandCaptureContext: restartCommandCaptureContext,
                processSnapshotService: processSnapshotService
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

    /// Worker implementation for detached loading and focused tests.
    /// Main-actor lifecycle paths must call ``loadFresh(homeDirectory:fileManager:)``.
    static func loadFreshOnWorker(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil,
        processSnapshotService: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await loadOnWorker(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            ttyDeviceBindings: ttyDeviceBindings,
            restartCommandPanelTTYDevices: restartCommandPanelTTYDevices,
            restartCommandCaptureContext: restartCommandCaptureContext,
            processSnapshotService: processSnapshotService
        )
    }

    /// Returns the last published agent index without filesystem or process capture.
    ///
    /// This is the bounded fallback for a watchdog whose fresh capture already
    /// exceeded its deadline, and for the synchronous update-relaunch save.
    /// No surface scan ran, so the binding index is unavailable rather than an
    /// empty clean scan: a clean scan would retire every agent-hook binding the
    /// cached agent index has not seen yet. For the same reason the agent
    /// index is marked incomplete, so a session the cache has not seen is not
    /// saved as stopped (#20186).
    static func cached(
        restorableAgentIndex: RestorableAgentSessionIndex
    ) -> ProcessDetectedResumeIndexes {
        ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex.markingIncomplete(),
            surfaceResumeBindingIndex: .unavailable
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    static func loadOnWorker(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        cachedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:],
        restartCommandPanelTTYDevices: [RestartCommandPanelKey: Int64] = [:],
        restartCommandCaptureContext: RestartCommandCaptureContext? = nil,
        restartCommandProcessBytes: @Sendable (Int) -> [UInt8]? = {
            CmuxTopProcessSnapshot.kernProcArgsBytes(for: $0)
        },
        processSnapshotService: ProcessSnapshotService<CmuxTopProcessCapture, CmuxTopProcessFields>? = nil
    ) async -> ProcessDetectedResumeIndexes {
        // `nil` uses the app's shared census. Tests inject their own so a
        // fixture never depends on the whole host's process table.
        let processSnapshot = if let maximumSnapshotAge {
            await CmuxTopProcessSnapshot.captureCached(
                includeProcessDetails: true, includeResources: false,
                maximumAge: maximumSnapshotAge, service: processSnapshotService
            )
        } else {
            await CmuxTopProcessSnapshot.capture(
                includeProcessDetails: true, includeResources: false, service: processSnapshotService
            )
        }
        guard processSnapshot.captureIsAvailable, processSnapshot.enumerationIsComplete, !Task.isCancelled else {
            return ProcessDetectedResumeIndexes(restorableAgentIndex: .unavailable, surfaceResumeBindingIndex: .unavailable)
        }
        let capturedAt = processSnapshot.sampledAt.timeIntervalSince1970
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
