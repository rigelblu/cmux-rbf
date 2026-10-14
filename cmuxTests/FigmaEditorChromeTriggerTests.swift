import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The wiring behind `FigmaEditorChromeAddressChangeTests`' rule, in a real web
/// view and with no network: a page loaded from a string, with Figma's file list
/// as its base address and a stub button that stands in for Figma's *Minimize UI*
/// control and counts its clicks. `history.pushState` changes the address in place,
/// as Figma does when a file is opened from its list.
@MainActor
@Suite("FigmaEditorChromeTrigger", .serialized)
struct FigmaEditorChromeTriggerTests {

    private static let fileList = "https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed"
    private static let page = """
        <!doctype html><html><body>
        <button aria-label="Minimize UI" onclick="window.__minimized = (window.__minimized || 0) + 1">Minimize UI</button>
        </body></html>
        """

    private func makePanel(in workspace: Workspace, addressBar: Bool) throws -> BrowserPanel {
        _ = NSApplication.shared
        let terminal = try #require(workspace.focusedPanelId)
        return try #require(workspace.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            url: nil,
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: addressBar)
        ))
    }

    /// Polls the main actor for up to `seconds`; the web view's callbacks run on it.
    private func eventually(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    private func clicks(_ panel: BrowserPanel) async -> Int {
        let value = try? await panel.webView.evaluateJavaScript("window.__minimized || 0")
        return (value as? NSNumber)?.intValue ?? -1
    }

    private func loadFileListPage(into panel: BrowserPanel) async throws {
        // The panel's navigation delegate turns a load of a string with an https base address into a real
        // load of that address, which would reach Figma over the network. Without the delegate the page
        // loads from the string. What is under test is the panel's address observer, which does not use it.
        panel.webView.navigationDelegate = nil
        panel.webView.loadHTMLString(Self.page, baseURL: URL(string: Self.fileList))
        var trace: [String] = []
        let loaded = await eventually {
            let line = "\(panel.webView.url?.absoluteString ?? "nil") loading=\(panel.webView.isLoading) current=\(panel.currentURL?.absoluteString ?? "nil")"
            if trace.last != line { trace.append(line) }
            return !panel.webView.isLoading && panel.webView.url?.absoluteString == Self.fileList
                && panel.currentURL?.absoluteString == Self.fileList
        }
        try #require(loaded, "the stub page did not load: \(trace.joined(separator: " | "))")
        let before = await clicks(panel)
        try #require(before == 0)
    }

    private func pushState(_ panel: BrowserPanel, to path: String) async {
        _ = try? await panel.webView.evaluateJavaScript("history.pushState({}, '', '\(path)')")
    }

    @Test("inPlaceChangeToAFileCollapsesOnce: a file opened from the list with no page load, then a frame added to it")
    func inPlaceChangeToAFileCollapsesOnce() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: false)
        try await loadFileListPage(into: panel)

        await pushState(panel, to: "/design/KEY/a")
        let collapsed = await eventually { await clicks(panel) == 1 }
        #expect(collapsed, "the observer did not run the collapse for an in-place change to a file")

        // The same file with a frame: no second collapse. The script clicks at once when the
        // control is there, so a short settle is enough to see a second one if it were run.
        await pushState(panel, to: "/design/KEY/a?node-id=1-2")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await clicks(panel) == 1)
    }

    @Test("addressBarShownDoesNotCollapse: an ordinary browser tab on the same change")
    func addressBarShownDoesNotCollapse() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: true)
        try await loadFileListPage(into: panel)

        await pushState(panel, to: "/design/KEY/a")
        let moved = await eventually { panel.currentURL?.path == "/design/KEY/a" }
        try #require(moved, "the address did not change")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await clicks(panel) == 0)
    }
}
