import AppKit
import Bonsplit
import CmuxPanes
import CmuxRemoteSession
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct DirectionalSplitActionTests {
    private struct DirectionCase: Sendable, CustomTestStringConvertible {
        let direction: SplitDirection
        let orientation: String
        let insertFirst: Bool
        let axis: Axis

        enum Axis: Sendable, Equatable {
            case horizontal
            case vertical
        }

        var testDescription: String {
            switch direction {
            case .left: "left"
            case .right: "right"
            case .up: "up"
            case .down: "down"
            }
        }
    }

    private static let directions = [
        DirectionCase(direction: .left, orientation: "horizontal", insertFirst: true, axis: .horizontal),
        DirectionCase(direction: .right, orientation: "horizontal", insertFirst: false, axis: .horizontal),
        DirectionCase(direction: .up, orientation: "vertical", insertFirst: true, axis: .vertical),
        DirectionCase(direction: .down, orientation: "vertical", insertFirst: false, axis: .vertical),
    ]

    @Test("Directional built-ins retain stable IDs, directional icons, and compatible routing")
    func directionalBuiltInManifest() {
        #expect(CmuxSurfaceTabBarBuiltInAction.splitLeft.configID == "cmux.splitLeft")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitUp.configID == "cmux.splitUp")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitRight.configID == "cmux.splitRight")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitDown.configID == "cmux.splitDown")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitLeft.defaultIcon == "rectangle.lefthalf.inset.filled")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitRight.defaultIcon == "rectangle.righthalf.inset.filled")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitUp.defaultIcon == "rectangle.tophalf.inset.filled")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitDown.defaultIcon == "rectangle.bottomhalf.inset.filled")
        #expect(CmuxSurfaceTabBarBuiltInAction.splitLeft.bonsplitAction == nil)
        #expect(CmuxSurfaceTabBarBuiltInAction.splitUp.bonsplitAction == nil)
        #expect(CmuxSurfaceTabBarBuiltInAction.splitRight.bonsplitAction == .splitRight)
        #expect(CmuxSurfaceTabBarBuiltInAction.splitDown.bonsplitAction == .splitDown)
    }

    @Test("Directional built-ins decode canonical and short config IDs")
    func directionalBuiltInConfigIDs() {
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.splitLeft") == .splitLeft)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "splitLeft") == .splitLeft)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.splitUp") == .splitUp)
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "splitUp") == .splitUp)
    }

    @Test("Remote embedded tab controls expose disabled Left and Up with localized help")
    func remoteEmbeddedSplitButtonCapability() {
        var configuration = BonsplitConfiguration()
        configuration.appearance.splitButtons = [
            .init(id: "left", systemImage: "arrow.left", action: .custom("cmux.splitLeft")),
            .init(id: "right", systemImage: "arrow.right", action: .custom("cmux.splitRight")),
            .init(id: "up", systemImage: "arrow.up", action: .custom("cmux.splitUp")),
            .init(id: "down", systemImage: "arrow.down", action: .custom("cmux.splitDown")),
        ]

        let buttons = configuration.remoteTmuxEmbedded.appearance.splitButtons
        #expect(buttons.map(\.id) == ["left", "right", "up", "down"])
        #expect(buttons[0].isEnabled == false)
        #expect(buttons[0].tooltip == TerminalSplitUnsupportedReason.remoteMirrorCannotInsertBefore.localizedHelp)
        #expect(buttons[1].isEnabled)
        #expect(buttons[2].isEnabled == false)
        #expect(buttons[2].tooltip == TerminalSplitUnsupportedReason.remoteMirrorCannotInsertBefore.localizedHelp)
        #expect(buttons[3].isEnabled)
    }

    @Test("A configured Split Right tab-bar action still splits a non-terminal pane")
    func splitRightTabBarActionSupportsNonTerminalSelection() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let workspace = fixture.workspace
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(workspace.newFilePreviewSurface(
            inPane: pane,
            filePath: "/tmp/cmux-cm2-tab-bar-non-terminal.md",
            focus: true
        ))
        workspace.applySurfaceTabBarButtons(
            [.builtIn(.splitRight)],
            sourcePath: nil,
            globalConfigPath: "/tmp/cmux-cm2-tab-bar.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:]
        )

        let button = try #require(workspace.bonsplitController.configuration.appearance.splitButtons.first)
        let paneCountBefore = workspace.bonsplitController.allPaneIds.count
        perform(
            button: button,
            in: pane,
            controller: workspace.bonsplitController
        )

        #expect(workspace.bonsplitController.allPaneIds.count == paneCountBefore + 1)
        let focusedPane = try #require(workspace.bonsplitController.focusedPaneId)
        let focusedTab = try #require(workspace.bonsplitController.selectedTab(inPane: focusedPane))
        let focusedPanelID = try #require(workspace.panelIdFromSurfaceId(focusedTab.id))
        #expect(workspace.terminalPanel(for: focusedPanelID) != nil)
    }

    @Test("Embedded remote Split Right follows the actual configured tab-bar action")
    func remoteEmbeddedSplitRightRoutesThroughConfiguredAction() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(connectedTransport: true)
        defer { harness.tearDown() }
        var configuration = BonsplitConfiguration()
        configuration.appearance.splitButtons = [
            .init(
                id: "right",
                systemImage: "rectangle.righthalf.inset.filled",
                action: CmuxSurfaceTabBarBuiltInAction.splitRight.bonsplitAction
                    ?? .custom(CmuxSurfaceTabBarBuiltInAction.splitRight.configID)
            ),
        ]
        harness.mirror.applyWorkspaceBonsplitConfiguration(configuration)

        let button = try #require(harness.mirror.bonsplitController.configuration.appearance.splitButtons.first)
        let pane = try #require(harness.mirror.bonsplitController.allPaneIds.first)
        perform(
            button: button,
            in: pane,
            controller: harness.mirror.bonsplitController
        )

        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let output = String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ) ?? ""
        let splitCommands = output.split(separator: "\n").filter { $0.hasPrefix("split-window ") }
        #expect(splitCommands.count == 1)
        #expect(splitCommands.first?.contains(" -h ") == true)
    }

    @Test("Explicit workspace splits preserve direction and focus", arguments: directions)
    private func explicitWorkspaceSplit(_ testCase: DirectionCase) throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        let sourcePanelID = try #require(fixture.workspace.focusedPanelId)
        let sourcePaneID = try #require(fixture.workspace.paneId(forPanelId: sourcePanelID)).id.uuidString
        let panelCountBefore = fixture.workspace.panels.count

        let result = fixture.appDelegate.executeTerminalSplit(
            direction: testCase.direction,
            source: .explicitWorkspacePane(
                workspaceId: fixture.workspace.id,
                panelId: sourcePanelID
            )
        )
        guard case .created(let createdPanelID) = result else {
            Issue.record("Expected a local pane for \(testCase.testDescription), got \(result)")
            return
        }

        #expect(fixture.workspace.panels.count == panelCountBefore + 1)
        #expect(fixture.workspace.focusedPanelId == createdPanelID)
        let createdPaneID = try #require(fixture.workspace.paneId(forPanelId: createdPanelID)).id.uuidString
        let root = try rootSplit(in: fixture.workspace)
        #expect(root.orientation == testCase.orientation)
        #expect(try paneID(in: testCase.insertFirst ? root.first : root.second) == createdPaneID)
        #expect(try paneID(in: testCase.insertFirst ? root.second : root.first) == sourcePaneID)
    }

    @Test("Explicit pane source wins over global window focus")
    func explicitPaneTargetsClickedWorkspaceAcrossWindows() throws {
        let first = try makeWorkspaceFixture()
        let second = try makeWorkspaceFixture()
        defer {
            closeWindow(second.windowID)
            closeWindow(first.windowID)
        }

        let firstPanelID = try #require(first.workspace.focusedPanelId)
        let firstCountBefore = first.workspace.panels.count
        let secondCountBefore = second.workspace.panels.count
        let secondWindow = try #require(mainWindow(second.windowID))
        secondWindow.makeKeyAndOrderFront(nil)

        let result = first.appDelegate.executeTerminalSplit(
            direction: .left,
            source: .explicitWorkspacePane(
                workspaceId: first.workspace.id,
                panelId: firstPanelID
            )
        )

        guard case .created(let createdPanelID) = result else {
            Issue.record("Expected the clicked workspace to receive the split")
            return
        }
        #expect(first.workspace.panels.count == firstCountBefore + 1)
        #expect(first.workspace.focusedPanelId == createdPanelID)
        #expect(second.workspace.panels.count == secondCountBefore)
    }

    @Test("Canvas splits place and focus one pane on the requested side", arguments: directions)
    private func canvasSplit(_ testCase: DirectionCase) throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        let sourcePanelID = try #require(fixture.workspace.focusedPanelId)
        fixture.workspace.setLayoutMode(.canvas)
        fixture.workspace.canvasModel.setFrame(
            CGRect(x: 100, y: 100, width: 600, height: 400),
            for: sourcePanelID
        )
        let sourceFrame = try #require(fixture.workspace.canvasModel.frame(of: sourcePanelID))
        let bonsplitPaneCount = fixture.workspace.bonsplitController.allPaneIds.count

        let result = fixture.appDelegate.executeTerminalSplit(
            direction: testCase.direction,
            source: .explicitWorkspacePane(
                workspaceId: fixture.workspace.id,
                panelId: sourcePanelID
            )
        )
        guard case .created(let createdPanelID) = result else {
            Issue.record("Expected a canvas pane for \(testCase.testDescription)")
            return
        }

        let createdFrame = try #require(fixture.workspace.canvasModel.frame(of: createdPanelID))
        #expect(fixture.workspace.focusedPanelId == createdPanelID)
        #expect(fixture.workspace.bonsplitController.allPaneIds.count == bonsplitPaneCount)
        switch testCase.direction {
        case .left:
            #expect(createdFrame.maxX <= sourceFrame.minX)
        case .right:
            #expect(createdFrame.minX >= sourceFrame.maxX)
        case .up:
            #expect(createdFrame.maxY <= sourceFrame.minY)
        case .down:
            #expect(createdFrame.minY >= sourceFrame.maxY)
        }
    }

    @Test("Remote tmux routes Right and Down exactly once", arguments: [
        DirectionCase(direction: .right, orientation: "horizontal", insertFirst: false, axis: .horizontal),
        DirectionCase(direction: .down, orientation: "vertical", insertFirst: false, axis: .vertical),
    ])
    private func remoteAppendSplit(_ testCase: DirectionCase) throws {
        let harness = try RemoteSplitFixture()
        defer { harness.tearDown() }
        let panelsBefore = harness.workspace.panels.count

        let result = harness.appDelegate.executeTerminalSplit(
            direction: testCase.direction,
            source: .explicitWorkspacePane(
                workspaceId: harness.workspace.id,
                panelId: harness.sourcePanelID
            )
        )
        #expect(result == .routedToRemote)
        #expect(harness.workspace.panels.count == panelsBefore)

        let output = try harness.finishAndReadCommands()
        let commands = output.split(separator: "\n").filter { $0.hasPrefix("split-window ") }
        #expect(commands.count == 1)
        #expect(commands.first?.contains(testCase.axis == .horizontal ? " -h " : " -v ") == true)
        #expect(commands.first?.contains(" -b ") == false)
    }

    @Test("Remote tmux rejects Left and Up without any mutation", arguments: [
        DirectionCase(direction: .left, orientation: "horizontal", insertFirst: true, axis: .horizontal),
        DirectionCase(direction: .up, orientation: "vertical", insertFirst: true, axis: .vertical),
    ])
    private func remoteInsertBeforeIsFailClosed(_ testCase: DirectionCase) throws {
        let harness = try RemoteSplitFixture()
        defer { harness.tearDown() }
        let panelsBefore = harness.workspace.panels.count

        let result = harness.appDelegate.executeTerminalSplit(
            direction: testCase.direction,
            source: .explicitWorkspacePane(
                workspaceId: harness.workspace.id,
                panelId: harness.sourcePanelID
            )
        )
        #expect(result == .unsupported(.remoteMirrorCannotInsertBefore))
        #expect(harness.workspace.panels.count == panelsBefore)
        var rejectionFeedbackCount = 0
        #expect(result.presentUserFeedback { rejectionFeedbackCount += 1 })
        #expect(rejectionFeedbackCount == 1)

        let output = try harness.finishAndReadCommands()
        #expect(!output.split(separator: "\n").contains { $0.hasPrefix("split-window ") })
    }

    @Test("The workspace split narrow waist rejects remote insert-before", arguments: [
        DirectionCase(direction: .left, orientation: "horizontal", insertFirst: true, axis: .horizontal),
        DirectionCase(direction: .up, orientation: "vertical", insertFirst: true, axis: .vertical),
    ])
    private func remoteWorkspaceNarrowWaistRejectsInsertBefore(_ testCase: DirectionCase) throws {
        let harness = try RemoteSplitFixture()
        defer { harness.tearDown() }

        let outcome = harness.workspace.newTerminalSplitOutcome(
            from: harness.sourcePanelID,
            orientation: testCase.direction.orientation,
            insertFirst: true
        )
        guard case .failed = outcome else {
            Issue.record("Expected low-level remote insert-before rejection")
            return
        }

        let output = try harness.finishAndReadCommands()
        #expect(!output.split(separator: "\n").contains { $0.hasPrefix("split-window ") })
    }

    @Test("Every terminal split action result is terminal, and only unsupported directions beep")
    func terminalResultFeedbackAndFallbackContract() {
        var feedbackCount = 0
        #expect(TerminalSplitActionResult.failed.isHandled)
        #expect(!TerminalSplitActionResult.failed.presentUserFeedback { feedbackCount += 1 })
        #expect(feedbackCount == 0)

        #expect(
            TerminalSplitActionResult
                .unsupported(.remoteMirrorCannotInsertBefore)
                .presentUserFeedback { feedbackCount += 1 }
        )
        #expect(feedbackCount == 1)
    }

    @MainActor
    private final class RemoteSplitFixture {
        let appDelegate: AppDelegate
        let windowID: UUID
        let workspace: Workspace
        let sourcePanelID: UUID
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let sessionMirror: RemoteTmuxSessionMirror
        private var didFinishReading = false

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowID = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            workspace = try #require(manager.selectedWorkspace)
            workspace.isRemoteTmuxMirror = true

            let host = RemoteTmuxHost(destination: "user@host")
            let sessionName = "cm2-\(UUID().uuidString)"
            connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
            pipe = Pipe()
            writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "directional-split-action-test",
                maxPendingBytes: 1 << 20,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )

            let layout = RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 40, height: 24, x: 0, y: 0, content: .pane(11)),
                    RemoteTmuxLayoutNode(width: 39, height: 24, x: 41, y: 0, content: .pane(22)),
                ])
            )
            connection.windowsByID[3] = RemoteTmuxWindow(
                id: 3,
                width: 80,
                height: 24,
                layout: layout
            )
            connection.windowOrder = [3]
            connection.recordPublishedPaneOwnership(windowId: 3, paneIds: [11, 22])
            sessionMirror = RemoteTmuxSessionMirror(
                host: host,
                sessionName: sessionName,
                connection: connection,
                tabManager: manager,
                workspace: workspace
            )
            appDelegate.remoteTmuxController.installSessionMirrorForTesting(sessionMirror)
            sourcePanelID = try #require(sessionMirror.panelIdByWindow[3])
        }

        func finishAndReadCommands() throws -> String {
            writer.close()
            didFinishReading = true
            return String(
                bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
                encoding: .utf8
            ) ?? ""
        }

        func tearDown() {
            appDelegate.remoteTmuxController.removeSessionMirrorForTesting(sessionMirror)
            sessionMirror.detachObserver()
            workspace.isRemoteTmuxMirror = false
            if !didFinishReading {
                writer.close()
            }
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private struct WorkspaceFixture {
        let appDelegate: AppDelegate
        let windowID: UUID
        let tabManager: TabManager
        let workspace: Workspace
    }

    private func makeWorkspaceFixture() throws -> WorkspaceFixture {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let workspace = try #require(manager.selectedWorkspace)
        return WorkspaceFixture(
            appDelegate: appDelegate,
            windowID: windowID,
            tabManager: manager,
            workspace: workspace
        )
    }

    private func mainWindow(_ windowID: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowID.uuidString)"
        return NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    private func closeWindow(_ windowID: UUID) {
        mainWindow(windowID)?.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func rootSplit(in workspace: Workspace) throws -> ExternalSplitNode {
        guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected workspace root to be a split")
            throw DirectionalSplitTestError.expectedSplit
        }
        return split
    }

    private func paneID(in node: ExternalTreeNode) throws -> String {
        guard case .pane(let pane) = node else {
            Issue.record("Expected split child to be a pane")
            throw DirectionalSplitTestError.expectedPane
        }
        return pane.id
    }

    private func perform(
        button: BonsplitConfiguration.SplitActionButton,
        in pane: PaneID,
        controller: BonsplitController
    ) {
        switch button.action {
        case .newTerminal:
            controller.requestNewTab(kind: "terminal", inPane: pane)
        case .newBrowser:
            controller.requestNewTab(kind: "browser", inPane: pane)
        case .splitRight:
            controller.splitPane(pane, orientation: .horizontal)
        case .splitDown:
            controller.splitPane(pane, orientation: .vertical)
        case .custom(let identifier):
            controller.requestCustomAction(identifier, inPane: pane)
        }
    }

    private enum DirectionalSplitTestError: Error {
        case expectedSplit
        case expectedPane
    }
}
