import Foundation
import CmuxRestartCommands

struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]
    private let restartCommandBindingsByPanel: [RestartCommandPanelKey: PaneRestartCommandBinding]
    private let ambiguousPanelIds: Set<UUID>

    init(
        bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot],
        restartCommandBindingsByPanel: [RestartCommandPanelKey: PaneRestartCommandBinding] = [:]
    ) {
        self.bindingsByPanel = bindingsByPanel
        self.restartCommandBindingsByPanel = restartCommandBindingsByPanel
        var candidatesByPanelId: [UUID: [SurfaceResumeBindingSnapshot]] = [:]
        for (key, binding) in bindingsByPanel {
            candidatesByPanelId[key.panelId, default: []].append(binding)
        }

        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        var ambiguousPanelIds: Set<UUID> = []
        for (panelId, candidates) in candidatesByPanelId {
            guard var selected = candidates.first else {
                continue
            }
            for candidate in candidates.dropFirst() {
                if candidate.isProcessDetected != selected.isProcessDetected {
                    if candidate.isProcessDetected { selected = candidate }
                    continue
                }
                if candidate.updatedAt != selected.updatedAt {
                    if candidate.updatedAt > selected.updatedAt { selected = candidate }
                    continue
                }
                let candidateIdentity = "\(candidate.kind ?? ""):\(candidate.checkpointId ?? candidate.command)"
                let selectedIdentity = "\(selected.kind ?? ""):\(selected.checkpointId ?? selected.command)"
                if candidateIdentity > selectedIdentity { selected = candidate }
            }
            let processDetectedCount = candidates.reduce(into: 0) { count, candidate in
                if candidate.isProcessDetected { count += 1 }
            }
            let topRankCount = candidates.reduce(into: 0) { count, candidate in
                guard candidate.isProcessDetected == selected.isProcessDetected,
                      candidate.updatedAt == selected.updatedAt else {
                    return
                }
                count += 1
            }
            if processDetectedCount > 1 || topRankCount > 1 {
                ambiguousPanelIds.insert(panelId)
            }
            bindingsByPanelId[panelId] = selected
        }
        self.bindingsByPanelId = bindingsByPanelId
        self.ambiguousPanelIds = ambiguousPanelIds
    }

    var isEmpty: Bool {
        bindingsByPanel.isEmpty
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
            ?? binding(panelId: panelId)
    }

    func binding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        guard !ambiguousPanelIds.contains(panelId) else { return nil }
        return bindingsByPanelId[panelId]
    }

    func hasAmbiguousPanel(_ panelId: UUID) -> Bool {
        ambiguousPanelIds.contains(panelId)
    }

    /// Resolves a restart-stable panel while preferring a process-detected binding for its owner.
    func bindingForStablePanel(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        let exact = bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
        if let exact, exact.isProcessDetected { return exact }
        guard !ambiguousPanelIds.contains(panelId) else { return nil }
        return bindingsByPanelId[panelId] ?? exact
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
