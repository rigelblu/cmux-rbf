// cmux-rbf #cm-73.2a
import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DesignFocusShortcut", .serialized)
struct DesignFocusShortcutTests {

    private func makeTemporaryDirectory() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("cmux-df-shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }

    @Test("defaultShortcutAndProperties: verifies stroke, label, and group")
    func defaultShortcutAndProperties() {
        // Red proof: KeyboardShortcutSettings.Action.toggleDesignFocus.defaultShortcut is stubbed .unbound
        #expect(
            KeyboardShortcutSettings.Action.toggleDesignFocus.defaultShortcut ==
            StoredShortcut(key: "\r", command: true, shift: true, option: true, control: false)
        )
        #expect(
            KeyboardShortcutSettings.Action.toggleDesignFocus.label == "Toggle Design Focus"
        )
        // Red proof: ShortcutAction.toggleDesignFocus.defaultStroke is stubbed nil
        #expect(
            ShortcutAction.toggleDesignFocus.defaultStroke ==
            ShortcutStroke(key: "\r", command: true, shift: true, option: true)
        )
        #expect(
            ShortcutAction.toggleDesignFocus.displayName == "Toggle Design Focus"
        )
        #expect(
            ShortcutAction.toggleDesignFocus.group == .panes
        )
    }

    @Test("settingsFileStoreParsesCustomShortcut: cmux.json override is respected")
    func settingsFileStoreParsesCustomShortcut() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsFile = dir.appendingPathComponent("cmux.json", isDirectory: false)

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleDesignFocus": "cmd+opt+d"
              }
            }
            """,
            to: settingsFile
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFile.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .toggleDesignFocus) ==
            StoredShortcut(key: "d", command: true, shift: false, option: true, control: false)
        )
    }

    @Test("settingsFileStoreParsesDefaultCombination: opt+shift+cmd+enter parses from cmux.json")
    func settingsFileStoreParsesDefaultCombination() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsFile = dir.appendingPathComponent("cmux.json", isDirectory: false)

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleDesignFocus": "opt+shift+cmd+enter"
              }
            }
            """,
            to: settingsFile
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFile.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .toggleDesignFocus) ==
            StoredShortcut(key: "\r", command: true, shift: true, option: true, control: false)
        )
    }

    // cmux-rbf #cm-73.2a
    @Test("flipDesignFocusLayoutDefaultShortcutAndProperties: verifies stroke, label, and group")
    func flipDesignFocusLayoutDefaultShortcutAndProperties() {
        #expect(
            KeyboardShortcutSettings.Action.flipDesignFocusLayout.defaultShortcut ==
            StoredShortcut(key: "\\", command: true, shift: true, option: true, control: false)
        )
        #expect(
            KeyboardShortcutSettings.Action.flipDesignFocusLayout.label == "Flip Design Focus Layout"
        )
        #expect(
            ShortcutAction.flipDesignFocusLayout.defaultStroke ==
            ShortcutStroke(key: "\\", command: true, shift: true, option: true)
        )
        #expect(
            ShortcutAction.flipDesignFocusLayout.displayName == "Flip Design Focus Layout"
        )
        #expect(
            ShortcutAction.flipDesignFocusLayout.group == .panes
        )
    }

    // cmux-rbf #cm-73.2a
    @Test("settingsFileStoreParsesFlipDesignFocusLayout: opt+shift+cmd+backslash parses from cmux.json")
    func settingsFileStoreParsesFlipDesignFocusLayout() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsFile = dir.appendingPathComponent("cmux.json", isDirectory: false)

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "flipDesignFocusLayout": "opt+shift+cmd+\\\\"
              }
            }
            """,
            to: settingsFile
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFile.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .flipDesignFocusLayout) ==
            StoredShortcut(key: "\\", command: true, shift: true, option: true, control: false)
        )
    }

    @Test("toggleDesignFocusRefusedWhenNoFigmaTab: bare workspace refuses design focus")
    @MainActor
    func toggleDesignFocusRefusedWhenNoFigmaTab() {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        #expect(!workspace.canToggleDesignFocus)
        #expect(!workspace.toggleDesignFocus())
        #expect(!workspace.isDesignFocusActive)
    }

    @Test("toggleDesignFocusTogglesActiveState: workspace enters and leaves design focus")
    @MainActor
    func toggleDesignFocusTogglesActiveState() throws {
        _ = NSApplication.shared
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let terminalId = try #require(workspace.focusedPanelId)
        let figmaURL = URL(string: "https://www.figma.com/design/KEY/slug")!
        let browserPanel = try #require(
            workspace.newBrowserSplit(
                from: terminalId,
                orientation: .horizontal,
                url: figmaURL,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            )
        )
        _ = browserPanel

        #expect(workspace.canToggleDesignFocus)
        // Red proof: toggleDesignFocus() is stubbed returning false
        #expect(workspace.toggleDesignFocus())
        #expect(workspace.isDesignFocusActive)

        // Toggling again leaves design focus
        #expect(workspace.toggleDesignFocus())
        #expect(!workspace.isDesignFocusActive)
    }
}
