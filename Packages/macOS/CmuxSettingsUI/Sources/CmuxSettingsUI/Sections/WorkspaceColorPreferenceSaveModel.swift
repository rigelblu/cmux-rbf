import CmuxSettings
import Observation

/// Holds the previous saved controls while one preference action is committing.
@MainActor
@Observable
final class WorkspaceColorPreferenceSaveModel {
    private(set) var isSaving = false
    private(set) var error: WorkspaceColorSettingsSnapshot.SaveError?
    private(set) var lastAction: WorkspaceColorSettingsSnapshot.Action?

    /// Serializes UI actions without an optimistic copy of the preference.
    func save(
        _ action: WorkspaceColorSettingsSnapshot.Action,
        expected: WorkspaceColorSettingsSnapshot,
        using commit: @MainActor (WorkspaceColorSettingsSnapshot.Action, WorkspaceColorSettingsSnapshot) async throws -> WorkspaceColorSettingsSnapshot,
        accept: @MainActor (WorkspaceColorSettingsSnapshot) -> Void
    ) async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        lastAction = action
        defer { isSaving = false }
        do {
            accept(try await commit(action, expected))
        } catch let failure as WorkspaceColorSettingsSnapshot.SaveError {
            error = failure
        } catch {
            self.error = .failed
        }
    }
}
