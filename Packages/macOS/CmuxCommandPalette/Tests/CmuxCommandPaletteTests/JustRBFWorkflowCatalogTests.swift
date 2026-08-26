import CmuxFoundation
import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("JustRBFWorkflowCatalog")
@MainActor
struct JustRBFWorkflowCatalogTests {
    @Test func publishesCompleteExitZeroStdoutAndIgnoresStderr() async {
        let runner = ScriptedWorkflowCommandRunner(results: [
            commandResult(
                stdout: "claude-ssu\tSession usage\ncodex-vcs-change-describe\n",
                stderr: "warning: claude-ssu is not reachable\n"
            ),
        ])
        let catalog = JustRBFWorkflowCatalog(commandRunner: runner)

        await catalog.refresh(shellPath: "/bin/fish", homeDirectory: "/Users/tester")

        #expect(catalog.workflows.map(\.name) == ["claude-ssu", "codex-vcs-change-describe"])
        #expect(catalog.revision == 1)
        let invocations = await runner.recordedInvocations()
        #expect(invocations == [
            WorkflowCommandInvocation(
                directory: "/Users/tester",
                executable: "/bin/fish",
                arguments: ["-lc", "just-rbf --list"],
                timeout: 2.0
            ),
        ])
    }

    @Test func successfulEmptySnapshotClearsTheCache() async {
        let runner = ScriptedWorkflowCommandRunner(results: [
            commandResult(stdout: "claude-ssu\n"),
            commandResult(stdout: ""),
        ])
        let catalog = JustRBFWorkflowCatalog(commandRunner: runner)

        await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")
        await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")

        #expect(catalog.workflows.isEmpty)
        #expect(catalog.revision == 2)
    }

    @Test func derivesStablePaletteIdentityFromCanonicalNamesAcrossRefresh() async {
        let runner = ScriptedWorkflowCommandRunner(results: [
            commandResult(stdout: "claude-ssu\tOld description\ncodex-vcs-change-describe\n"),
            commandResult(stdout: "claude-ssu\tNew description\ngcr-migrate-to-blue\n"),
        ])
        let catalog = JustRBFWorkflowCatalog(commandRunner: runner)

        await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")
        let originalIdentity = catalog.workflows[0].commandPaletteID
        await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")

        #expect(catalog.workflows[0].name == "claude-ssu")
        #expect(catalog.workflows[0].commandPaletteID == originalIdentity)
        #expect(catalog.workflows[0].escapedDescription == "New description")
        #expect(catalog.workflows[1].commandPaletteID != originalIdentity)
    }

    @Test func everyFailureRetainsTheLastCompleteSnapshot() async {
        let runner = ScriptedWorkflowCommandRunner(results: [
            commandResult(stdout: "claude-ssu\n"),
            commandResult(stdout: nil),
            commandResult(stdout: "partial\n", exitStatus: 7),
            commandResult(stdout: "partial\n", timedOut: true),
            commandResult(stdout: nil, exitStatus: nil, executionError: "launch failed"),
            commandResult(stdout: "malformed-without-newline"),
        ])
        let catalog = JustRBFWorkflowCatalog(commandRunner: runner)

        for _ in 0..<6 {
            await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")
        }

        #expect(catalog.workflows.map(\.name) == ["claude-ssu"])
        #expect(catalog.revision == 1)
    }

    @Test func concurrentRefreshesShareOneFlight() async {
        let runner = SuspendedWorkflowCommandRunner()
        let catalog = JustRBFWorkflowCatalog(commandRunner: runner)

        let first = Task { @MainActor in
            await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")
        }
        await runner.waitUntilCalled()
        let second = Task { @MainActor in
            await catalog.refresh(shellPath: "/bin/zsh", homeDirectory: "/Users/tester")
        }
        await Task.yield()

        #expect(await runner.callCount() == 1)
        await runner.finish(with: commandResult(stdout: "claude-ssu\n"))
        await first.value
        await second.value

        #expect(await runner.callCount() == 1)
        #expect(catalog.workflows.map(\.name) == ["claude-ssu"])
        #expect(catalog.revision == 1)
    }
}

private struct WorkflowCommandInvocation: Sendable, Equatable {
    let directory: String
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval?
}

private actor ScriptedWorkflowCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var invocations: [WorkflowCommandInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(
            WorkflowCommandInvocation(
                directory: directory,
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        )
        return results.removeFirst()
    }

    func recordedInvocations() -> [WorkflowCommandInvocation] {
        invocations
    }
}

private actor SuspendedWorkflowCommandRunner: CommandRunning {
    private var invocationCount = 0
    private var continuation: CheckedContinuation<CommandResult, Never>?

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCalled() async {
        while invocationCount == 0 {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        invocationCount
    }

    func finish(with result: CommandResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private func commandResult(
    stdout: String?,
    stderr: String? = nil,
    exitStatus: Int32? = 0,
    timedOut: Bool = false,
    executionError: String? = nil
) -> CommandResult {
    CommandResult(
        stdout: stdout,
        stderr: stderr,
        exitStatus: exitStatus,
        timedOut: timedOut,
        executionError: executionError
    )
}
