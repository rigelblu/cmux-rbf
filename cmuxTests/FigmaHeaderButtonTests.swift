import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-73.9`'s button as the header's list sees it: where it sits in the default
/// list, that a person's own list has it only when it names it, the id people
/// write in `cmux.json`, and that its click goes the custom way so it carries the
/// pane that was clicked. Every test builds its own config text in a temporary
/// folder; none reads `~/.config/cmux/cmux.json`.
@MainActor
@Suite("FigmaHeaderButton", .serialized)
struct FigmaHeaderButtonTests {

    private static let terminal = "cmux.newTerminal"
    private static let browser = "cmux.newBrowser"
    private static let figma = "cmux.newFigma"
    private static let splitRight = "cmux.splitRight"
    private static let splitDown = "cmux.splitDown"

    /// A store that read `global` as its only config file.
    private func loadedStore(global: String) throws -> (store: CmuxConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-figma-header-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("cmux.json")
        try global.write(to: path, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(globalConfigPath: path.path, localConfigPath: nil, startFileWatchers: false)
        store.loadAll()
        return (store, root)
    }

    private func buttonList(_ ids: [String]) -> String {
        let quoted = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{ "ui": { "surfaceTabBar": { "buttons": [\#(quoted)] } } }"#
    }

    @Test("defaultListHasFigmaThird: five entries, the Figma button after the globe, and the same five once resolved")
    func defaultListHasFigmaThird() throws {
        let expected = [Self.terminal, Self.browser, Self.figma, Self.splitRight, Self.splitDown]
        #expect(CmuxSurfaceTabBarButton.defaults.map(\.id) == expected)

        // The list a person with no `ui.surfaceTabBar.buttons` gets, after the registry has filled it.
        let (store, root) = try loadedStore(global: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.surfaceTabBarButtons.map(\.id) == expected)
        #expect(store.surfaceTabBarButtons[2].action == .builtIn(.newFigma))
    }

    @Test("configuredListWithoutFigmaHasNoFigmaButton: a list that names only the terminal and the browser has two buttons")
    func configuredListWithoutFigmaHasNoFigmaButton() throws {
        let (store, root) = try loadedStore(global: buttonList([Self.terminal, Self.browser]))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.surfaceTabBarButtons.map(\.id) == [Self.terminal, Self.browser])
        #expect(!store.surfaceTabBarButtons.contains { $0.action == .builtIn(.newFigma) })
    }

    @Test("configuredListNamingFigmaHasIt: the same list plus the id has three buttons, the Figma one last")
    func configuredListNamingFigmaHasIt() throws {
        let (store, root) = try loadedStore(global: buttonList([Self.terminal, Self.browser, Self.figma]))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.surfaceTabBarButtons.map(\.id) == [Self.terminal, Self.browser, Self.figma])
        #expect(store.surfaceTabBarButtons.last?.action == .builtIn(.newFigma))
    }

    @Test("configIDRoundTrips: cmux.newFigma is the built-in, and the built-in's id is cmux.newFigma")
    func configIDRoundTrips() {
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "cmux.newFigma") == .newFigma)
        #expect(CmuxSurfaceTabBarBuiltInAction.newFigma.configID == "cmux.newFigma")
        #expect(CmuxSurfaceTabBarBuiltInAction.allCases.contains(.newFigma))
    }

    @Test("figmaButtonGoesTheCustomWay: no Bonsplit action of its own, so the click carries the clicked pane")
    func figmaButtonGoesTheCustomWay() throws {
        #expect(CmuxSurfaceTabBarBuiltInAction.newFigma.bonsplitAction == nil)

        // And the button the header is handed asks for the custom route under its own id.
        let (store, root) = try loadedStore(global: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let button = try #require(store.surfaceTabBarButtons.first { $0.action == .builtIn(.newFigma) })
        let handed = button.bonsplitActionButton(configSourcePath: nil, globalConfigPath: store.globalConfigPath)
        #expect(handed.action == .custom("cmux.newFigma"))
        // cmux-rbf #cm-73.16: the header names its menu; the palette keeps New Tab (Figma).
        #expect(handed.tooltip == "Figma")
    }

    @Test("defaultButtonDrawsFigmasImage: the button the header is handed carries image data, not a symbol, in the default list and in a project's own list")
    func defaultButtonDrawsFigmasImage() throws {
        let (store, root) = try loadedStore(global: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let button = try #require(store.surfaceTabBarButtons.first { $0.action == .builtIn(.newFigma) })
        for source in [nil, "/tmp/some-project/.cmux/cmux.json"] as [String?] {
            let handed = button.bonsplitActionButton(
                configSourcePath: source,
                globalConfigPath: store.globalConfigPath,
                allowProjectLocalIcon: false
            )
            guard case .imageData = handed.icon else {
                Issue.record("config source \(source ?? "none"): the icon is \(handed.icon)")
                continue
            }
        }
        // A person's own icon still wins.
        let own = CmuxSurfaceTabBarButton.builtIn(.newFigma, icon: .symbol("star"))
        let ownHanded = own.bonsplitActionButton(configSourcePath: nil, globalConfigPath: store.globalConfigPath)
        guard case .systemImage("star") = ownHanded.icon else {
            Issue.record("a configured icon was replaced: \(ownHanded.icon)")
            return
        }
    }

    @Test("figmaButtonsSymbolIsPaintpalette: the symbol drawn where only a symbol can be, not the image's question mark")
    func figmaButtonsSymbolIsPaintpalette() {
        #expect(CmuxSurfaceTabBarBuiltInAction.newFigma.defaultIcon == "paintpalette")
        #expect(CmuxSurfaceTabBarButtonAction.builtIn(.newFigma).defaultIcon == "paintpalette")
        #expect(CmuxSurfaceTabBarButtonAction.builtIn(.newBrowser).defaultIcon == "globe")
    }

    @Test("configTextNamingTheIdResolvesToTheBuiltIn: an action in cmux.json named cmux.newFigma is the built-in action")
    func configTextNamingTheIdResolvesToTheBuiltIn() throws {
        let (store, root) = try loadedStore(global: """
        { "actions": { "cmux.newFigma": { "shortcut": "cmd+opt+shift+f" } } }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let action = try #require(store.resolvedAction(id: "cmux.newFigma"))
        #expect(action.action == .builtIn(.newFigma))
        #expect(action.shortcut != nil, "the shortcut the text gave it is the built-in's")
        #expect(store.configurationIssues.isEmpty)
    }
}
