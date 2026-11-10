import Foundation

/// One agent in one state on a workspace row: its name and how many panes it is in that state on. (cm-128.6)
struct SidebarAgentStateEntry: Equatable, Sendable {
    /// The agent's key, a Feed slot's `cmux.feed.attention:` taken off; empty on the merged nameless entry.
    let statusKey: String
    /// The agent's display name, or nil when no built-in definition names it (a registered Vault agent). Every nameless
    /// agent in a state is one entry, and its line reads without a name.
    let displayName: String?
    /// How many (pane, agent) pairs are in this state.
    let paneCount: Int
    /// Error entries only: whether the error was a typed usage limit (Claude's `rate_limit`, Codex's `usage_limit_exceeded`),
    /// so "hit its usage limit" and "stopped on an error" stay separate entries.
    let usageLimit: Bool
}

/// For each state a mark draws, the agents in it, and how many `cmux workspace loading` loaders run. A mark shows when its
/// list is not empty. The idle list draws nothing of `.6`'s: it gives the tooltip lines of `.9`'s quiet "Idle" word. (cm-128.6)
struct SidebarAgentStateLists: Equatable, Sendable {
    var waiting: [SidebarAgentStateEntry] = []
    var error: [SidebarAgentStateEntry] = []
    var running: [SidebarAgentStateEntry] = []
    var monitoring: [SidebarAgentStateEntry] = []
    var idle: [SidebarAgentStateEntry] = []
    /// Running `cmux workspace loading` loaders, which add to the spinner and decide nothing about agents.
    var loaderCount = 0

    /// The hand shows while any agent is waiting.
    var showsRaisedHand: Bool { !waiting.isEmpty }
    /// The spinner's count: running agent panes plus the running loaders.
    var activeCodingAgentCount: Int { running.reduce(loaderCount) { $0 + $1.paneCount } }
    /// The waveform's count.
    var monitoringAgentCount: Int { monitoring.reduce(0) { $0 + $1.paneCount } }
}

enum SidebarAgentActivitySummary {
    /// The row's lists, each behind its mark's gate (cm-128.6). Waiting and error sit behind the setting
    /// (`settings.details.showAgentActivity`, the hand's gate, which the triangle shares); running, monitoring, idle and
    /// the loaders sit behind the factory's `showsAgentActivity` (the setting and the spinner flag). No status list gates any.
    /// - Parameters:
    ///   - showsNeedsYouMarks: The setting.
    ///   - showsAgentActivity: The setting and the spinner flag.
    ///   - paneStates: The workspace's per-agent states, read only when a list can show.
    static func lists(
        showsNeedsYouMarks: Bool,
        showsAgentActivity: Bool,
        paneStates: @autoclosure () -> WorkspaceAgentPaneStates
    ) -> SidebarAgentStateLists {
        guard showsNeedsYouMarks || showsAgentActivity else { return SidebarAgentStateLists() }
        let states = paneStates()
        var lists = SidebarAgentStateLists()
        for pane in states.entries {
            switch pane.state {
            case .needsInput where showsNeedsYouMarks: add(pane, to: &lists.waiting)
            case .error where showsNeedsYouMarks: add(pane, to: &lists.error, needsName: true)
            case .running where showsAgentActivity: add(pane, to: &lists.running)
            case .monitoring where showsAgentActivity: add(pane, to: &lists.monitoring, needsName: true)
            case .idle where showsAgentActivity: add(pane, to: &lists.idle)
            default: break
            }
        }
        if showsAgentActivity { lists.loaderCount = states.loaderCount }
        return lists
    }

    /// Adds one pane's agent: an entry for each agent (and usage-limit flag), at its first pane in the given order; every
    /// nameless agent shares one entry. With `needsName`, a nameless agent is left out: the error and monitoring marks have no
    /// nameless line, so an entry for one would draw the mark with an empty tooltip and VoiceOver label (cm-128.6).
    private static func add(
        _ pane: WorkspaceAgentPaneState,
        to list: inout [SidebarAgentStateEntry],
        needsName: Bool = false
    ) {
        let name = SidebarAgentMarkTooltip.knownDisplayName(forStatusKey: pane.agentKey)
        if needsName && name == nil { return }
        let key = name == nil ? "" : pane.agentKey
        if let index = list.firstIndex(where: { $0.statusKey == key && $0.usageLimit == pane.usageLimit }) {
            let existing = list[index]
            list[index] = SidebarAgentStateEntry(
                statusKey: existing.statusKey, displayName: existing.displayName,
                paneCount: existing.paneCount + 1, usageLimit: existing.usageLimit)
        } else {
            list.append(SidebarAgentStateEntry(
                statusKey: key, displayName: name, paneCount: 1, usageLimit: pane.usageLimit))
        }
    }
}
