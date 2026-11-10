import AppKit
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.6 (Scenarios 91 and 42, the agent half): the one builder behind every agent mark's tooltip. One line for each agent in
/// a state, by its one display name, with a count when several panes hold it, in the sidebar's pane order, a loader's line last.
/// A registered Vault agent has no display name and reads the nameless lines, never its key.
@MainActor
@Suite("Agent mark tooltips")
struct SidebarAgentMarkTooltipTests {
    private let one = UUID(), two = UUID(), three = UUID()

    private func pane(_ panel: UUID, _ key: String, _ state: AgentHibernationLifecycleState,
                      limit: Bool = false) -> WorkspaceAgentPaneState {
        WorkspaceAgentPaneState(panelId: panel, agentKey: key, state: state, usageLimit: limit)
    }

    private func lists(_ panes: [WorkspaceAgentPaneState], loaders: Int = 0) -> SidebarAgentStateLists {
        SidebarAgentActivitySummary.lists(showsNeedsYouMarks: true, showsAgentActivity: true,
            paneStates: WorkspaceAgentPaneStates(entries: panes, loaderCount: loaders))
    }

    private func lines(_ mark: SidebarAgentMarkTooltip.Mark, _ panes: [WorkspaceAgentPaneState], loaders: Int = 0) -> [String] {
        SidebarAgentMarkTooltip.lines(mark, in: lists(panes, loaders: loaders))
    }

    // MARK: Working

    @Test func panesOfOneAgentAreOneLineWithTheirCountInPaneOrder() {
        #expect(lines(.running, [pane(one, "claude_code", .running), pane(two, "claude_code", .running), pane(three, "pi", .running)])
                == ["Claude Code is working (2)", "Pi is working"])
    }

    @Test func aLoaderBesideARunningAgentIsTheLastLine() {
        #expect(lines(.running, [pane(one, "claude_code", .running)], loaders: 1)
                == ["Claude Code is working", "Loading (1 active task)"])
    }

    @Test func namelessRunningAgentsAndLoadersCountTogetherInOneLastLine() {
        #expect(lines(.running, [pane(one, "my-vault-agent", .running)]) == ["Loading (1 active task)"])
        #expect(lines(.running, [pane(one, "my-vault-agent", .running)], loaders: 1) == ["Loading (2 active tasks)"])
        #expect(lines(.running, [], loaders: 3) == ["Loading (3 active tasks)"])
    }

    // MARK: Waiting

    @Test func aFeedSlotIsNamedForItsAgentAndTheLinesFollowPaneOrder() throws {
        // Two panes (Scenario 91): codex on the first, the Feed slot on the second. Alphabetical order would put Claude Code first.
        let workspace = Workspace()
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false)).id
        let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")
        workspace.agentLifecycleStatesByPanelId[first] = ["codex": .needsInput]
        workspace.agentLifecycleStatesByPanelId[second] = [slot: .needsInput]
        let all = SidebarAgentActivitySummary.lists(showsNeedsYouMarks: true, showsAgentActivity: true,
            paneStates: workspace.agentPaneStates(panelIds: [first, second]))
        #expect(SidebarAgentMarkTooltip.lines(.waiting, in: all) == ["Codex needs your answer", "Claude Code needs your answer"])
    }

    @Test func severalPanesWaitingOnOneAgentCount() {
        #expect(lines(.waiting, [pane(one, "codex", .needsInput), pane(two, "codex", .needsInput)])
                == ["Codex needs your answer (2)"])
    }

    @Test func aNamelessWaitingAgentReadsToday() {
        #expect(lines(.waiting, [pane(one, "my-vault-agent", .needsInput)]) == ["An agent is waiting for your answer"])
        #expect(lines(.waiting, [pane(one, "my-vault-agent", .needsInput), pane(two, "other-vault", .needsInput)])
                == ["An agent is waiting for your answer (2)"], "several nameless agents are one line with the count")
        #expect(lines(.waiting, [pane(one, "my-vault-agent", .needsInput)]).joined().contains("my-vault-agent") == false,
                "never the key")
    }

    // MARK: Monitoring, idle, error

    @Test func aMonitoringAgentIsWatchingABackgroundJob() {
        #expect(lines(.monitoring, [pane(one, "claude_code", .monitoring)]) == ["Claude Code is watching a background job"])
        #expect(lines(.monitoring, [pane(one, "claude_code", .monitoring), pane(two, "claude_code", .monitoring)])
                == ["Claude Code is watching a background job (2)"])
    }

    @Test func idleAgentsAreOneLineEachWithTheirCount() {
        #expect(lines(.idle, [pane(one, "claude_code", .idle), pane(two, "claude_code", .idle), pane(three, "codex", .idle)])
                == ["Claude Code is idle (2)", "Codex is idle"])
    }

    @Test func namelessIdleAgents() {
        #expect(lines(.idle, [pane(one, "my-vault-agent", .idle)]) == ["An agent is idle"])
        #expect(lines(.idle, [pane(one, "my-vault-agent", .idle), pane(two, "other-vault", .idle)]) == ["An agent is idle (2)"])
    }

    @Test func errorsSayStoppedOrHitItsUsageLimitWithCounts() {
        #expect(lines(.error, [pane(one, "pi", .error), pane(two, "pi", .error)]) == ["Pi stopped on an error (2)"])
        #expect(lines(.error, [pane(one, "claude_code", .error, limit: true)]) == ["Claude Code hit its usage limit"])
        #expect(lines(.error, [pane(one, "claude_code", .error)]) == ["Claude Code stopped on an error"])
        #expect(lines(.error, [pane(one, "claude_code", .error, limit: true), pane(two, "claude_code", .error, limit: true)])
                == ["Claude Code hit its usage limit (2)"])
        #expect(lines(.error, [pane(one, "claude_code", .error, limit: true), pane(two, "claude_code", .error)])
                == ["Claude Code hit its usage limit", "Claude Code stopped on an error"], "kept apart by the flag, in pane order")
    }

    @Test func linesFollowThePaneOrderGiven() {
        #expect(lines(.running, [pane(one, "pi", .running), pane(two, "codex", .running), pane(three, "claude_code", .running)])
                == ["Pi is working", "Codex is working", "Claude Code is working"])
    }

    /// cm-128.6 (whole-diff review, finding 5): the journal admits only named keys for an error or a monitor, so a nameless one is
    /// unreachable today. The list is what a mark shows on, so a nameless entry must never reach it: it would draw a triangle or
    /// a waveform with an empty tooltip and an empty VoiceOver label.
    @Test func aNamelessErrorOrMonitoringAgentIsKeptOutOfItsList() {
        let all = lists([pane(one, "my-vault-agent", .error), pane(two, "my-vault-agent", .monitoring),
                         pane(three, "claude_code", .error), pane(three, "codex", .monitoring)])
        #expect(all.error.map(\.displayName) == ["Claude Code"], Comment(rawValue: "\(all.error)"))
        #expect(all.monitoring.map(\.displayName) == ["Codex"], Comment(rawValue: "\(all.monitoring)"))
        let onlyNameless = lists([pane(one, "my-vault-agent", .error), pane(two, "my-vault-agent", .monitoring)])
        #expect(onlyNameless.error.isEmpty && onlyNameless.monitoring.isEmpty, Comment(rawValue: "\(onlyNameless)"))
        #expect(onlyNameless.monitoringAgentCount == 0)
    }

    @Test func aMarkWithNoAgentsHasNoLines() {
        for mark in [SidebarAgentMarkTooltip.Mark.waiting, .error, .running, .monitoring, .idle] {
            #expect(SidebarAgentMarkTooltip.lines(mark, in: SidebarAgentStateLists()).isEmpty)
            #expect(SidebarAgentMarkTooltip.text(mark, in: SidebarAgentStateLists()).isEmpty)
        }
    }

    @Test func textJoinsTheLinesOnePerLine() {
        let all = lists([pane(one, "claude_code", .running), pane(two, "pi", .running)])
        #expect(SidebarAgentMarkTooltip.text(.running, in: all) == "Claude Code is working\nPi is working")
    }

    // MARK: Both renderers read the builder

    private func allMarksLists() -> SidebarAgentStateLists {
        lists([pane(one, "claude_code", .needsInput), pane(one, "codex", .error, limit: true), pane(two, "codex", .error, limit: true),
               pane(two, "pi", .running), pane(two, "claude_code", .monitoring), pane(three, "gemini", .idle)], loaders: 1)
    }

    @Test func theAppKitMarksSayTheBuildersLinesInTheTooltipAndTheAccessibilityLabel() throws {
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        snapshot.agentLists = allMarksLists()
        let model = SidebarAppKitRowCellTests.makeModel(snapshot: snapshot)
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        _ = cell.layoutContent(model: model, width: 420, apply: true)
        let all = snapshot.agentLists
        let hand = try #require(cell.handForTesting)
        let triangle = try #require(cell.errorTriangleForTesting)
        let waveform = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? NSImageView }
            .first { !$0.isHidden && $0 !== hand && $0 !== triangle && $0.toolTip == SidebarAgentMarkTooltip.text(.monitoring, in: all) })
        let spinner = try #require([cell.markSpinnerForTesting, cell.trailingSpinnerForTesting].compactMap { $0 }.first { !$0.isHidden })
        #expect(hand.toolTip == "Claude Code needs your answer" && hand.accessibilityLabel() == hand.toolTip)
        #expect(triangle.toolTip == "Codex hit its usage limit (2)" && triangle.accessibilityLabel() == triangle.toolTip)
        #expect(waveform.toolTip == "Claude Code is watching a background job" && waveform.accessibilityLabel() == waveform.toolTip)
        #expect(spinner.toolTip == "Pi is working\nLoading (1 active task)", "\(String(describing: spinner.toolTip))")
        #expect(spinner.accessibilityLabel() == spinner.toolTip)
        #expect(spinner.isAccessibilityElement(), "a plain NSView is none by default, so VoiceOver would skip the label")
        #expect(spinner.accessibilityRole() == .image)
        for (view, mark) in [(hand as NSView, SidebarAgentMarkTooltip.Mark.waiting), (triangle, .error), (waveform, .monitoring)] {
            #expect(view.toolTip == SidebarAgentMarkTooltip.text(mark, in: all), "\(mark)")
        }
        #expect(spinner.toolTip == SidebarAgentMarkTooltip.text(.running, in: all))
    }

    /// SwiftUI's `.help` has no pixels, and the hosted row exposes no accessibility tree in the test host (a control showed
    /// `found = []`). So the SwiftUI row has one computed property for every mark's words, which its body is the only reader of
    /// (cm-128.6). This holds that property to the builder. KNOWN LIMIT: no test turns red if `TabItemView.body` stops reading
    /// it, because a test can't read the body's `.help` or accessibility label here; that the body reads only this property
    /// for each mark is checked by reading `TabItemView.body`, not by a test.
    @Test func theSwiftUIRowsMarkWordsAreTheBuildersLines() throws {
        let suite = "SidebarAgentMarkTooltipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        snapshot.agentLists = allMarksLists()
        let entrances = WorkspaceStatusEntrancesTests()
        let input = entrances.rowInput(snapshot, settings: SidebarTabItemSettingsSnapshot(defaults: defaults))
        let row = TabItemView(
            snapshot: entrances.rowSnapshot(input),
            actions: SidebarWorkspaceContextMenuWindowTargetsTests.actions(currentWindowMoveTargets: { [] }))
        let all = snapshot.agentLists
        let words = row.agentMarkTooltips
        #expect(words.waiting == "Claude Code needs your answer", Comment(rawValue: words.waiting))
        #expect(words.error == "Codex hit its usage limit (2)", Comment(rawValue: words.error))
        #expect(words.running == "Pi is working\nLoading (1 active task)", Comment(rawValue: words.running))
        #expect(words.monitoring == "Claude Code is watching a background job", Comment(rawValue: words.monitoring))
        #expect(words == SidebarAgentMarkTooltip.Texts(all))
        for (text, mark) in [(words.waiting, SidebarAgentMarkTooltip.Mark.waiting), (words.error, .error),
                             (words.running, .running), (words.monitoring, .monitoring)] {
            #expect(text == SidebarAgentMarkTooltip.text(mark, in: all), "\(mark)")
        }
    }

    /// Scenario 140 (cm-128.9): the SwiftUI row's Idle word reads `agentMarkTooltips.idle`, the builder's idle lines. That its
    /// `.help` and `.accessibilityLabel` read this value is a code read (`Sources/ContentView.swift`, the line's row).
    @Test func theSwiftUIRowsIdleWordIsTheBuildersIdleLines() throws {
        let suite = "SidebarAgentMarkTooltipTests.idle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        snapshot.agentLists = SidebarAgentStateLists()
        // Panes 1 and 2 hold `claude_code` idle.
        snapshot.agentLists.idle = [SidebarAgentStateEntry(statusKey: "claude_code", displayName: "Claude Code", paneCount: 2, usageLimit: false)]
        let entrances = WorkspaceStatusEntrancesTests()
        let input = entrances.rowInput(snapshot, settings: SidebarTabItemSettingsSnapshot(defaults: defaults))
        let row = TabItemView(
            snapshot: entrances.rowSnapshot(input),
            actions: SidebarWorkspaceContextMenuWindowTargetsTests.actions(currentWindowMoveTargets: { [] }))
        let words = row.agentMarkTooltips
        #expect(words.idle == "Claude Code is idle (2)", Comment(rawValue: words.idle))
        #expect(words.idle == SidebarAgentMarkTooltip.text(.idle, in: snapshot.agentLists))
    }
}
