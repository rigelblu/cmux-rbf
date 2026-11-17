import CmuxSettings
import Foundation

/// Whether a Figma pane's header names its file: the setting `figma.showFileNameInHeader`,
/// held where `displayTitle` can read it without reading a file.
///
/// cmux-rbf #cm-73.43. One app-wide holder, ``current``, which both `displayTitle`s read
/// (`BrowserPanel`, `DeferredBrowserPanel`). Its public shape is final: ``current``,
/// ``showsFileName``, and an initialiser that takes a fixed value, which is how a test makes
/// its own holder. The default is on.
@MainActor
final class FigmaTabTitleSetting {
    /// The holder the app reads. Under the unit-test host (`XCTestConfigurationFilePath`) it gets
    /// no store and holds the default, on, so no test reads Tom's `cmux.json`. A test that needs
    /// another value installs its own holder for its run and puts this one back (`defer`), in the
    /// one `.serialized` suite that reads titles.
    static var current: FigmaTabTitleSetting = makeAppSetting()

    /// Whether a Figma file tab's title carries the file's name. Off reads just `Figma`.
    private(set) var showsFileName: Bool

    nonisolated(unsafe) private var watchTask: Task<Void, Never>?

    init(showsFileName: Bool = true) {
        self.showsFileName = showsFileName
    }

    init(
        store: JSONConfigStore?,
        onChange: (@MainActor () -> Void)? = nil
    ) {
        let key = SettingCatalog().figma.showFileNameInHeader
        self.showsFileName = store?.snapshotValue(for: key) ?? key.defaultValue
        guard let store else { return }
        watchTask = Task { @MainActor [weak self] in
            for await value in store.values(for: key) {
                guard let self, !Task.isCancelled else { break }
                if self.showsFileName != value {
                    self.showsFileName = value
                    onChange?()
                }
            }
        }
    }

    deinit {
        watchTask?.cancel()
    }

    /// Builds the holder the app reads: over `cmux.json`, re-titling every window on a change. The two
    /// parameters are the test seam (a test builds this holder with no test-host variable and a scratch
    /// file, so the app's own store and its own re-title closure run); the app passes neither.
    static func makeAppSetting(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configFile: @autoclosure () -> URL = CmuxConfigLocation().userConfigFile
    ) -> FigmaTabTitleSetting {
        if environment["XCTestConfigurationFilePath"] != nil {
            return FigmaTabTitleSetting()
        }
        return FigmaTabTitleSetting(
            store: JSONConfigStore(fileURL: configFile()),
            onChange: {
                AppDelegate.shared?.refreshFigmaTabTitles()
            }
        )
    }
}
