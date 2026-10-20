import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAgentChat
import CmuxBrowser
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) @MainActor
struct FigmaBoardLayoutWorkspaceTests {
    private let file = URL(string: "https://www.figma.com/design/KEY/name")!

    private func request(_ url: URL?, omnibar: Bool = false, asker: DesignFocusRouting.Asker? = .user) -> BrowserSplitRequest {
        BrowserSplitRequest(url: url, focus: false, preferredProfileID: nil,
                            chromeVisibility: .init(omnibarVisible: omnibar),
                            transparentBackground: false, bypassRemoteProxy: true, designFocusAsker: asker)
    }

    @Test func onlyAgentOpenRecordsTheActualOpener() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        let source = try #require(w.focusedPanelId)
        let terminal = try #require(w.panels[source] as? TerminalPanel)
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: "opening-session", hookEventName: .sessionStart,
            source: "claude", surfaceId: source.uuidString))
        w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1272, height: 917))
        for asker: DesignFocusRouting.Asker? in [.user, nil, .agent] {
            if asker == nil {
                // The agent is working when it opens the blank file, before drawing.
                _ = registry.noteHookEvent(WorkstreamEvent(sessionId: "opening-session", hookEventName: .userPromptSubmit,
                    source: "claude", surfaceId: source.uuidString))
            }
            let result = try #require(BrowserSplitContainer.workspace(w).openBrowserToRight(
                of: source, request: request(file, asker: asker), registry: registry))
            if asker == .user {
                #expect(result.panel.figmaBoardLayoutBinding == nil)
                #expect(terminal.lastFigmaBoardOpen.isEmpty)
            } else {
                let binding = try #require(result.panel.figmaBoardLayoutBinding)
                #expect(binding.conversation == FigmaBoardLayoutBinding.Conversation(
                    panelID: source, kind: .claude, sessionID: "opening-session"))
                #expect(binding.fileKey == "KEY")
                #expect(binding.orientation == .vertical)
                #expect(terminal.lastFigmaBoardOpen[binding.conversation] == FigmaBoardLayoutBinding.LastOpen(
                    panelID: result.panel.id, fileKey: "KEY"))
            }
        }
    }

    @Test func sourceGeometryChoosesActualSplit() throws {
        for (width, height, direction): (CGFloat, CGFloat, SplitOrientation) in [
            (1272, 917, .horizontal), (917, 917, .horizontal),
            (636, 917, .vertical), (1518, 2822, .vertical)
        ] {
            let w = Workspace(); defer { w.teardownAllPanels() }
            w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: width, height: height))
            let source = try #require(w.focusedPanelId)
            let landed = try #require(BrowserSplitContainer.workspace(w).openBrowserToRight(of: source, request: request(file)))
            #expect(landed.createdSplit)
            #expect(landed.splitDirection == direction, "source \(width) x \(height)")
            #expect(w.bonsplitController.allPaneIds.count == 2)
            let frames = w.bonsplitController.layoutSnapshot().panes
            let sourcePane = try #require(w.paneId(forPanelId: source))
            let targetPane = try #require(w.paneId(forPanelId: landed.panel.id))
            let a = try #require(frames.first { $0.paneId == sourcePane.id.uuidString }?.frame)
            let b = try #require(frames.first { $0.paneId == targetPane.id.uuidString }?.frame)
            #expect(direction == .horizontal ? b.x > a.x : b.y > a.y)
        }
    }

    @Test func ordinaryPagesAndOmnibarKeepRightSplit() throws {
        for (url, omnibar) in [(URL(string: "https://example.com")!, false), (file, true)] {
            let w = Workspace(); defer { w.teardownAllPanels() }
            w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 636, height: 917))
            let source = try #require(w.focusedPanelId)
            let landed = try #require(BrowserSplitContainer.workspace(w).openBrowserToRight(of: source, request: request(url, omnibar: omnibar)))
            #expect(landed.splitDirection == .horizontal)
            #expect(landed.orientation == nil)
        }
    }

    @Test func rightSiblingWinsAndReportsItsOwnShape() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1272, height: 917))
        let source = try #require(w.focusedPanelId)
        let sibling = try #require(w.newTerminalSplit(from: source, orientation: .horizontal))
        let target = try #require(w.paneId(forPanelId: sibling.id))
        let landed = try #require(BrowserSplitContainer.workspace(w).openBrowserToRight(of: source, request: request(file)))
        #expect(!landed.createdSplit)
        #expect(landed.splitDirection == nil)
        #expect(w.paneId(forPanelId: landed.panel.id) == target)
        #expect(w.bonsplitController.allPaneIds.count == 2)
        #expect(landed.orientation == .vertical)
    }

    @Test func landedOrientationAndPairGeometry() throws {
        #expect(BoardLayoutOrientation(size: CGSize(width: 636, height: 917)) == .vertical)
        #expect(BoardLayoutOrientation(size: CGSize(width: 1272, height: 458)) == .horizontal)
        #expect(BoardLayoutOrientation(size: CGSize(width: 1000, height: 1000)) == .horizontal)
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.w.bonsplitController
        #expect(abs((c.pairSecondPaneSize?.width ?? 0) - 900) <= 1)
        #expect(c.pairSecondPaneSize?.height == 1000)
        let beside = try #require(BrowserSplitContainer.workspace(f.w).openBrowserToRight(of: f.terminal, request: request(file)))
        #expect(beside.orientation == .vertical)
        c.setPairZoomOrientation(.vertical)
        #expect(c.pairSecondPaneSize?.width == 1800)
        #expect(abs((c.pairSecondPaneSize?.height ?? 0) - 500) <= 1)
        let below = try #require(BrowserSplitContainer.workspace(f.w).openBrowserToRight(of: f.terminal, request: request(file)))
        #expect(below.orientation == .horizontal)
    }

    @MainActor private final class Fixture {
        let w = Workspace()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry: AgentChatSessionRegistry
        let terminal: UUID
        let browser: BrowserPanel
        let session = UUID().uuidString
        var sent: [(UUID, [TextBoxSubmit.DispatchEvent])] = []

        init(kind: String = "claude") throws {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
            registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
            terminal = try #require(w.focusedPanelId)
            w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1800, height: 1000))
            browser = try #require(w.newBrowserSplit(from: terminal, orientation: .horizontal,
                url: URL(string: "https://www.figma.com/design/KEY/name"), focus: false,
                allowsExternalBrowserFallback: false, chromeVisibility: .init(omnibarVisible: false)))
            fire(.sessionStart, source: kind)
            w.recordFigmaBoardOpen(panel: browser, sourcePanelID: terminal, url: browser.currentURL,
                                   orientation: .vertical, registry: registry)
            let a = try #require(w.paneId(forPanelId: terminal)), b = try #require(w.paneId(forPanelId: browser.id))
            try #require(w.bonsplitController.setPairZoom(firstPane: a, secondPane: b, orientation: .horizontal))
        }
        func fire(_ event: WorkstreamEvent.HookEventName, source: String = "claude", sessionID: String? = nil) {
            _ = registry.noteHookEvent(WorkstreamEvent(sessionId: sessionID ?? session, hookEventName: event,
                                                     source: source, surfaceId: terminal.uuidString))
        }
        func navigate(_ address: String) {
            browser.navigateWithoutInsecureHTTPPrompt(request: URLRequest(url: URL(string: address)!),
                recordTypedNavigation: false, trustedInternalNavigation: true)
        }
        @discardableResult func send(_ orientation: BoardLayoutOrientation, automatic: Bool = false) -> Bool {
            w.handOffBoardLayout(orientation, requireChange: automatic, registry: registry, home: home,
                                 deliver: { self.sent.append(($0, $1)) })
        }
        @discardableResult func flip() -> Bool {
            w.flipDesignFocusLayout(requestBoardLayout: { self.send($0, automatic: true) })
        }
        func cleanup() { w.teardownAllPanels(); try? FileManager.default.removeItem(at: home) }
    }

    @Test func flipDeliversOnceAndRemembersOnlySuccess() throws {
        for kind in ["claude", "codex"] {
            let f = try Fixture(kind: kind); defer { f.cleanup() }
            #expect(f.flip())
            #expect(f.sent.count == 1)
            #expect(f.sent.first?.0 == f.terminal)
            #expect(f.sent.first?.1 == FigmaDesignHandOff.dispatchEvents(for: .layoutHorizontal, kind: kind == "claude" ? .claude : .codex))
            #expect(f.browser.figmaBoardLayoutBinding?.orientation == .horizontal)
            #expect(f.flip())
            #expect(f.sent.count == 2)
            #expect(f.sent.last?.1 == FigmaDesignHandOff.dispatchEvents(for: .layoutVertical, kind: kind == "claude" ? .claude : .codex))
            #expect(!f.send(.vertical))
            #expect(f.sent.count == 2)
        }
    }

    @Test func busyAndPromptsRefuseWithoutClearingOrChangingMemory() throws {
        for event: WorkstreamEvent.HookEventName in [.userPromptSubmit, .permissionRequest, .askUserQuestion, .exitPlanMode] {
            let f = try Fixture(); defer { f.cleanup() }
            f.fire(event)
            let before = f.browser.figmaBoardLayoutBinding
            #expect(f.w.boardControlState(registry: f.registry)?.boardEnabled == false)
            #expect(f.w.boardControlState(registry: f.registry)?.pinEnabled == true)
            #expect(f.w.boardControlState(registry: f.registry)?.unavailableReason == .busyAgent)
            #expect(f.flip())
            #expect(!f.send(.horizontal))
            #expect(f.sent.isEmpty)
            #expect(f.browser.figmaBoardLayoutBinding == before)
            #expect(!f.browser.keepsBoardLayoutOnFlip)
        }
    }

    @Test func pinSuppressesFlipsButAllowsExplicitLayout() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(f.w.toggleBoardLayoutPin(registry: f.registry))
        #expect(f.flip()); #expect(f.flip())
        #expect(f.sent.isEmpty)
        #expect(f.browser.figmaBoardLayoutBinding?.orientation == .vertical)
        #expect(f.w.toggleBoardLayoutPin(registry: f.registry))
        #expect(f.flip()); #expect(f.sent.count == 1)
        #expect(f.w.toggleBoardLayoutPin(registry: f.registry))
        #expect(f.send(.vertical)); #expect(f.sent.count == 2)
        #expect(f.browser.keepsBoardLayoutOnFlip)
        #expect(!f.send(.vertical)); #expect(f.sent.count == 2)

        // After two pinned flips, unpinning must not resend an already remembered layout.
        let same = try Fixture(); defer { same.cleanup() }
        #expect(same.send(.horizontal))
        #expect(same.w.toggleBoardLayoutPin(registry: same.registry))
        #expect(same.flip()); #expect(same.flip())
        #expect(same.sent.count == 1)
        #expect(same.w.toggleBoardLayoutPin(registry: same.registry))
        #expect(same.flip())
        #expect(same.sent.count == 1)
        #expect(same.browser.figmaBoardLayoutBinding?.orientation == .horizontal)
    }

    @Test func singlePaneZoomRefusesFlip() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let pane = try #require(f.w.paneId(forPanelId: f.browser.id))
        f.w.bonsplitController.togglePaneZoom(inPane: pane)
        #expect(!f.flip())
        #expect(f.sent.isEmpty)
        #expect(f.browser.figmaBoardLayoutBinding?.orientation == .vertical)
    }

    @Test func changedURLRefusesAndExactFileRestores() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.w.recordFigmaFile(panelID: f.browser.id, address: file, title: "Original", showsAddressBar: false)
        #expect(f.w.figmaFileObservations[f.browser.id]?.key == "KEY")
        for address in ["https://www.figma.com/design/OTHER/name", "https://www.figma.com/design/KEY/branch/BRANCH/name", "https://www.figma.com/files", "https://example.com"] {
            f.w.recordFigmaFile(panelID: f.browser.id, address: file, title: "Original", showsAddressBar: false)
            f.navigate(address)
            if FigmaPaneURL.fileKey(fromPaneURL: URL(string: address)!) == nil {
                #expect(f.w.figmaFileObservations[f.browser.id]?.key == "KEY", "stale recent key must be present")
            }
            #expect(f.w.boardControlState(registry: f.registry) == PairBoardControlState(), "\(address)")
            #expect(!f.send(.horizontal), "\(address)")
            #expect(!f.w.toggleBoardLayoutPin(registry: f.registry))
            #expect(f.sent.isEmpty)
        }
        for address in ["https://www.figma.com/design/KEY/renamed?node-id=12-2", "https://www.figma.com/file/KEY/name", "https://www.figma.com/design/KEY/name"] {
            f.navigate(address)
            #expect(f.w.boardControlState(registry: f.registry)?.boardEnabled == true, "\(address)")
        }
        #expect(f.send(.horizontal)); #expect(f.sent.count == 1)
    }

    @Test func changedSessionAndLastOpenRefuseThenRestore() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try #require(f.browser.figmaBoardLayoutBinding)
        f.fire(.sessionStart, sessionID: "replacement")
        #expect(!f.send(.horizontal))
        #expect(f.w.boardControlState(registry: f.registry) == PairBoardControlState())
        f.fire(.sessionStart)
        #expect(f.w.boardControlState(registry: f.registry)?.boardEnabled == true)
        let terminal = try #require(f.w.panels[f.terminal] as? TerminalPanel)
        terminal.lastFigmaBoardOpen[original.conversation] = .init(panelID: UUID(), fileKey: "KEY")
        #expect(!f.send(.horizontal))
        terminal.lastFigmaBoardOpen[original.conversation] = .init(panelID: f.browser.id, fileKey: "KEY")
        #expect(f.w.boardControlState(registry: f.registry)?.boardEnabled == true)
        f.browser.figmaBoardLayoutBinding = nil
        #expect(!f.send(.horizontal))
        #expect(!f.w.toggleBoardLayoutPin(registry: f.registry))
        f.browser.figmaBoardLayoutBinding = original
        f.fire(.sessionEnd)
        #expect(!f.send(.horizontal))
        #expect(f.sent.isEmpty)
        #expect(f.browser.figmaBoardLayoutBinding == original)
    }

    @Test func anotherTerminalCannotClaimThePair() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let terminalPane = try #require(f.w.paneId(forPanelId: f.terminal))
        let figmaPane = try #require(f.w.paneId(forPanelId: f.browser.id))
        let other = try #require(f.w.newTerminalSplit(from: f.terminal, orientation: .horizontal, focus: false))
        _ = f.registry.noteHookEvent(WorkstreamEvent(sessionId: "other-conversation", hookEventName: .sessionStart,
            source: "claude", surfaceId: other.id.uuidString))
        try #require(f.w.bonsplitController.setPairZoom(firstPane: terminalPane, secondPane: figmaPane, orientation: .horizontal))
        f.w.bonsplitController.selectTab(try #require(f.w.surfaceIdFromPanelId(f.terminal)))
        f.w.recordFigmaBoardOpen(panel: f.browser, sourcePanelID: other.id, url: file, orientation: .vertical, registry: f.registry)
        #expect(f.w.boardControlState(registry: f.registry) == PairBoardControlState())
        #expect(!f.send(.horizontal))
        #expect(f.sent.isEmpty)
        f.w.recordFigmaBoardOpen(panel: f.browser, sourcePanelID: f.terminal, url: file, orientation: .vertical, registry: f.registry)
        #expect(f.w.boardControlState(registry: f.registry)?.boardEnabled == true)
        #expect(f.send(.horizontal))
        #expect(f.sent.count == 1)
        #expect(f.sent.first?.0 == f.terminal)
    }

    @Test func aLaterOpenSupersedesTheOriginalTab() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let pane = try #require(f.w.paneId(forPanelId: f.browser.id))
        let later = try #require(f.w.newBrowserSurface(inPane: pane, url: file, focus: false,
            selectWhenNotFocused: false, creationPolicy: .automationPreload, allowsExternalBrowserFallback: false,
            chromeVisibility: .init(omnibarVisible: false), designFocusAsker: .agent))
        f.w.recordFigmaBoardOpen(panel: later, sourcePanelID: f.terminal, url: file, orientation: .vertical, registry: f.registry)
        f.w.bonsplitController.selectTab(try #require(f.w.surfaceIdFromPanelId(f.browser.id)))
        #expect(f.w.boardControlState(registry: f.registry) == PairBoardControlState())
        #expect(!f.send(.horizontal))
        #expect(f.sent.isEmpty)
        f.w.recordFigmaBoardOpen(panel: f.browser, sourcePanelID: f.terminal, url: file, orientation: .vertical, registry: f.registry)
        #expect(f.send(.horizontal))
        #expect(f.sent.count == 1)
    }

    @Test func readWrapperPreservesExactFileIdentity() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let binding = try #require(f.browser.figmaBoardLayoutBinding)
        let terminal = try #require(f.w.panels[f.terminal] as? TerminalPanel)
        // URL resolution and identity matching need no read of the wrapper file or the real home.
        let readURL = try FigmaPaneURL.destination(for: file, node: "12-2").url
        #expect(binding.matches(conversation: binding.conversation, panelID: f.browser.id,
            currentFileKey: FigmaPaneURL.fileKey(fromPaneURL: readURL),
            lastOpen: terminal.lastFigmaBoardOpen[binding.conversation]))
    }

    @Test func staleHoverDoesNotAuthorizeDelivery() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let hover = try #require(f.w.boardControlState(registry: f.registry))
        #expect(hover.boardEnabled)
        f.fire(.userPromptSubmit)
        #expect(hover.boardEnabled)
        #expect(!f.send(.horizontal))
        #expect(f.sent.isEmpty)
        #expect(f.w.boardControlState(registry: f.registry)?.litOrientation == .vertical)
    }

    @Test func commandSetIsExactlyEight() {
        let commands = Set([ChatAgentKind.claude, .codex].flatMap { kind in
            FigmaDesignHandOff.Job.allCases.flatMap { job in
                FigmaDesignHandOff.dispatchEvents(for: job, kind: kind).compactMap { event -> String? in
                    if case .pasteText(let text) = event { return text }; return nil
                }
            }
        })
        #expect(commands == Set(["/", "$"].flatMap { prefix in
            ["put", "new", "layout vertical", "layout horizontal"].map { prefix + "design-in-figma-pane " + $0 }
        }))
    }
}

/// Where the one-shot "fit once the editor has loaded" mark is set (`cm-73.22`). The clicked-link
/// entrance is in `FigmaClickWorkspaceTests`.
@Suite(.serialized) @MainActor
struct FigmaFitEntranceWorkspaceTests {
    private let design = URL(string: "https://www.figma.com/design/KEY/name")!

    private func request(_ url: URL?, omnibar: Bool = false) -> BrowserSplitRequest {
        BrowserSplitRequest(url: url, focus: false, preferredProfileID: nil,
                            chromeVisibility: .init(omnibarVisible: omnibar),
                            transparentBackground: false, bypassRemoteProxy: true, designFocusAsker: .agent)
    }

    @Test func openPlacementSetsTheMarkForADesignFileWithNoAddressBar() throws {
        let wrapperEmbed = FigmaPaneURL.wrapperURL(
            FigmaPaneURL.wrapperFileURL(),
            embedding: URL(string: "https://embed.figma.com/design/KEY/name?node-id=1-2")!
        )
        let cases: [(url: URL, omnibar: Bool, fits: Bool)] = [
            (design, false, true),
            (design, true, false),
            (URL(string: "https://www.figma.com/board/KEY/name")!, false, false),
            (URL(string: "https://www.figma.com/slides/KEY/name")!, false, false),
            (wrapperEmbed, false, false),
            (URL(string: "https://example.com")!, false, false)
        ]
        for testCase in cases {
            for existingRightPane in [false, true] {
                let w = Workspace(); defer { w.teardownAllPanels() }
                w.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1272, height: 917))
                let source = try #require(w.focusedPanelId)
                if existingRightPane { _ = try #require(w.newTerminalSplit(from: source, orientation: .horizontal)) }
                let landed = try #require(BrowserSplitContainer.workspace(w).openBrowserToRight(
                    of: source, request: request(testCase.url, omnibar: testCase.omnibar)))
                #expect(landed.panel.figmaFitMark.isPending == testCase.fits,
                        "\(testCase.url) omnibar \(testCase.omnibar) reuse \(existingRightPane)")
            }
        }
    }

    @Test func menuAndNewFileEntriesSetTheMarkAndRecentFilesDoNot() throws {
        let suite = "figma-fit-entrance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set("www.figma.com", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let file = try #require(w.newFigmaSurface(inPane: pane, address: design, focus: false,
                                                   defaults: defaults, openExternally: { _ in }))
        #expect(file.figmaFitMark.isPending)
        let newFile = try #require(w.newFigmaSurface(
            inPane: pane, address: URL(string: "https://www.figma.com/design/new?folder_id=1&team_id=2")!,
            focus: false, defaults: defaults, openExternally: { _ in }))
        #expect(newFile.figmaFitMark.isPending)
        let board = try #require(w.newFigmaSurface(
            inPane: pane, address: URL(string: "https://www.figma.com/board/new?folder_id=1&team_id=2")!,
            focus: false, defaults: defaults, openExternally: { _ in }))
        #expect(!board.figmaFitMark.isPending)
        let recent = try #require(w.newFigmaSurface(inPane: pane, focus: false, defaults: defaults, openExternally: { _ in }))
        #expect(!recent.figmaFitMark.isPending)
    }
}
