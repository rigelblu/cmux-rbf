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

/// Scenario 91: the panel's state follows its load, the script's answer, a failure and the Swift deadline.
@MainActor
@Suite("FigmaLoadBarSignal", .serialized)
struct FigmaLoadBarSignalTests {

    private static let fileList = "https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed"
    private static let pageWithControl = """
        <!doctype html><html><body>
        <button aria-label="Minimize UI" onclick="window.__minimized = (window.__minimized || 0) + 1">Minimize UI</button>
        </body></html>
        """
    private static let pageWithLateControl = """
        <!doctype html><html><body>
        <script>
        setTimeout(() => {
            var b = document.createElement("button");
            b.setAttribute("aria-label", "Minimize UI");
            b.onclick = function() { window.__minimized = (window.__minimized || 0) + 1; };
            b.textContent = "Minimize UI";
            document.body.appendChild(b);
        }, 1000);
        </script>
        </body></html>
        """
    private static let pageWithoutControl = """
        <!doctype html><html><body>
        <script>
        window.__warned = [];
        console.warn = function(msg) { window.__warned.push(msg); };
        </script>
        <p>No control</p>
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

    private func eventually(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    private func clicks(_ panel: BrowserPanel) async -> Int {
        let value = try? await panel.webView.evaluateJavaScript("window.__minimized || 0")
        return (value as? NSNumber)?.intValue ?? -1
    }

    private func loadFileListPage(into panel: BrowserPanel, html: String) async throws {
        panel.webView.navigationDelegate = nil
        panel.webView.loadHTMLString(html, baseURL: URL(string: Self.fileList))
        let loaded = await eventually {
            !panel.webView.isLoading
                && panel.webView.url?.absoluteString == Self.fileList
                && panel.currentURL?.absoluteString == Self.fileList
        }
        try #require(loaded, "the stub page did not load")
    }

    private func pushState(_ panel: BrowserPanel, to path: String) async {
        _ = try? await panel.webView.evaluateJavaScript("history.pushState({}, '', '\(path)')")
    }

    @Test("finishedOnTheEditorWaits: editor load leaves state waiting, read view leaves it not waiting")
    func finishedOnTheEditorWaits() {
        let state = FigmaLoadBarState()
        state.begin(isErrorPage: false)
        state.finished(
            url: URL(string: "https://www.figma.com/design/KEY/a"),
            isOmnibarVisible: false,
            isErrorPage: false
        )
        guard case .waiting = state.editorWait else {
            Issue.record("expected waiting state on editor link")
            return
        }

        state.finished(
            url: URL(fileURLWithPath: "/tmp/cmux-figma-read.html"),
            isOmnibarVisible: false,
            isErrorPage: false
        )
        #expect(state.editorWait == .notWaiting)
    }

    @Test("controlFoundEndsTheWait: script answers found, clicks button, and ends the wait")
    func controlFoundEndsTheWait() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: false)
        try await loadFileListPage(into: panel, html: Self.pageWithControl)

        await pushState(panel, to: "/design/KEY/a")
        let clicked = await eventually { await clicks(panel) == 1 }
        #expect(clicked, "button was not clicked")

        let waitEnded = await eventually { panel.figmaLoadBar.editorWait == .notWaiting }
        #expect(waitEnded, "wait did not end after control was found")
    }

    @Test("noControlTimesOut: script answers timeout after 500ms, logs warning, and ends wait")
    func noControlTimesOut() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: false)
        panel.figmaMinimizeTimeoutMilliseconds = 500
        panel.figmaLoadBar.deadlineSeconds = 60
        try await loadFileListPage(into: panel, html: Self.pageWithoutControl)

        await pushState(panel, to: "/design/KEY/a")
        let waitEnded = await eventually(seconds: 4) { panel.figmaLoadBar.editorWait == .notWaiting }
        #expect(waitEnded, "wait did not end after timeout")

        let warned = try? await panel.webView.evaluateJavaScript("window.__warned || []") as? [String]
        #expect(warned?.contains("[cmux] figma: no minimize control after 500ms") == true)
    }

    @Test("staleAnswerIsDropped: answer with an older wait ID does not end current wait")
    func staleAnswerIsDropped() {
        let state = FigmaLoadBarState()
        state.finished(
            url: URL(string: "https://www.figma.com/design/KEY/a"),
            isOmnibarVisible: false,
            isErrorPage: false
        )
        guard case let .waiting(_, currentID) = state.editorWait else {
            Issue.record("expected waiting state")
            return
        }

        let staleID = currentID - 1
        state.scriptAnswered(waitID: staleID)
        guard case let .waiting(_, remainingID) = state.editorWait else {
            Issue.record("expected state to remain waiting")
            return
        }
        #expect(remainingID == currentID)
    }

    @Test("deadlineEndsAWaitWithNoAnswer: Swift timer ends wait when timeout expires")
    func deadlineEndsAWaitWithNoAnswer() async throws {
        let state = FigmaLoadBarState()
        state.deadlineSeconds = 0.5
        state.finished(
            url: URL(string: "https://www.figma.com/design/KEY/a"),
            isOmnibarVisible: false,
            isErrorPage: false
        )
        guard case .waiting = state.editorWait else {
            Issue.record("expected waiting state")
            return
        }

        let deadline = Date().addingTimeInterval(2.5)
        var ended = false
        while Date() < deadline {
            if state.editorWait == .notWaiting {
                ended = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(ended, "deadline did not end wait within 2.5s")
    }

    @Test("failureIsNotRefilledByTheErrorPage: error page preserves failed state and keeps bar hidden")
    func failureIsNotRefilledByTheErrorPage() {
        let state = FigmaLoadBarState()
        state.failed()
        #expect(state.editorWait == .failed)

        state.begin(isErrorPage: true)
        #expect(state.editorWait == .failed)

        state.finished(
            url: URL(string: "about:blank"),
            isOmnibarVisible: false,
            isErrorPage: true
        )
        #expect(state.editorWait == .failed)

        let phase = FigmaLoadBar.phase(
            isFigmaPane: true,
            isLoading: true,
            progress: 0.5,
            editorWait: state.editorWait,
            now: Date(),
            deadline: 22
        )
        #expect(phase == .hidden)

        state.begin(isErrorPage: false)
        #expect(state.editorWait == .notWaiting)
    }

    @Test("fullLoadOnEditorStartsWaitAndCollapses: full load through navigation delegate waits on finish and collapses")
    func fullLoadOnEditorStartsWaitAndCollapses() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: false)
        panel.figmaMinimizeTimeoutMilliseconds = 3000
        panel.figmaLoadBar.deadlineSeconds = 60
        let editorURL = try #require(URL(string: "https://www.figma.com/design/KEY/a"))
        panel.webView.applyBrowserUserAgentPolicy(for: editorURL)
        panel.webView.loadHTMLString(Self.pageWithLateControl, baseURL: editorURL)

        let isWaiting = await eventually {
            if case .waiting = panel.figmaLoadBar.editorWait { return true }
            return false
        }
        #expect(isWaiting, "expected editorWait to be waiting before control appears")

        let clicked = await eventually(seconds: 4) { await clicks(panel) == 1 }
        #expect(clicked, "button was not clicked on full load")

        let waitEnded = await eventually(seconds: 4) { panel.figmaLoadBar.editorWait == .notWaiting }
        #expect(waitEnded, "editorWait did not end after collapse on full load")
    }

    @Test("inPlaceNonEditorEndsWait: in-place navigation to non-editor ends running wait")
    func inPlaceNonEditorEndsWait() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try makePanel(in: workspace, addressBar: false)
        try await loadFileListPage(into: panel, html: Self.pageWithoutControl)

        await pushState(panel, to: "/design/KEY/a")
        let waiting = await eventually {
            if case .waiting = panel.figmaLoadBar.editorWait { return true }
            return false
        }
        #expect(waiting, "expected in-place editor to start waiting")

        await pushState(panel, to: "/files/team/1/recents-and-sharing/recently-viewed")
        let waitEnded = await eventually { panel.figmaLoadBar.editorWait == .notWaiting }
        #expect(waitEnded, "in-place non-editor navigation did not end running wait")
    }

    @Test("inPlaceNonEditorStateEndsWait: inPlaceNonEditorOpened resets waiting to notWaiting and leaves failed intact")
    func inPlaceNonEditorStateEndsWait() {
        let state = FigmaLoadBarState()
        state.inPlaceEditorOpened()
        guard case .waiting = state.editorWait else {
            Issue.record("expected waiting state")
            return
        }
        state.inPlaceNonEditorOpened()
        #expect(state.editorWait == .notWaiting)

        state.failed()
        #expect(state.editorWait == .failed)
        state.inPlaceNonEditorOpened()
        #expect(state.editorWait == .failed, "inPlaceNonEditorOpened must not clear failed state")
    }
}
