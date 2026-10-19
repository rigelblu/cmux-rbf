import Bonsplit
import CmuxAgentChat
import Foundation

extension Workspace {
    func recordFigmaBoardOpen(panel: BrowserPanel, sourcePanelID: UUID, url: URL?,
                             orientation: BoardLayoutOrientation,
                             registry: AgentChatSessionRegistry? = nil) {
        let registry = registry ?? TerminalController.shared.agentChatTranscriptService?.registry
        guard let terminal = panels[sourcePanelID] as? TerminalPanel,
              let record = registry?.liveSession(surfaceID: sourcePanelID.uuidString),
              record.agentKind == .claude || record.agentKind == .codex,
              !record.sessionID.isEmpty,
              let fileKey = url.flatMap({ FigmaPaneURL.fileKey(fromPaneURL: $0) }) else { return }
        let conversation = FigmaBoardLayoutBinding.Conversation(
            panelID: sourcePanelID, kind: record.agentKind, sessionID: record.sessionID
        )
        panel.figmaBoardLayoutBinding = FigmaBoardLayoutBinding(
            conversation: conversation, fileKey: fileKey, orientation: orientation
        )
        terminal.lastFigmaBoardOpen[conversation] = .init(panelID: panel.id, fileKey: fileKey)
    }

    /// Current URL and live conversation are authority, never the recent-files observation.
    private func matchingBoardTarget(registry: AgentChatSessionRegistry) -> (BrowserPanel, AgentChatSessionRecord)? {
        guard isDesignFocusActive, bonsplitController.zoomedPaneId == nil,
              let pair = bonsplitController.pairZoomPanes,
              let terminalTab = bonsplitController.selectedTab(inPane: pair.first)?.id,
              let terminalID = panelIdFromSurfaceId(terminalTab), let terminal = panels[terminalID] as? TerminalPanel,
              let figmaTab = bonsplitController.selectedTab(inPane: pair.second)?.id,
              let figmaID = panelIdFromSurfaceId(figmaTab), let panel = panels[figmaID] as? BrowserPanel,
              let binding = panel.figmaBoardLayoutBinding,
              let record = registry.liveSession(surfaceID: terminalID.uuidString) else { return nil }
        let conversation = FigmaBoardLayoutBinding.Conversation(
            panelID: terminalID, kind: record.agentKind, sessionID: record.sessionID
        )
        let key = (panel.currentURL ?? panel.webView.url).flatMap { FigmaPaneURL.fileKey(fromPaneURL: $0) }
        guard binding.matches(conversation: conversation, panelID: figmaID, currentFileKey: key,
                              lastOpen: terminal.lastFigmaBoardOpen[conversation]) else { return nil }
        return (panel, record)
    }

    func boardControlState(registry: AgentChatSessionRegistry?) -> PairBoardControlState? {
        guard isDesignFocusActive else { return nil }
        guard let registry, let (panel, record) = matchingBoardTarget(registry: registry),
              let binding = panel.figmaBoardLayoutBinding else { return PairBoardControlState() }
        let available = FigmaDesignHandOff.isAvailable(record)
        return PairBoardControlState(litOrientation: binding.orientation, pin: panel.keepsBoardLayoutOnFlip,
                                     boardEnabled: available, pinEnabled: true,
                                     unavailableReason: available ? nil : .busyAgent)
    }

    @discardableResult
    func handOffBoardLayout(_ orientation: BoardLayoutOrientation, requireChange: Bool,
                            registry: AgentChatSessionRegistry? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            deliver: ((UUID, [TextBoxSubmit.DispatchEvent]) -> Void)? = nil) -> Bool {
        let registry = registry ?? TerminalController.shared.agentChatTranscriptService?.registry
        guard let registry, let (panel, _) = matchingBoardTarget(registry: registry),
              let binding = panel.figmaBoardLayoutBinding,
              binding.orientation != orientation,
              !requireChange || !panel.keepsBoardLayoutOnFlip else { return false }
        let job: FigmaDesignHandOff.Job = orientation == .vertical ? .layoutVertical : .layoutHorizontal
        let sent = FigmaDesignHandOff.send(job, to: binding.conversation, in: self, registry: registry,
                                         home: home, validateTarget: { [weak self, weak panel] in
            guard let self, let panel, let (current, _) = self.matchingBoardTarget(registry: registry) else { return false }
            return current === panel && (!requireChange || !panel.keepsBoardLayoutOnFlip)
        }, deliver: deliver)
        if sent { panel.figmaBoardLayoutBinding?.orientation = orientation }
        return sent
    }

    @discardableResult
    func toggleBoardLayoutPin(registry: AgentChatSessionRegistry?) -> Bool {
        guard let registry, let (panel, _) = matchingBoardTarget(registry: registry) else { return false }
        panel.keepsBoardLayoutOnFlip.toggle()
        return true
    }

    func pairBoardControlState(for controller: BonsplitController) -> PairBoardControlState? {
        boardControlState(registry: TerminalController.shared.agentChatTranscriptService?.registry)
    }

    func splitTabBar(_ controller: BonsplitController, didChooseBoardLayout orientation: BoardLayoutOrientation) {
        _ = handOffBoardLayout(orientation, requireChange: false)
    }

    func splitTabBarDidTogglePin(_ controller: BonsplitController) {
        _ = toggleBoardLayoutPin(registry: TerminalController.shared.agentChatTranscriptService?.registry)
    }
}
