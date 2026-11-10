import Foundation

/// The one builder behind every agent mark's tooltip and accessibility label (cm-128.6): it turns a state's list of agents into
/// one line each, and both renderers set each mark from it. One display name for each agent, from one table; Q41's count when
/// several panes hold the agent in that state; the sidebar's pane order, which the lists keep; a loader's line last. An agent
/// with no display name (a registered Vault agent) reads the nameless lines and never its key.
enum SidebarAgentMarkTooltip {
    /// The marks that name agents.
    enum Mark {
        case waiting, error, running, monitoring, idle
    }

    /// Every mark's tooltip and accessibility label for one row, from the lists. The SwiftUI row reads this and nothing else for
    /// its marks' words, so a test can hold the row to the builder without reading the view tree (which carries no accessibility
    /// tree in the test host).
    struct Texts: Equatable {
        let waiting: String
        let error: String
        let running: String
        let monitoring: String
        /// The Idle word's tooltip and accessibility label (cm-128.9).
        let idle: String

        init(_ lists: SidebarAgentStateLists) {
            waiting = SidebarAgentMarkTooltip.text(.waiting, in: lists)
            error = SidebarAgentMarkTooltip.text(.error, in: lists)
            running = SidebarAgentMarkTooltip.text(.running, in: lists)
            monitoring = SidebarAgentMarkTooltip.text(.monitoring, in: lists)
            idle = SidebarAgentMarkTooltip.text(.idle, in: lists) // (cm-128.9)
        }
    }

    /// The lines for a mark, one for each agent in that state.
    static func lines(_ mark: Mark, in lists: SidebarAgentStateLists) -> [String] {
        switch mark {
        case .waiting:
            return lists.waiting.compactMap { entry in
                guard let name = entry.displayName else { return namelessWaiting(entry.paneCount) }
                return needsInput(name, entry.paneCount)
            }
        case .error:
            // The journal admits only the 19 named keys and the socket refuses `.error`, so no nameless agent holds one.
            return lists.error.compactMap { entry in
                guard let name = entry.displayName else { return nil }
                return entry.usageLimit ? usageLimit(name, entry.paneCount) : stopped(name, entry.paneCount)
            }
        case .running:
            var result = lists.running.compactMap { entry in
                entry.displayName.map { working($0, entry.paneCount) }
            }
            // Nameless running agents and `cmux workspace loading` loaders count together in one last line.
            var namelessCount = 0
            for entry in lists.running where entry.displayName == nil { namelessCount += entry.paneCount }
            if namelessCount + lists.loaderCount > 0 {
                result.append(SidebarWorkspaceLoadingTooltip.text(count: namelessCount + lists.loaderCount))
            }
            return result
        case .monitoring:
            // No nameless agent can monitor: the journal admits only the named keys, and the socket takes no `monitoring`.
            return lists.monitoring.compactMap { entry in
                entry.displayName.map { monitoring($0, entry.paneCount) }
            }
        case .idle:
            return lists.idle.compactMap { entry in
                guard let name = entry.displayName else { return namelessIdle(entry.paneCount) }
                return idle(name, entry.paneCount)
            }
        }
    }

    /// The tooltip and accessibility label: the lines, one per line.
    static func text(_ mark: Mark, in lists: SidebarAgentStateLists) -> String {
        lines(mark, in: lists).joined(separator: "\n")
    }

    /// The agent's name from the built-in definitions (one name table, shared with the task manager and the Feed's titles), or
    /// nil when none names it. A Feed attention slot's `cmux.feed.attention:` is taken off first.
    static func knownDisplayName(forStatusKey key: String) -> String? {
        let bare = key.hasPrefix(FeedCoordinator.attentionStatusKeyPrefix)
            ? String(key.dropFirst(FeedCoordinator.attentionStatusKeyPrefix.count)) : key
        let source = FeedCoordinator.source(forLifecycleStatusKey: bare)
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == source }?.displayName
    }

    // MARK: Lines. Each string key is a literal, so the catalog extraction sees it.

    private static func needsInput(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.needsInput", defaultValue: "%@ needs your answer"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.needsInput.count", defaultValue: "%1$@ needs your answer (%2$lld)"),
                name, Int64(count))
    }

    private static func working(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.working", defaultValue: "%@ is working"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.working.count", defaultValue: "%1$@ is working (%2$lld)"),
                name, Int64(count))
    }

    private static func monitoring(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.monitoring", defaultValue: "%@ is watching a background job"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.monitoring.count",
                       defaultValue: "%1$@ is watching a background job (%2$lld)"),
                name, Int64(count))
    }

    private static func idle(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.idle", defaultValue: "%@ is idle"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.idle.count", defaultValue: "%1$@ is idle (%2$lld)"),
                name, Int64(count))
    }

    private static func usageLimit(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentError.usageLimit.tooltip", defaultValue: "%@ hit its usage limit"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.usageLimit.count", defaultValue: "%1$@ hit its usage limit (%2$lld)"),
                name, Int64(count))
    }

    private static func stopped(_ name: String, _ count: Int) -> String {
        count == 1
            ? String.localizedStringWithFormat(
                String(localized: "sidebar.agentError.stopped.tooltip", defaultValue: "%@ stopped on an error"), name)
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.stopped.count", defaultValue: "%1$@ stopped on an error (%2$lld)"),
                name, Int64(count))
    }

    private static func namelessWaiting(_ count: Int) -> String {
        count == 1
            ? String(localized: "sidebar.agentWaiting.tooltip", defaultValue: "An agent is waiting for your answer")
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.waitingNameless.count",
                       defaultValue: "An agent is waiting for your answer (%lld)"),
                Int64(count))
    }

    private static func namelessIdle(_ count: Int) -> String {
        count == 1
            ? String(localized: "sidebar.agentMarks.idleNameless", defaultValue: "An agent is idle")
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentMarks.idleNameless.count", defaultValue: "An agent is idle (%lld)"),
                Int64(count))
    }
}
