import Foundation

extension ClaudeHookSessionStore {
    /// The newest pending permissions kept per session. A tool that never completes would otherwise leave its pairing behind. (cm-128.1)
    static let maxPendingClaudePermissions = 32

    func rememberClaudePermission(sessionId: String, workspaceId: String, surfaceId: String,
                                  permission: ClaudePendingPermission) throws {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(state: state, sessionId: sessionId,
                workspaceId: workspaceId, surfaceId: surfaceId, now: now)
            record.workspaceId = workspaceId
            record.surfaceId = surfaceId
            record.pendingClaudePermissions = Array(
                ((record.pendingClaudePermissions ?? []) + [permission]).suffix(Self.maxPendingClaudePermissions))
            record.updatedAt = now
            state.sessions[sessionId] = record
        }
    }

    func consumeClaudePermission(sessionId: String, toolName: String, inputFingerprint: String,
                                 agentId: String?) throws -> ClaudePendingPermission? {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        // cm-128.1: this runs for every tool completion and most have nothing to pair. Look first without writing, so a
        // completion with no pending permission does not rewrite the whole store under the exclusive lock.
        let hasPending = try withLockedState(persist: false) { state in
            !(state.sessions[sessionId]?.pendingClaudePermissions?.isEmpty ?? true)
        }
        guard hasPending else { return nil }
        return try withLockedState { state in
            guard var record = state.sessions[sessionId],
                  var pending = record.pendingClaudePermissions,
                  let index = pending.firstIndex(where: {
                      $0.toolName == toolName && $0.inputFingerprint == inputFingerprint && $0.agentId == agentId
                  }) else { return nil }
            let matched = pending.remove(at: index)
            record.pendingClaudePermissions = pending.isEmpty ? nil : pending
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[sessionId] = record
            return matched
        }
    }

    func updateClaudeEditorMode(sessionId: String, editorMode: String) throws {
        try withLockedState { state in
            guard var record = state.sessions[sessionId] else { return }
            record.editorMode = editorMode
            state.sessions[sessionId] = record
        }
    }

    /// Drops a session's pending permissions. Prompt and Stop clear them in the record update they already do; this is for a
    /// session's end, and it writes only when there is something to clear. (cm-128.1)
    func clearClaudePermissions(sessionId: String) throws {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPending = try withLockedState(persist: false) { state in
            !(state.sessions[sessionId]?.pendingClaudePermissions?.isEmpty ?? true)
        }
        guard hasPending else { return }
        try withLockedState { state in
            guard var record = state.sessions[sessionId] else { return }
            record.pendingClaudePermissions = nil
            state.sessions[sessionId] = record
        }
    }
}
