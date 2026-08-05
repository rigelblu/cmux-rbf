import CMUXAgentLaunch
import Testing

@Suite("AgentForkArgv")
struct AgentForkArgvTests {
    @Test("Built-in forkable kinds")
    func builtInForkableKinds() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: "/opt/bin/claude",
                arguments: ["/opt/bin/claude", "--model", "sonnet"]
            ) == ["claude", "--resume", "SID", "--fork-session"]
        )
        // Claude drops `--model` (it restores its own, #cm-30); every other kind below
        // keeps theirs, which is what makes the drop provably claude-only.
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "--model", "gpt-5"]
            ) == ["/opt/bin/codex", "fork", "SID", "--model", "gpt-5"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "opencode",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["opencode", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["opencode", "--session", "SID", "--fork", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "pi",
                sessionId: "SID",
                executablePath: "/opt/bin/pi",
                arguments: ["/opt/bin/pi", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["/opt/bin/pi", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "omp",
                sessionId: "SID",
                executablePath: "/opt/bin/omp",
                arguments: ["/opt/bin/omp", "--model", "anthropic/claude-sonnet-4-6"]
            ) == ["/opt/bin/omp", "--fork", "SID", "--model", "anthropic/claude-sonnet-4-6"]
        )
    }

    @Test("Codex one-shot commands are not forkable")
    func codexOneShotCommandsAreNotForkable() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "exec", "make", "test"]
            ) == nil
        )
    }

    @Test("Codex fork captures preserve prompt tags")
    func codexForkCapturesPreservePromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "tag-one",
                    "tag two",
                    "--model",
                    "gpt-5"
                ]
            ) == ["/opt/bin/codex", "fork", "CHILD", "tag-one", "tag two", "--model", "gpt-5"]
        )
    }

    @Test("Codex fork captures preserve command-shaped prompt tags")
    func codexForkCapturesPreserveCommandShapedPromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "exec",
                    "review",
                    "help",
                    "fork",
                    "resume",
                    "--model",
                    "gpt-5"
                ]
            ) == ["/opt/bin/codex", "fork", "CHILD", "exec", "review", "help", "fork", "resume", "--model", "gpt-5"]
        )
    }

    @Test("Codex normal prompt captures do not replay prompts when forked")
    func codexNormalPromptCapturesDoNotReplayPrompts() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "--model",
                    "gpt-5",
                    "initial prompt should not replay",
                ]
            ) == ["/opt/bin/codex", "fork", "CHILD", "--model", "gpt-5"]
        )
    }

    @Test("Codex fork captures preserve options after prompt tags")
    func codexForkCapturesPreserveOptionsAfterPromptTags() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "codex",
                sessionId: "CHILD",
                executablePath: "/opt/bin/codex",
                arguments: [
                    "/opt/bin/codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "tag-one",
                    "--sandbox",
                    "danger-full-access",
                ]
            ) == ["/opt/bin/codex", "fork", "CHILD", "tag-one", "--sandbox", "danger-full-access"]
        )
    }

    @Test("cmux wrapper launchers use fork verbs")
    func launcherWrappersUseForkVerbs() {
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "claudeTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "claude-teams", "--worktree", "/tmp/team repo"]
            ) == .resolved(["cmux", "claude-teams", "--resume", "SID", "--fork-session", "--worktree", "/tmp/team repo"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "codexTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "codex-teams", "--model", "gpt-5"]
            ) == .resolved(["cmux", "codex-teams", "fork", "SID", "--model", "gpt-5"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "omo",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "omo", "--model", "anthropic/claude-sonnet-4-6"]
            ) == .resolved(["cmux", "omo", "--session", "SID", "--fork", "--model", "anthropic/claude-sonnet-4-6"])
        )
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "omx",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "omx"]
            ) == .resolved(nil)
        )
    }

    @Test("Unsupported agents stay unsupported")
    func unsupportedAgentsStayUnsupported() {
        #expect(
            AgentForkArgv().builtInKind(kind: "grok", sessionId: "SID", executablePath: nil, arguments: ["grok"]) == nil
        )
        #expect(
            AgentForkArgv().builtInKind(kind: "amp", sessionId: "SID", executablePath: nil, arguments: ["amp"]) == nil
        )
    }

    /// A fork is a resume (`--resume <id> --fork-session`) through the same sanitizer, so it carries
    /// the identical defect: replaying the launch-time `--model`/`--effort` overrides the state
    /// Claude Code restores for itself. Splitting resume from fork would ship half a fix for one
    /// user need (#cm-30).
    @Test("Claude fork omits model and effort so Claude restores its own")
    func claudeForkOmitsModelAndEffort() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: "/opt/bin/claude",
                arguments: [
                    "/opt/bin/claude",
                    "--model", "sonnet",
                    "--effort", "high",
                    "--dangerously-skip-permissions",
                ]
            ) == ["claude", "--resume", "SID", "--fork-session", "--dangerously-skip-permissions"]
        )
    }

    /// The `claudeTeams` launcher resolves before `builtInKind` on the fork path too — the fourth
    /// and last site where cmux authors a claude resume command (#cm-30).
    @Test("Claude teams fork omits model and effort")
    func claudeTeamsForkOmitsModelAndEffort() {
        #expect(
            AgentForkArgv().launcherResolution(
                launcher: "claudeTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "claude-teams", "--model", "sonnet", "--effort", "high", "--verbose"]
            ) == .resolved(["cmux", "claude-teams", "--resume", "SID", "--fork-session", "--verbose"])
        )
    }
}
