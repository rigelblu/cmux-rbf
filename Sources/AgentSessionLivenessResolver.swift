import CmuxAgentJournal
import Foundation

/// A PID that fits `pid_t` and can name a process.
private func isValidPID(_ pid: Int) -> Bool { pid > 0 && pid <= Int(Int32.max) }

/// Decides from process evidence whether an agent session is gone.
///
/// `.dead` needs proof: the recorded PID is absent, or the process now holding
/// it is a different generation. Anything else that is not a live match is
/// `.unknown`, and an `.unknown` session keeps its wait or error. The pane the
/// session was recorded on is never part of the answer: an agent running in a
/// herdr terminal is alive from here too.
struct AgentSessionLivenessResolver: Sendable {
    enum Liveness: Sendable { case alive, dead, unknown }
    let homeDirectory: URL
    let processIdentity: @Sendable (Int) -> AgentPIDProcessIdentity?
    let processPresence: @Sendable (Int) -> PIDPresence

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         processIdentity: @escaping @Sendable (Int) -> AgentPIDProcessIdentity? = {
             guard isValidPID($0) else { return nil }
             return AgentPIDProcessIdentity(pid: pid_t($0))
         }, processPresence: @escaping @Sendable (Int) -> PIDPresence = {
             guard isValidPID($0) else { return .unknown }
             return PIDPresence.current(pid: pid_t($0))
         }) {
        self.homeDirectory = homeDirectory
        self.processIdentity = processIdentity
        self.processPresence = processPresence
    }

    /// Liveness of the session's hook record: the PID and generation it recorded.
    /// A missing, corrupt, unreadable or PID-less record is `.unknown`.
    func liveness(source: String, sessionId: String) -> Liveness {
        guard let entry = AgentChatHookSessionStore(homeDirectory: homeDirectory)
            .entry(agentSource: source, sessionID: sessionId), let pid = entry.pid else { return .unknown }
        return processLiveness(pid: pid, recorded: recordedIdentity(of: entry, pid: pid))
    }

    /// Liveness of one recorded process generation. Without a recorded
    /// identity only a missing PID proves anything, because a present PID may
    /// belong to a later process.
    func processLiveness(pid: Int, recorded: AgentPIDProcessIdentity?) -> Liveness {
        guard isValidPID(pid) else { return .unknown }
        let absentOrUnknown: Liveness = processPresence(pid) == .absent ? .dead : .unknown
        guard let recorded, Int(recorded.pid) == pid else { return absentOrUnknown }
        guard let current = processIdentity(pid), Int(current.pid) == pid else { return absentOrUnknown }
        return current == recorded ? .alive : .dead
    }

    /// The session id a swept PID key stands for, never guessed.
    ///
    /// Claude's `claude_code` key names a pane, not a session, so it takes the
    /// one record on exactly that workspace and pane that recorded this PID.
    /// Every other agent's key ends in `.<sessionId>`.
    func sessionId(forPIDKey key: String, source: String, workspaceId: UUID, surfaceId: UUID, pid: Int) -> String? {
        if source == "claude" {
            let matches = AgentChatHookSessionStore(homeDirectory: homeDirectory).entries(agentSource: source).filter {
                $0.pid == pid && $0.workspaceID == workspaceId.uuidString && $0.surfaceID == surfaceId.uuidString
            }
            return matches.count == 1 ? matches[0].sessionID : nil
        }
        guard let dot = key.firstIndex(of: ".") else { return nil }
        let suffix = String(key[key.index(after: dot)...])
        return suffix.isEmpty ? nil : suffix
    }

    private func recordedIdentity(of entry: AgentChatHookSessionStore.Entry, pid: Int) -> AgentPIDProcessIdentity? {
        guard isValidPID(pid), let seconds = entry.pidStartSeconds,
              let microseconds = entry.pidStartMicroseconds else { return nil }
        return AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: seconds, startMicroseconds: microseconds)
    }
}
