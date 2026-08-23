import AppKit
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link open coordinator", .serialized)
struct TerminalLinkOpenCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "terminal-link-open-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        defaults.set(
            true,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )
        return defaults
    }

    @Test("Embedded URL without an owning container falls back externally")
    @MainActor
    func unresolvedSourceFallsBackExternally() throws {
        let defaults = makeDefaults()
        let url = try #require(URL(string: "https://example.com/unresolved"))
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(externallyOpened == [url])
    }

    @Test("Explicit default-browser action opens exactly once")
    @MainActor
    func explicitDefaultBrowserActionOpensExactlyOnce() throws {
        let defaults = makeDefaults()
        let url = try #require(URL(string: "https://example.com/explicit"))
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.openInDefaultBrowser(url))
        #expect(externallyOpened == [url])
        #expect(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }

    @Test("Explicit default-browser failure returns false without retrying")
    @MainActor
    func explicitDefaultBrowserFailureDoesNotRetry() throws {
        let defaults = makeDefaults()
        let url = try #require(URL(string: "https://example.com/refused"))
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return false
            },
            deferOperation: { operation in operation() }
        )

        #expect(!coordinator.openInDefaultBrowser(url))
        #expect(externallyOpened == [url])
        #expect(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }

    @Test("Dock terminal links split once, then reuse the right browser pane")
    @MainActor
    func dockEmbeddedLinksReuseThenSplit() throws {
        let defaults = makeDefaults()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == terminalPanelId ? store : nil
            },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: firstURL.absoluteString,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))
        #expect(store.bonsplitController.allPaneIds.count == 2)

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: secondURL.absoluteString,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))
        #expect(store.bonsplitController.allPaneIds.count == 2)

        let browserPanels = store.bonsplitController.allTabIds.compactMap {
            store.panel(for: $0) as? BrowserPanel
        }
        #expect(browserPanels.count == 2)
        #expect(Set(browserPanels.compactMap { $0.preferredURLStringForOmnibar() }) == [
            firstURL.absoluteString,
            secondURL.absoluteString,
        ])
        #expect(externallyOpened.isEmpty)
    }

    @Test(
        "Visible HTML paths open in Browser instead of File Preview",
        arguments: ["html", "htm"]
    )
    @MainActor
    func visibleHTMLPathOpensInBrowser(pathExtension: String) throws {
        _ = NSApplication.shared
        let defaults = makeDefaults()
        let htmlURL = try makeHTMLFixture(pathExtension: pathExtension)
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path,
            defaults: defaults
        ))

        let browser = try #require(
            workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(browser.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(!workspace.panels.values.contains { $0 is FilePreviewPanel })
    }

    @Test("Dock HTML paths open in Browser instead of externally")
    @MainActor
    func dockHTMLPathOpensInBrowser() throws {
        let defaults = makeDefaults()
        let htmlURL = try makeHTMLFixture(pathExtension: "html")
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == terminalPanelId ? store : nil
            },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: htmlURL.path,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))

        let browserPanels = store.bonsplitController.allTabIds.compactMap {
            store.panel(for: $0) as? BrowserPanel
        }
        #expect(browserPanels.count == 1)
        #expect(browserPanels.first?.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(externallyOpened.isEmpty)
    }

    private func makeHTMLFixture(pathExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-html-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("index.\(pathExtension)")
        try "<h1>hello</h1><p style=\"color:green\">rendered</p>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        return fileURL
    }
}

@Suite("Terminal context menu links")
struct TerminalContextMenuLinkTests {
    @Test("Only routed embedded-browser targets are eligible")
    @MainActor
    func webOnlyEligibility() throws {
        let https = try #require(TerminalContextMenuLinkAction(
            rawValue: "https://example.com/path",
            isTerminalViewport: true
        ))
        #expect(https.url.absoluteString == "https://example.com/path")

        let http = try #require(TerminalContextMenuLinkAction(
            rawValue: "http://example.com/path",
            isTerminalViewport: true
        ))
        #expect(http.url.absoluteString == "http://example.com/path")

        let bare = try #require(TerminalContextMenuLinkAction(
            rawValue: "example.com/path",
            isTerminalViewport: true
        ))
        #expect(bare.url.host == "example.com")

        for rawValue in [
            "/tmp/cm-46.txt",
            "file:///tmp/cm-46.txt",
            "mailto:test@example.com",
            "ftp://example.com/file",
            "https:///tmp/cmux.txt",
            "",
            "not a link",
        ] {
            #expect(TerminalContextMenuLinkAction(
                rawValue: rawValue,
                isTerminalViewport: true
            ) == nil)
        }
        #expect(TerminalContextMenuLinkAction(
            rawValue: nil,
            isTerminalViewport: true
        ) == nil)
    }

    @Test("Pane chrome rejects a stale terminal link candidate")
    @MainActor
    func paneChromeIsIneligible() {
        #expect(TerminalContextMenuLinkAction(
            rawValue: "https://stale.example/terminal",
            isTerminalViewport: false
        ) == nil)
    }

    @Test("Link action stays first and snapshots its URL")
    @MainActor
    func menuShapeAndSnapshot() throws {
        let originalURL = "https://example.com/original"
        var rawValue = originalURL
        let action = try #require(TerminalContextMenuLinkAction(
            rawValue: rawValue,
            isTerminalViewport: true
        ))
        rawValue = "https://example.com/replaced"

        for existingItems in [
            ["Paste"],
            ["Copy", "Paste"],
            ["Trigger Flash", "-", "Copy", "Paste"],
        ] {
            let menu = NSMenu()
            for title in existingItems {
                menu.addItem(title == "-"
                    ? .separator()
                    : NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }

            action.prepend(
                to: menu,
                target: nil,
                action: NSSelectorFromString("terminalContextMenuTestAction:")
            )

            #expect(menu.items[0].title == String(
                localized: "browser.openInDefaultBrowser",
                defaultValue: "Open in Default Browser"
            ))
            #expect(menu.items[1].isSeparatorItem)
            #expect(menu.items.dropFirst(2).map { $0.isSeparatorItem ? "-" : $0.title } == existingItems)
            #expect((menu.items[0].representedObject as? URL)?.absoluteString == originalURL)
        }
    }
}
