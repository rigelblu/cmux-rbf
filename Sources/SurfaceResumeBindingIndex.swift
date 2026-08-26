import Foundation
import CmuxRestartCommands

struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]
    private let restartCommandBindingsByPanel: [RestartCommandPanelKey: PaneRestartCommandBinding]

    init(
        bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot],
        restartCommandBindingsByPanel: [RestartCommandPanelKey: PaneRestartCommandBinding] = [:]
    ) {
        self.bindingsByPanel = bindingsByPanel
        self.restartCommandBindingsByPanel = restartCommandBindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            let existing = bindingsByPanelId[key.panelId]
            if existing == nil || binding.updatedAt >= (existing?.updatedAt ?? 0) {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    func restartCommandBinding(workspaceId: UUID, panelId: UUID) -> PaneRestartCommandBinding? {
        restartCommandBindingsByPanel[
            RestartCommandPanelKey(workspaceID: workspaceId, panelID: panelId)
        ]
    }

    var restartCommandBindingFingerprint: Int {
        var hasher = Hasher()
        for (key, binding) in restartCommandBindingsByPanel.sorted(by: {
            if $0.key.workspaceID != $1.key.workspaceID {
                return $0.key.workspaceID.uuidString < $1.key.workspaceID.uuidString
            }
            return $0.key.panelID.uuidString < $1.key.panelID.uuidString
        }) {
            hasher.combine(key.workspaceID)
            hasher.combine(key.panelID)
            hasher.combine(binding.definitionID)
            hasher.combine(binding.detectorFingerprint)
            hasher.combine(binding.snapshotGenerationID)
            hasher.combine(binding.captureKind)
        }
        return hasher.finalize()
    }

    static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}
