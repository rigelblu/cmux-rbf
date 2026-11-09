import AppKit
import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxSidebar
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.5 (Scenarios 23 and 72): a pane at `.error` is its own per-pane value. The hand reads needs-input only; every
/// other needs-you reader still counts the error, which is an `==` comparison the compiler would not flag.
@MainActor
@Suite(.serialized)
struct SidebarWorkspaceStateMarksTests {
    private func rowSnapshot(
        _ workspace: Workspace,
        list: WorkspaceStatusList = WorkspaceStatusEntrancesTests.hisList,
        agentActivityOn: Bool = true
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suite = "SidebarWorkspaceStateMarksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if !agentActivityOn { defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentActivityKey) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: true,
            todoControlsEnabled: true, statusList: list, statusColorHexes: [:]
        ).makeSnapshot()
    }

    // MARK: Projection

    @Test func aClaudeErrorFromTheJournalIsItsOwnPerPaneValue() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.errorReported)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .error, "marks \(harness.marks)")
        }
    }

    @Test func aCodexErrorFromTheJournalIsItsOwnPerPaneValueToo() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.errorReported, source: "codex")
            await harness.settle()
            #expect(harness.marks["codex"] == .error, "marks \(harness.marks)")
        }
    }

    // MARK: Scenario 72, each reader

    @Test func anyAgentNeedsInputStillCountsAnError() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["claude_code": .error]
            #expect(harness.workspace.taskStatusSignals().anyAgentNeedsInput, "Auto, the strip, the number, Cycle Status and the socket read this")
        }
    }

    @Test func anErrorIsClearableAndAClearLeavesItUnknown() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["claude_code": .error]
            #expect(harness.workspace.hasClearableAgentState, "a row whose only mark is the triangle must be clearable")
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown, "marks \(harness.marks)")
        }
    }

    // MARK: Scenario 23, the hand

    @Test func anErrorShowsNoHandAndAWaitStillDoes() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["claude_code": .error]
            #expect(!rowSnapshot(harness.workspace).showsRaisedHand, "an error is the triangle's, not the hand's")
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["claude_code": .needsInput]
            #expect(rowSnapshot(harness.workspace).showsRaisedHand, "control: a wait shows the hand")
        }
    }
    // MARK: Scenario 75, the triangle's data, its tooltip and its AppKit mark

    private func observeError(_ harness: ClearAgentStateHarness, source: String, native: String?, detail: String?, session: String = "session", panel: UUID? = nil) {
        harness.center.observe(AgentJournalEventDraft(kind: .errorReported, occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000) + 5,
            source: source, agentKey: source == "claude" ? "claude_code" : source, sessionId: session,
            workspaceId: harness.workspace.id.uuidString, surfaceId: (panel ?? harness.panel).uuidString, nativeEvent: native, detail: detail))
    }

    @Test func anErroredClaudePaneShowsTheTriangleWithoutTheHandAndSaysStopped() async throws {
        try await ClearAgentStateHarness.run { harness in
            observeError(harness, source: "claude", native: "StopFailure", detail: "server_error")
            await harness.settle()
            let snapshot = rowSnapshot(harness.workspace)
            #expect(snapshot.erroredAgents.map(\.displayName) == ["Claude Code"], "\(snapshot.erroredAgents)")
            #expect(!snapshot.showsRaisedHand)
            #expect(SidebarAgentErrorSummary.tooltip(for: snapshot.erroredAgents) == "Claude Code stopped on an error")
            let signals = harness.workspace.taskStatusSignals()
            #expect(signals.anyAgentNeedsInput && signals.anyAgentError && !signals.anyAgentWaiting)
        }
    }

    @Test func aTypedUsageLimitSaysSoAndNothingElseDoes() async throws {
        try await ClearAgentStateHarness.run { harness in
            observeError(harness, source: "claude", native: "StopFailure", detail: "rate_limit")
            observeError(harness, source: "codex", native: "Stop", detail: "usage_limit_exceeded")
            observeError(harness, source: "pi", native: "Stop", detail: "usage_limit_exceeded")
            await harness.settle()
            let lines = SidebarAgentErrorSummary.tooltipLines(for: rowSnapshot(harness.workspace).erroredAgents)
            #expect(lines.contains("Claude Code hit its usage limit"), "\(lines)")
            #expect(lines.contains("Codex hit its usage limit"), "\(lines)")
            #expect(lines.contains("Pi stopped on an error"), "the same detail from another source is free text: \(lines)")
            #expect(lines.count == 3, "one line per errored agent: \(lines)")
        }
    }

    @Test func theUsageLimitLeavesWithTheError() async throws {
        try await ClearAgentStateHarness.run { harness in
            observeError(harness, source: "claude", native: "StopFailure", detail: "rate_limit")
            await harness.settle()
            #expect(harness.workspace.agentUsageLimitKeysByPanelId[harness.panel]?.contains("claude_code") == true)
            harness.observe(.turnStarted)
            await harness.settle()
            #expect(harness.workspace.agentUsageLimitKeysByPanelId[harness.panel] == nil)
            #expect(rowSnapshot(harness.workspace).erroredAgents.isEmpty)
        }
    }

    @Test func aWaitAndAnErrorOnTwoAgentsShowTheHandAndTheTriangleTogether() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["claude_code": .needsInput, "codex": .error]
            let snapshot = rowSnapshot(harness.workspace)
            #expect(snapshot.showsRaisedHand)
            #expect(snapshot.erroredAgents.map(\.statusKey) == ["codex"])
        }
    }

    @Test(arguments: [false, true])
    func theAppKitTriangleIsTheHandsTwinOutsideTheDoneDim(isDark: Bool) throws {
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(customColorHex: "#777777", showsRaisedHand: true, taskStatus: .done)
        snapshot.erroredAgents = [SidebarErroredAgent(statusKey: "claude_code", displayName: "Claude Code", usageLimit: false)]
        let model = SidebarAppKitRowCellTests.makeModel(isActive: false, colorSchemeIsDark: isDark, snapshot: snapshot)
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        _ = cell.layoutContent(model: model, width: 420, apply: true)
        let triangle = try #require(cell.errorTriangleForTesting)
        #expect(!triangle.isHidden)
        #expect(triangle.toolTip == "Claude Code stopped on an error")
        #expect(triangle.accessibilityLabel() == "Claude Code stopped on an error")
        let expectedYellow = waitingHandYellow(for: isDark ? .dark : .light)
        #expect(triangle.contentTintColor?.usingColorSpace(.sRGB) == expectedYellow.usingColorSpace(.sRGB))
        func effectiveAlpha(_ view: NSView) -> CGFloat {
            var alpha: CGFloat = 1
            var current: NSView? = view
            while let node = current { alpha *= node.alphaValue; current = node.superview }
            return alpha
        }
        #expect(effectiveAlpha(triangle) == 1, "no agent mark dims on a Done row")
        #expect(effectiveAlpha(try #require(cell.handForTesting)) == 1)
        let hand = try #require(cell.handForTesting)
        #expect(triangle.frame.minX >= hand.frame.maxX, "beside the hand, after it: hand \(hand.frame), triangle \(triangle.frame)")
    }
}

// MARK: cm-128.5 step-2 fix round (F1, F3, F4, F5, F6, F7)

extension SidebarWorkspaceStateMarksTests {
    private func secondPane(_ harness: ClearAgentStateHarness) throws -> UUID {
        let pane = try #require(harness.workspace.paneId(forPanelId: harness.panel))
        return try #require(harness.workspace.newTerminalSurface(inPane: pane, focus: false)).id
    }

    // MARK: F3 and F4, the lines and their order

    @Test func twoErroredClaudePanesSayEachTheirOwnLineInPaneOrder() async throws {
        try await ClearAgentStateHarness.run { harness in
            let second = try secondPane(harness)
            #expect(harness.workspace.sidebarOrderedPanelIds() == [harness.panel, second], "pane order")
            observeError(harness, source: "claude", native: "StopFailure", detail: "rate_limit", session: "a")
            observeError(harness, source: "claude", native: "StopFailure", detail: "server_error", session: "b", panel: second)
            await harness.settle()
            let lines = SidebarAgentErrorSummary.tooltipLines(for: rowSnapshot(harness.workspace).erroredAgents)
            #expect(lines == ["Claude Code hit its usage limit", "Claude Code stopped on an error"], "\(lines)")
        }
    }

    @Test func theLinesFollowThePaneOrderNotTheKeyOrderNorThePaneIdOrder() {
        let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let agents = SidebarAgentErrorSummary.erroredAgents(
            showsAgentActivity: true, orderedPanelIds: [high, low],
            statesByPanelId: [high: ["pi": .error, "claude_code": .error], low: ["codex": .error]],
            usageLimitKeysByPanelId: [:])
        #expect(agents.map(\.statusKey) == ["claude_code", "pi", "codex"], "the first pane's keys by name, then the next pane: \(agents.map(\.statusKey))")
        let reversed = SidebarAgentErrorSummary.erroredAgents(
            showsAgentActivity: true, orderedPanelIds: [low, high],
            statesByPanelId: [high: ["pi": .error], low: ["codex": .error]], usageLimitKeysByPanelId: [:])
        #expect(reversed.map(\.statusKey) == ["codex", "pi"], "\(reversed.map(\.statusKey))")
    }

    @Test func theSameLineIsSaidOnce() {
        let a = UUID(), b = UUID()
        let agents = SidebarAgentErrorSummary.erroredAgents(
            showsAgentActivity: true, orderedPanelIds: [a, b],
            statesByPanelId: [a: ["claude_code": .error], b: ["claude_code": .error]],
            usageLimitKeysByPanelId: [a: ["claude_code"], b: ["claude_code"]])
        #expect(SidebarAgentErrorSummary.tooltipLines(for: agents) == ["Claude Code hit its usage limit"], "\(agents)")
    }

    // MARK: F6, one name table

    @Test func everyBuiltInAgentIsNamedByItsOwnDefinition() {
        for definition in CmuxTaskManagerCodingAgentDefinition.builtIns {
            let key = FeedCoordinator.lifecycleStatusKey(forSource: definition.id)
            #expect(SidebarAgentErrorSummary.displayName(forStatusKey: key) == definition.displayName, "\(key)")
        }
        let kimi = CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == "kimi" }
        #expect(SidebarAgentErrorSummary.displayName(forStatusKey: "kimi") == kimi?.displayName)
        #expect(SidebarAgentErrorSummary.displayName(forStatusKey: "unheard-of") == "unheard-of", "the bare key is the fallback")
    }

    // MARK: F7, the pane order is read only when a pane holds an error

    @Test func thePaneOrderIsNotReadWhenNoPaneHoldsAnError() {
        var reads = 0
        let panel = UUID()
        let none = SidebarAgentErrorSummary.erroredAgents(
            showsAgentActivity: true, orderedPanelIds: { reads += 1; return [panel] }(),
            statesByPanelId: [panel: ["claude_code": .needsInput]], usageLimitKeysByPanelId: [:])
        #expect(none.isEmpty)
        #expect(reads == 0, "the order was read \(reads) time(s) for a row with no error")
        let some = SidebarAgentErrorSummary.erroredAgents(
            showsAgentActivity: true, orderedPanelIds: { reads += 1; return [panel] }(),
            statesByPanelId: [panel: ["claude_code": .error]], usageLimitKeysByPanelId: [:])
        #expect(some.count == 1 && reads == 1, "control: an error reads the order once")
    }

    // MARK: F5, the usage-limit set follows the states

    @Test func anErrorToAnErrorWithoutTheLimitDropsTheUsageLimit() async throws {
        try await ClearAgentStateHarness.run { harness in
            observeError(harness, source: "claude", native: "StopFailure", detail: "rate_limit")
            await harness.settle()
            #expect(harness.workspace.agentUsageLimitKeysByPanelId[harness.panel]?.contains("claude_code") == true, "control: the limit is flagged")
            observeError(harness, source: "claude", native: "StopFailure", detail: "server_error")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .error, "marks \(harness.marks)")
            #expect(harness.workspace.agentUsageLimitKeysByPanelId[harness.panel]?.contains("claude_code") != true,
                    "the second error is not a usage limit: \(harness.workspace.agentUsageLimitKeysByPanelId)")
            let lines = SidebarAgentErrorSummary.tooltipLines(for: rowSnapshot(harness.workspace).erroredAgents)
            #expect(lines == ["Claude Code stopped on an error"], "\(lines)")
        }
    }

    @Test func clearingAPanesStatesDropsItsUsageLimit() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .error)
            harness.workspace.setAgentUsageLimit(key: "claude_code", panelId: harness.panel)
            harness.workspace.clearAgentLifecycleStates(panelId: harness.panel)
            #expect(harness.workspace.agentUsageLimitKeysByPanelId[harness.panel] == nil, "\(harness.workspace.agentUsageLimitKeysByPanelId)")
        }
    }

    @Test func clearingEveryPanesStatesDropsEveryUsageLimit() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .error)
            harness.workspace.setAgentUsageLimit(key: "claude_code", panelId: harness.panel)
            harness.workspace.clearAllAgentLifecycleStates()
            #expect(harness.workspace.agentUsageLimitKeysByPanelId.isEmpty, "\(harness.workspace.agentUsageLimitKeysByPanelId)")
        }
    }

    @Test func aMovedRateLimitedPaneKeepsItsUsageLimit() async throws {
        try await ClearAgentStateHarness.run { harness in
            let moved = try secondPane(harness)
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: moved, lifecycle: .error)
            harness.workspace.setAgentUsageLimit(key: "claude_code", panelId: moved)
            let destination = harness.tabManager.addWorkspace(select: false)
            defer { harness.tabManager.closeWorkspace(destination) }
            let detached = try #require(harness.workspace.detachSurface(panelId: moved))
            let pane = try #require(destination.bonsplitController.focusedPaneId)
            #expect(destination.attachDetachedSurface(detached, inPane: pane, focus: false) == moved)
            #expect(destination.agentLifecycleStatesByPanelId[moved]?["claude_code"] == .error, "control: the state moved")
            #expect(destination.agentUsageLimitKeysByPanelId[moved]?.contains("claude_code") == true,
                    "the limit stayed behind: \(destination.agentUsageLimitKeysByPanelId)")
            let lines = SidebarAgentErrorSummary.tooltipLines(for: rowSnapshot(destination).erroredAgents)
            #expect(lines == ["Claude Code hit its usage limit"], "\(lines)")
        }
    }

    // MARK: F1, each reader and wiring

    @Test func anErrorKeepsItsStatusEntryWithItsPaneWhenItMoves() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Stopped")
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .idle)
            #expect(harness.workspace.agentRuntimeState(forPanelId: harness.panel)?.statusEntries["claude_code"] == nil, "control: an idle pane takes no entry")
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .error)
            #expect(harness.workspace.agentRuntimeState(forPanelId: harness.panel)?.statusEntries["claude_code"] != nil,
                    "an errored pane's entry stayed behind")
        }
    }

    @Test func anErrorOnAnotherPaneKeepsTheSharedStatusEntryWhenOnePaneIsCleared() async throws {
        try await ClearAgentStateHarness.run { harness in
            let other = try secondPane(harness)
            harness.workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Stopped")
            _ = harness.workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: harness.panel, refreshPorts: false)
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: other, lifecycle: .idle)
            #expect(harness.workspace.clearAgentPID(key: "claude_code.first", panelId: harness.panel, clearStatus: true, refreshPorts: false))
            #expect(harness.workspace.statusEntries["claude_code"] == nil, "control: nothing live is left, the entry goes")
            harness.workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Stopped")
            _ = harness.workspace.recordAgentPID(key: "claude_code.first", pid: 111, panelId: harness.panel, refreshPorts: false)
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: other, lifecycle: .error)
            #expect(harness.workspace.clearAgentPID(key: "claude_code.first", panelId: harness.panel, clearStatus: true, refreshPorts: false))
            #expect(harness.workspace.statusEntries["claude_code"] != nil, "an errored pane is a live runtime: its entry stays")
        }
    }

    @Test func anErroredPaneKeepsItsKeyFilterOffNeedsInput() async throws {
        try await ClearAgentStateHarness.run { harness in
            let surface = try #require((harness.workspace.panels[harness.panel] as? TerminalPanel)?.surface)
            surface.updateAgentInputPhase(["claude_code": .needsInput])
            #expect(surface.agentInputState.needsInput, "control: a wait is needs-input")
            surface.updateAgentInputPhase(["claude_code": .error])
            #expect(!surface.agentInputState.needsInput, "an error is not needs-input: the key filter must stay off")
        }
    }

    @Test func aStartupReplayRepaintsTheUsageLimitLine() async throws {
        try await ClearAgentStateHarness.run { harness in
            observeError(harness, source: "claude", native: "StopFailure", detail: "rate_limit")
            await harness.settle()
            harness.workspace.clearAllAgentLifecycleStates()
            #expect(harness.workspace.agentLifecycleStatesByPanelId.isEmpty && harness.workspace.agentUsageLimitKeysByPanelId.isEmpty, "control: wiped")
            harness.center.noteStartupReplayReady()
            await harness.settle()
            #expect(harness.marks["claude_code"] == .error, "the replay painted \(harness.marks)")
            let lines = SidebarAgentErrorSummary.tooltipLines(for: rowSnapshot(harness.workspace).erroredAgents)
            #expect(lines == ["Claude Code hit its usage limit"], "\(lines)")
        }
    }

    @Test func theTriangleHidesWithTheHandWhenThereIsNoStatusListOrAgentActivityIsOff() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .error)
            #expect(rowSnapshot(harness.workspace).erroredAgents.count == 1, "control: his list, activity on")
            let noList = WorkspaceStatusList(entries: WorkspaceStatusEntrancesTests.hisEntries, source: .cmux)
            #expect(rowSnapshot(harness.workspace, list: noList).erroredAgents.isEmpty, "no status list hides the triangle")
            #expect(rowSnapshot(harness.workspace, agentActivityOn: false).erroredAgents.isEmpty, "agent activity off hides the triangle")
        }
    }

    // MARK: Scenario 75, the SwiftUI row's triangle

    /// The yellowest pixel (0 to 255, `(red + green) / 2 - blue`) of a rendered SwiftUI row. A triangle drawn at full strength
    /// is far yellower than the row's own colors; one dimmed toward the row's background loses it.
    private func peakYellowness(done: Bool) throws -> Int {
        let suite = "SidebarWorkspaceStateMarksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(taskStatus: done ? .done : .todo)
        snapshot.erroredAgents = [SidebarErroredAgent(statusKey: "claude_code", displayName: "Claude Code", usageLimit: false)]
        let entrances = WorkspaceStatusEntrancesTests()
        let input = entrances.rowInput(snapshot, settings: SidebarTabItemSettingsSnapshot(defaults: defaults))
        let row = TabItemView(
            snapshot: entrances.rowSnapshot(input),
            actions: SidebarWorkspaceContextMenuWindowTargetsTests.actions(currentWindowMoveTargets: { [] }))
        let host = NSHostingView(rootView: row.environment(\.colorScheme, .light).frame(width: 320, height: 80))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        // Option A (conductor, 2026-11-09): render the host's layer tree into an opaque white bitmap. `cacheDisplay` drops the
        // opacity SwiftUI puts on the layers, and reads a clear background, so a dimmed triangle looked undimmed.
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let hostLayer = try #require(host.layer, "the hosting view has no layer")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        graphics.cgContext.scaleBy(x: 2, y: 2)
        hostLayer.render(in: graphics.cgContext)
        var best = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                best = max(best, (r + g) / 2 - b)
            }
        }
        return best
    }

    @Test func theSwiftUITriangleSitsOutsideTheDoneDim() throws {
        let todo = try peakYellowness(done: false)
        let done = try peakYellowness(done: true)
        #expect(todo >= 120, "control: a To do row draws the triangle in yellow; its yellowest pixel scores \(todo)")
        // Done dims content to 0.6; a dimmed triangle scores 0.6 of the To do row's (137 of 229 measured), so 80% sits between.
        #expect(done * 10 >= todo * 8, "a Done row dimmed the triangle: its yellowest pixel scores \(done), the To do row's \(todo)")
    }
}
