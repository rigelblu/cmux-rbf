import Foundation

extension AppDelegate {
    func syncManualRestoreSnapshotCachePruningCrashDiagnostics() {
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
            if !Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
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
