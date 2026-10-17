import CmuxPanes
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              let resource = SurfaceCatalog.shared.resource(forPanel: target.surfaceID)
                ?? SurfaceCatalog.shared.resource(forPanel: target.containerPanelID),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        // cmux-rbf `#cm-73`: a Figma link goes to a Figma pane. Asked after the caller's settings checks, so a person's link settings win.
        if openClickedFigmaLink(
            url,
            sourcePanelId: target.containerPanelID,
            page: figmaClickEnvironment.page,
            defaults: figmaClickEnvironment.defaults
        ) { return true }
        // cmux-rbf #cm-73.2a
        let wasDesignFocusActive = isDesignFocusActive
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            if newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil {
                return true
            }
            if wasDesignFocusActive {
                let outcome = DesignFocusRouting.decide(
                    url: url,
                    showsAddressBar: true,
                    target: .newTab,
                    asker: .user,
                    wantsFocus: true,
                    modeEnabled: true
                )
                if outcome == .externalBrowser {
                    return true
                }
            }
            return false
        }
        if newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url
        ) != nil {
            return true
        }
        if wasDesignFocusActive {
            let outcome = DesignFocusRouting.decide(
                url: url,
                showsAddressBar: true,
                target: .newSplit,
                asker: .user,
                wantsFocus: true,
                modeEnabled: true
            )
            if outcome == .externalBrowser {
                return true
            }
        }
        return false
    }
}
