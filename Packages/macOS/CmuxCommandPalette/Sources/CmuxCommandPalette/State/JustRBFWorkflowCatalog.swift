public import CmuxFoundation
public import Observation

/// App-scoped, last-success cache of workflows from `just-rbf --list`.
@MainActor
@Observable
public final class JustRBFWorkflowCatalog {
    /// The most recent complete successful workflow snapshot.
    public private(set) var workflows: [JustRBFWorkflow] = []
    /// Monotonic publication revision used to invalidate palette search corpora.
    public private(set) var revision: UInt64 = 0

    private let commandRunner: any CommandRunning
    private let parser = JustRBFWorkflowListParser()
    @ObservationIgnored private var refreshTask: Task<[JustRBFWorkflow]?, Never>?

    /// Creates an empty catalog backed by an injected command runner.
    public init(commandRunner: any CommandRunning) {
        self.commandRunner = commandRunner
    }

    /// Refreshes through the user's login shell, coalescing concurrent calls.
    ///
    /// Only a complete, UTF-8, exit-zero snapshot replaces the cache. Launch
    /// failures, timeouts, nonzero exits, unavailable stdout, and parse failures
    /// leave both the workflows and revision untouched. Standard error is ignored.
    public func refresh(shellPath: String, homeDirectory: String) async {
        if let refreshTask {
            _ = await refreshTask.value
            return
        }

        let commandRunner = commandRunner
        let parser = parser
        let task = Task<[JustRBFWorkflow]?, Never> {
            let result = await commandRunner.run(
                directory: homeDirectory,
                executable: shellPath,
                arguments: ["-lc", "just-rbf --list"],
                timeout: 2.0
            )
            guard result.executionError == nil,
                  !result.timedOut,
                  result.exitStatus == 0,
                  let stdout = result.stdout else {
                return nil
            }
            return try? parser.parse(stdout)
        }
        refreshTask = task

        let refreshedWorkflows = await task.value
        refreshTask = nil
        guard let refreshedWorkflows else { return }
        workflows = refreshedWorkflows
        revision += 1
    }
}
