import Foundation

extension AppDelegate {
    /// Returns whether a missing primary snapshot has an independent recovery
    /// signal. A clean missing primary still means the user intentionally began
    /// fresh, while an unclean launch or crash-only teardown marker means the
    /// `-previous` generation is the safe source of truth.
    nonisolated static func shouldRecoverMissingPrimarySessionSnapshot(
        previousLaunchWasUnclean: Bool,
        crashOnlyPrimarySnapshotRemovalMarker: Bool
    ) -> Bool {
        previousLaunchWasUnclean || crashOnlyPrimarySnapshotRemovalMarker
    }

    /// Synchronizes the manual-restore cache while preserving a known-good
    /// generation across an unclean launch. A primary snapshot can be valid JSON
    /// yet represent a partially completed restore; keeping the prior copy gives
    /// the user a rollback path and avoids destroying the only intact snapshot.
    func syncManualRestoreSnapshotCachePruningCrashDiagnostics(
        preserveExistingBackup: Bool = false
    ) {
        guard let primaryURL = sessionSnapshotStore.defaultSnapshotFileURL(),
              let backupURL = sessionSnapshotStore.manualRestoreSnapshotFileURL() else {
            return
        }
        switch sessionSnapshotStore.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot, _):
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
            guard let prunedSnapshot = SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot else {
                return
            }
            if preserveExistingBackup,
               case .loaded = sessionSnapshotStore.loadOutcome(fileURL: backupURL) {
                return
            }
            let didSave = sessionSnapshotStore.save(prunedSnapshot, fileURL: backupURL)
            if didSave,
               let identity = prunedSnapshot.restartCommandEnvelope?.validatedIdentity,
               let fileData = try? Data(contentsOf: backupURL) {
                _ = restartCommandCoordinator.registerReceipt(
                    identity: identity,
                    fileData: fileData,
                    source: .manualBackup
                )
            } else if didSave {
                restartCommandCoordinator.clearReceipt(source: .manualBackup)
            }
        case .missing:
            restartCommandCoordinator.clearReceipt(source: .automaticPrimary)
            if !preserveExistingBackup && !Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
                sessionSnapshotStore.removeSnapshot(fileURL: backupURL)
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    restartCommandCoordinator.clearReceipt(source: .manualBackup)
                }
            }
        case .unusable:
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
            restartCommandCoordinator.clearReceipt(source: .automaticPrimary)
        }
    }

    private nonisolated static var crashOnlyPrimarySnapshotRemovalDefaultsKey: String {
        "cmux.session.crashOnlyPrimarySnapshotRemoval.v1"
    }

    nonisolated static func markCrashOnlyPrimarySnapshotRemoval(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    nonisolated static func hasCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    nonisolated static func clearCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }
}
