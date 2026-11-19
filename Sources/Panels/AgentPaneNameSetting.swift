import CmuxSettings
import Foundation

/// The name each agent's Agent Pane shows: the setting `agentPane.names`, held where the one caption writer
/// (`Workspace.agentPaneCaption`) can read it without reading a file.
///
/// cmux-rbf #cm-126.15. One app-wide holder, ``current``, shaped like `FigmaTabTitleSetting`: it reads the
/// global `cmux.json`'s snapshot, watches the key, and on a change re-titles every Agent Pane in every window
/// (`AppDelegate.refreshAgentPaneCaptions()`). The default is no names, so every pane reads "Agent Pane".
@MainActor
final class AgentPaneNameSetting {
    /// The holder the app reads. Under the unit-test host (`XCTestConfigurationFilePath`) it gets no store and
    /// holds no names, so no test reads Tom's `cmux.json`. A test that needs names installs its own holder for
    /// its run and puts this one back (`defer`).
    static var current: AgentPaneNameSetting = makeAppSetting()

    /// The usable names by lowercased slug (`*` for every agent): skipped entries are already left out.
    private(set) var names: [String: String]

    nonisolated(unsafe) private var watchTask: Task<Void, Never>?

    init(names: [String: String] = [:]) {
        self.names = names
    }

    init(
        store: JSONConfigStore?,
        onChange: (@MainActor () -> Void)? = nil
    ) {
        let key = SettingCatalog().agentPane.names
        self.names = store?.snapshotValue(for: key).usableNames ?? [:]
        guard let store else { return }
        watchTask = Task { @MainActor [weak self] in
            for await value in store.values(for: key) {
                guard let self, !Task.isCancelled else { break }
                let next = value.usableNames
                if self.names != next {
                    self.names = next
                    onChange?()
                }
            }
        }
    }

    deinit {
        watchTask?.cancel()
    }

    /// Builds the holder the app reads: over `cmux.json`, re-titling every Agent Pane on a change. The three
    /// parameters are the test seam (a test builds this holder with no test-host variable, a scratch file and its
    /// own re-title closure, so the app's own store runs); the app passes none.
    static func makeAppSetting(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configFile: @autoclosure () -> URL = CmuxConfigLocation().userConfigFile,
        onChange: (@MainActor () -> Void)? = nil
    ) -> AgentPaneNameSetting {
        if environment["XCTestConfigurationFilePath"] != nil {
            return AgentPaneNameSetting()
        }
        return AgentPaneNameSetting(
            store: JSONConfigStore(fileURL: configFile()),
            onChange: onChange ?? {
                AppDelegate.shared?.refreshAgentPaneCaptions()
            }
        )
    }
}
