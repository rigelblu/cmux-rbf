import AppKit
import CmuxBrowser
import CoreGraphics
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux-rbf (#cm-73.3, step 5): one Back and Forward history across a Figma pane's
/// preview and editor, for `⌘[` / `⌘]` and the mouse's back and forward buttons.
/// Tom's rule, 2026-10-20 15:51, applied to the pointing rule on 2026-10-22.
@MainActor
@Suite("FigmaPaneBack", .serialized)
struct FigmaPaneBackTests {
    private let document = URL(string: "https://www.figma.com/design/KEY/screen")!

    private func editorLink(_ node: String) -> URL {
        URL(string: document.absoluteString + "?node-id=\(node)")!
    }

    /// `wrapper` stands in for cmux's own read-view page, as the app's default does.
    private func panel(on address: URL, wrapper: URL) -> BrowserPanel {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            chromeVisibility: .hidden,
            websiteDataStore: .nonPersistent()
        )
        panel.figmaPageWrapper = wrapper
        panel.publishObservedDocumentURL(address)
        return panel
    }

    private func wrapper() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm73-back-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("figma-embed.html")
    }

    private func node(_ pane: BrowserPanel, _ page: URL) -> String? {
        pane.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) }
    }

    private func showsPreview(_ pane: BrowserPanel, _ page: URL) -> Bool {
        pane.currentURL.map { FigmaPaneURL.isWrapperPage($0, wrapper: page) } ?? false
    }

    /// Figma's *Open in Figma* mark asks for a new tab; both delegates hand it to the pane as an in-pane request.
    private func clickOpenInFigma(_ pane: BrowserPanel, _ target: URL) throws {
        let delegate = try #require(pane.webView.navigationDelegate as? BrowserNavigationDelegate)
        let request = try #require(delegate.requestNavigation)
        request(URLRequest(url: target), .currentTab, nil)
    }

    @Test("Back on an editor Tom switched to shows the preview live; Forward brings the editor back live")
    func backAndForwardAcrossOneSwitch() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        let loader = DocumentLoader()
        try await loader.seed(previewView, value: "preview")
        pane.publishObservedDocumentURL(previewA)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        editorView.stopLoading()
        try await loader.seed(editorView, value: "editor")
        editorView.pageZoom = 1.4
        pane.publishObservedDocumentURL(editorLink("12-2"))
        let starts = NavigationStarts()
        let observations = [previewView, editorView].map { view in
            view.observe(\.isLoading, options: [.new]) { _, change in
                if change.newValue == true { starts.record() }
            }
        }
        defer { observations.forEach { $0.invalidate() } }

        pane.goBack()
        #expect(pane.webView === previewView, "Back stayed on the editor")
        #expect(showsPreview(pane, page))
        #expect(node(pane, page) == "12-2")
        try await Task.sleep(for: .milliseconds(200))
        #expect(starts.count == 0, "Back loaded the preview again")
        #expect(try await pane.webView.evaluateJavaScript("window.cm73Place") as? String == "preview", "Back reloaded the preview")

        pane.goForward()
        #expect(pane.webView === editorView, "Forward did not bring the same editor back")
        #expect(pane.webView.pageZoom == 1.4)
        try await Task.sleep(for: .milliseconds(200))
        #expect(starts.count == 0, "Forward loaded the editor again")
        #expect(try await pane.webView.evaluateJavaScript("window.cm73Place") as? String == "editor", "Forward reloaded the editor")
    }

    @Test("Within the editor, Back walks the editor's own pages before it crosses to the preview")
    func backWalksEditorOwnPagesFirst() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        editorView.stopLoading()
        // Two pages the editor loads itself, as Figma does when Tom moves inside it.
        for name in ["first", "second"] {
            let file = page.deletingLastPathComponent().appendingPathComponent("\(name).html")
            try "<html><body>\(name)</body></html>".write(to: file, atomically: true, encoding: .utf8)
            editorView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            for _ in 0..<200 {
                if editorView.url == file && !editorView.isLoading { break }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        pane.publishObservedDocumentURL(editorLink("12-2"))
        try #require(editorView.backForwardList.backList.count == 1, "fixture: the editor holds two pages of its own")

        pane.goBack()
        #expect(pane.webView === editorView, "Back left the editor before walking its own pages")
        for _ in 0..<200 {
            if editorView.backForwardList.backList.isEmpty && !editorView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editorView.backForwardList.backList.isEmpty, "Back did not move within the editor")

        pane.goBack()
        #expect(pane.webView === previewView, "Back did not cross to the preview after the editor's own pages")
    }

    @Test("Back after a pointing goes to where Tom was before it, not to the place he had gone back from")
    func pointingAfterBackDropsForwardPlaces() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.goBack()
        try #require(pane.webView === previewView)
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        pane.goForward()
        #expect(pane.webView === previewView, "Forward after a pointing went to a place the pointing replaced")
        #expect(node(pane, page) == "47-9")
        pane.goBack()
        #expect(pane.webView === previewView, "Back after a pointing went to the editor Tom had gone back from")
        #expect(node(pane, page) == "12-2")
    }

    @Test("Scenario 205: Back walks the agent's boards on the preview, in order, then Forward reverses to the same editor")
    func backWalksPreviewBoardsThenForwardReturnsToEditor() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        #expect(editorView !== previewView)

        pane.goBack()
        #expect(pane.webView === previewView, "Back did not return to the preview")
        #expect(node(pane, page) == "47-9")
        pane.goBack()
        #expect(pane.webView === previewView)
        #expect(node(pane, page) == "12-2", "Back did not walk to the agent's earlier board")
        pane.goForward()
        #expect(pane.webView === previewView)
        #expect(node(pane, page) == "47-9")
        pane.goForward()
        #expect(pane.webView === editorView, "Forward did not return to the same editor")
        #expect(!showsPreview(pane, page))
    }

    @Test("Across a pointing: Back reaches the preview, then reopens the dropped editor at its address; Forward reverses")
    func backAcrossPointingReopensDroppedEditor() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView

        // Preview A → Tom clicks Figma's Open in Figma mark → editor A.
        try clickOpenInFigma(pane, editorLink("12-2"))
        #expect(pane.webView !== previewView, "Open in Figma replaced the preview instead of opening the editor beside it")
        #expect(pane.currentURL == editorLink("12-2"))
        let editorA = pane.webView
        // Figma writes where Tom is into the editor's address; that is the address to reopen.
        let savedEditorA = editorLink("12-5")
        pane.publishObservedDocumentURL(savedEditorA)

        // The agent's goto B: preview B, editor A dropped.
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        #expect(pane.webView === previewView)
        #expect(node(pane, page) == "47-9")
        #expect(editorA.navigationDelegate == nil, "the pointing kept editor A")

        // Tom switches: a fresh editor on B.
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.webView !== editorA)
        #expect(node(pane, page) == "47-9")

        pane.goBack()
        #expect(pane.webView === previewView, "Back from editor B did not show preview B")
        #expect(node(pane, page) == "47-9")

        pane.goBack()
        #expect(!showsPreview(pane, page), "Back from preview B did not go to editor A")
        #expect(pane.currentURL == savedEditorA, "editor A did not reopen at its saved address")

        pane.goBack()
        #expect(pane.webView === previewView)
        #expect(node(pane, page) == "12-2", "Back from editor A did not reach preview A")

        pane.goForward()
        #expect(pane.currentURL == savedEditorA)
        pane.goForward()
        #expect(pane.webView === previewView)
        #expect(node(pane, page) == "47-9")
        pane.goForward()
        #expect(!showsPreview(pane, page))
        #expect(node(pane, page) == "47-9", "Forward did not end on editor B")
        pane.goForward()
        #expect(!showsPreview(pane, page), "Forward past the newest place changed the pane")
        #expect(node(pane, page) == "47-9")
    }

    @Test("Open in Figma on a node, then a switch, shows the preview on that node, not the first page")
    func openInFigmaThenSwitchShowsThatNode() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try clickOpenInFigma(pane, editorLink("12-2"))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(showsPreview(pane, page))
        #expect(node(pane, page) == "12-2", "the switch showed the file's first page")
        #expect(pane.webView === previewView, "the switch reloaded the preview")
    }

    @Test("Open in Figma with an editor already kept moves that editor to the board and keeps the preview behind")
    func openInFigmaMovesKeptEditor() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try clickOpenInFigma(pane, editorLink("55-6"))
        #expect(!showsPreview(pane, page))
        #expect(pane.currentURL == editorLink("55-6"))
        pane.goBack()
        #expect(pane.webView === previewView, "Back after Open in Figma did not return to the preview")
        #expect(node(pane, page) == "12-2")
    }

    @Test("A goto on an editor opened alone drops it; Back reopens it at its address")
    func gotoFromLoneEditorThenBackReopensEditor() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let pane = panel(on: document, wrapper: page)
        defer { pane.close() }
        let editorView = pane.webView
        let saved = editorLink("3-4")
        pane.publishObservedDocumentURL(saved)
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        #expect(pane.webView !== editorView, "the goto kept the lone editor's page under the preview")
        #expect(showsPreview(pane, page))
        #expect(node(pane, page) == "47-9")
        pane.goBack()
        #expect(!showsPreview(pane, page), "Back did not return to the editor")
        #expect(pane.currentURL == saved)
        pane.goForward()
        #expect(showsPreview(pane, page))
        #expect(node(pane, page) == "47-9")
    }

    @Test("The mouse's back and forward buttons cross sides through the same path")
    func mouseButtonsCrossSides() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        editorView.otherMouseDown(with: try mouseEvent(.otherMouseDown, button: 3))
        editorView.otherMouseUp(with: try mouseEvent(.otherMouseUp, button: 3))
        #expect(pane.webView === previewView, "mouse back did not cross to the preview")
        previewView.otherMouseDown(with: try mouseEvent(.otherMouseDown, button: 4))
        previewView.otherMouseUp(with: try mouseEvent(.otherMouseUp, button: 4))
        #expect(pane.webView === editorView, "mouse forward did not cross to the editor")
    }


    @Test("Trackpad swipe stays WebKit's own on both pages")
    func swipeStaysPerPage() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(previewView.allowsBackForwardNavigationGestures)
        #expect(pane.webView.allowsBackForwardNavigationGestures)
    }

    // Real loads below: the preview's wrapper page commits, so WebKit's own list is not empty.

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func listDump(_ view: WKWebView, _ page: URL) -> String {
        let back = view.backForwardList.backList.map { FigmaPaneURL.node(fromPaneURL: $0.url, wrapper: page) ?? $0.url.lastPathComponent }
        let cur = view.backForwardList.currentItem.map { FigmaPaneURL.node(fromPaneURL: $0.url, wrapper: page) ?? $0.url.lastPathComponent } ?? "nil"
        let fwd = view.backForwardList.forwardList.map { FigmaPaneURL.node(fromPaneURL: $0.url, wrapper: page) ?? $0.url.lastPathComponent }
        return "back=\(back) current=\(cur) forward=\(fwd)"
    }

    private func liveNode(_ view: WKWebView, _ page: URL) -> String? {
        view.url.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) }
    }

    /// Preview A, then the agent's goto B, both committed in the preview's own list.
    private func committedPreviewAB(_ page: URL) async throws -> (pane: BrowserPanel, preview: WKWebView) {
        try FigmaWrapperPage.install(at: page)
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        let previewView = pane.webView
        pane.navigate(to: previewA)
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil }, "fixture: preview A never committed")
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(await waitUntil {
            previewView.backForwardList.backList.count == 1 && liveNode(previewView, page) == "47-9"
        }, "fixture: goto B never committed: \(listDump(previewView, page))")
        return (pane, previewView)
    }

    @Test("Back at the first place, after Back returned to it, stays on it")
    func backPastFirstPlaceStays() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        try #require(pane.webView === previewView, "fixture: Back did not cross to preview B")
        pane.goBack()
        try #require(await waitUntil {
            liveNode(previewView, page) == "12-2" && !previewView.isLoading
        }, "fixture: Back to preview A never arrived: \(listDump(previewView, page))")
        let before = listDump(previewView, page)
        pane.goBack()
        try await Task.sleep(for: .milliseconds(1500))
        let shown = liveNode(previewView, page)
        #expect(shown == "12-2", "Back at the first place showed \(shown ?? "nil"); list before \(before), after \(listDump(previewView, page))")
        #expect(node(pane, page) == "12-2", "pane address after Back at the first place: \(String(describing: pane.currentURL))")
    }

    @Test("After the editor's own pages and a switch to the preview, Back, Back, Forward, Forward returns to the preview")
    func forwardAfterEditorOwnPagesReturnsToPreview() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        editorView.stopLoading()
        for name in ["first", "second"] {
            let file = page.deletingLastPathComponent().appendingPathComponent("\(name).html")
            try "<html><body>\(name)</body></html>".write(to: file, atomically: true, encoding: .utf8)
            editorView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            _ = await waitUntil(5) { editorView.url == file && !editorView.isLoading }
        }
        pane.publishObservedDocumentURL(editorLink("12-2"))
        try #require(editorView.backForwardList.backList.count == 1, "fixture: the editor holds two pages of its own")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.webView === previewView, "fixture: switch did not show the preview")
        pane.goBack()
        try #require(pane.webView === editorView, "fixture: Back did not cross to the editor")
        pane.goBack()
        try #require(await waitUntil(5) { editorView.backForwardList.backList.isEmpty && !editorView.isLoading }, "fixture: Back did not walk within the editor")
        pane.goForward()
        try #require(await waitUntil(5) { editorView.backForwardList.backList.count == 1 && !editorView.isLoading }, "fixture: Forward did not walk within the editor")
        pane.goForward()
        #expect(pane.webView === previewView, "Forward never returned to the preview Tom had switched to")
    }

    @Test("After WebKit's own Back on the preview (a swipe), ⌘[ stays without a load and ⌘] goes forward again")
    func keysFollowWebKitsOwnBack() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        previewView.goBack() // what a trackpad swipe does: WebKit's own list
        try #require(await waitUntil {
            previewView.backForwardList.backList.isEmpty && liveNode(previewView, page) == "12-2" && !previewView.isLoading
        }, "fixture: native back did not reach A: \(listDump(previewView, page))")
        // The swipe's own load must be over before counting the loads ⌘[ starts.
        try await Task.sleep(for: .milliseconds(300))
        let starts = NavigationStarts()
        let observation = previewView.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == true { starts.record() }
        }
        defer { observation.invalidate() }
        pane.goBack()
        try await Task.sleep(for: .milliseconds(500))
        #expect(starts.count == 0, "⌘[ at the first place after a swipe back loaded the preview again")
        #expect(previewView.backForwardList.forwardList.count == 1, "⌘[ after a swipe back dropped WebKit's forward page: \(listDump(previewView, page))")
        pane.goForward()
        let moved = await waitUntil(3) { liveNode(previewView, page) == "47-9" }
        #expect(moved, "⌘] after a native back did nothing: \(listDump(previewView, page)), canGoForward=\(pane.canGoForward)")
    }

    @Test("Back and Forward between the agent's boards use WebKit's own list, with no duplicate pages")
    func boardsUseWebKitsOwnList() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        try #require(pane.webView === previewView)
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: Back to A never arrived")
        #expect(previewView.backForwardList.backList.isEmpty && previewView.backForwardList.forwardList.count == 1,
                "Back between boards loaded a page instead of moving in WebKit's list: \(listDump(previewView, page))")
        pane.goForward()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: Forward to B never arrived")
        #expect(previewView.backForwardList.backList.count == 1 && previewView.backForwardList.forwardList.isEmpty,
                "Forward between boards loaded a page instead of moving in WebKit's list: \(listDump(previewView, page))")
    }

    @Test("Back at the first place, after the history loaded it again on top of another board, stays on it")
    func backAtReloadedFirstPlaceStays() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        try FigmaWrapperPage.install(at: page)
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        // Preview A is never loaded, so the agent's goto B takes WebKit's first slot.
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: goto B never committed")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        try #require(pane.webView === previewView, "fixture: Back did not cross to preview B")
        pane.goBack()
        try #require(await waitUntil {
            previewView.backForwardList.backList.count == 1 && liveNode(previewView, page) == "12-2" && !previewView.isLoading
        }, "fixture: A was not loaded again on top of B: \(listDump(previewView, page))")
        pane.goBack()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(liveNode(previewView, page) == "12-2", "Back at the first place walked into B's slot: \(listDump(previewView, page))")
    }

    @Test("After a swipe back into an earlier board, ⌘[ goes on from that board, to the editor before it")
    func backAfterSwipeGoesOnFromThere() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        try FigmaWrapperPage.install(at: page)
        let pane = panel(on: document, wrapper: page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("12-2", wrapper: page))
        let previewView = pane.webView
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: goto A never committed")
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(await waitUntil { previewView.backForwardList.backList.count == 1 && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: goto B never committed")
        previewView.goBack() // a trackpad swipe
        try #require(await waitUntil { previewView.backForwardList.backList.isEmpty && liveNode(previewView, page) == "12-2" }, "fixture: the swipe did not reach A")
        pane.goBack()
        #expect(!showsPreview(pane, page), "⌘[ after the swipe did not go on to the editor before board A: \(String(describing: pane.currentURL))")
    }

    @Test("The page moving to another file resets the history, with no page held behind it")
    func fileChangeWithoutHeldPageResets() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let pane = panel(on: document, wrapper: page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(pane.retainedFigmaPageAddress == nil, "fixture: the pointing dropped the editor")
        let otherFile = URL(string: "https://www.figma.com/design/OTHER/another-screen")!
        pane.publishObservedDocumentURL(otherFile)
        pane.goBack()
        let key = pane.currentURL.flatMap { FigmaPaneURL.fileKey(fromPaneURL: $0, wrapper: page) }
        #expect(key == "OTHER", "Back crossed into the previous file's editor: \(String(describing: pane.currentURL))")
    }

    @Test("A reopened editor uses its last Figma editor address, not a page it passed through")
    func reopenUsesLastEditorAddress() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        try clickOpenInFigma(pane, editorLink("12-2"))
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.publishObservedDocumentURL(editorLink("12-5"))
        // Figma's sign-in page, which the editor can pass through, and a link on Figma's
        // read-view host: the same file, but not an address the editor opens on.
        pane.publishObservedDocumentURL(URL(string: "https://www.figma.com/login?cont=x")!)
        pane.publishObservedDocumentURL(URL(string: "https://embed.figma.com/design/KEY/screen?node-id=9-9")!)
        pane.goBack()
        pane.goBack()
        pane.goForward()
        pane.goForward()
        #expect(pane.currentURL == editorLink("12-5"), "the editor reopened at \(String(describing: pane.currentURL))")
    }

    // Cold review 2 (verify2/verify-2.md): its probes P1, P2, P8, P8b and P8c, lifted, and the tests for its gaps.

    /// Commits a page at `address` in `view`'s own list, standing in for a Figma editor load (no network).
    private func commitEditorPage(_ view: WKWebView, _ address: URL) async throws {
        view.stopLoading()
        let before = view.backForwardList.currentItem
        _ = view.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<html><body>editor \(address.absoluteString)</body></html>")
        try #require(await waitUntil {
            view.backForwardList.currentItem !== before && view.backForwardList.currentItem?.url == address && !view.isLoading
        }, "fixture: simulated editor page \(address) never committed: \(String(describing: view.backForwardList.currentItem?.url)) back=\(view.backForwardList.backList.count)")
    }

    private func previewURL(_ node: String, _ page: URL) throws -> URL {
        try FigmaPaneURL.destination(for: document, node: node, wrapper: page).url
    }

    /// Scenario 205's pointing sequence with every load committed, stopped at preview A after Back x3.
    /// Editor A's saved address is 12-5; editor B is a separate page; the reopen of A goes into editor B's page.
    private func backThreeTimesCommitted(_ page: URL) async throws -> (pane: BrowserPanel, preview: WKWebView, editor: WKWebView) {
        try FigmaWrapperPage.install(at: page)
        let previewA = try previewURL("12-2", page)
        let pane = panel(on: previewA, wrapper: page)
        let previewView = pane.webView
        pane.navigate(to: previewA)
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && !previewView.isLoading }, "fixture: preview A")
        try clickOpenInFigma(pane, editorLink("12-2"))
        let editorA = pane.webView
        try #require(editorA !== previewView, "fixture: Open in Figma made no editor")
        try await commitEditorPage(editorA, editorLink("12-5"))
        pane.publishObservedDocumentURL(editorLink("12-5"))
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(await waitUntil { previewView.backForwardList.backList.count == 1 && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: goto B: \(listDump(previewView, page))")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorB = pane.webView
        try #require(editorB !== editorA && editorB !== previewView, "fixture: switch made no fresh editor")
        try await commitEditorPage(editorB, editorLink("47-9"))
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView && node(pane, page) == "47-9", "fixture: Back 1 to preview B")
        pane.goBack()
        try #require(pane.webView === editorB, "fixture: Back 2 reopens editor A in the held editor page")
        try await commitEditorPage(editorB, editorLink("12-5"))
        pane.publishObservedDocumentURL(editorLink("12-5"))
        try #require(editorB.backForwardList.backList.count == 1, "fixture: reopen at slot 1: \(listDump(editorB, page))")
        pane.goBack()
        try #require(await waitUntil { pane.webView === previewView && liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: Back 3 to preview A: \(listDump(previewView, page))")
        return (pane, previewView, editorB)
    }

    @Test("P1: after there and back, editor B moving itself does not take editor A's place: Back x3 reaches editor A at its address")
    func editorBOwnPageDoesNotReplaceEditorA() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, editorB) = try await backThreeTimesCommitted(page)
        defer { pane.close() }
        pane.goBack()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(pane.webView === previewView && liveNode(previewView, page) == "12-2", "one more Back left A: \(listDump(previewView, page))")
        pane.goForward()
        _ = await waitUntil(3) { !pane.webView.isLoading }
        #expect(pane.webView === editorB && pane.webView.url == editorLink("12-5"), "Forward 1 not editor A at E_A: \(String(describing: pane.webView.url))")
        pane.goForward()
        #expect(await waitUntil { pane.webView === previewView && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "Forward 2 not preview B: \(listDump(previewView, page))")
        pane.goForward()
        #expect(await waitUntil { pane.webView === editorB && editorB.backForwardList.backList.isEmpty && !editorB.isLoading }, "Forward 3 not editor B: \(listDump(editorB, page))")
        // Editor B moves itself, as Figma does when Tom moves inside it.
        try await commitEditorPage(editorB, editorLink("47-20"))
        pane.publishObservedDocumentURL(editorLink("47-20"))
        try #require(editorB.backForwardList.backList.count == 1, "fixture: editor B's own page: \(listDump(editorB, page))")
        pane.goBack()
        try #require(await waitUntil { editorB.backForwardList.backList.isEmpty && !editorB.isLoading }, "fixture: Back within editor B: \(listDump(editorB, page))")
        pane.goBack()
        try #require(pane.webView === previewView, "fixture: Back to preview B")
        pane.goBack()
        _ = await waitUntil(3) { !pane.webView.isLoading && pane.webView.url != editorLink("47-9") }
        #expect(pane.webView.url == editorLink("12-5"), "Back to editor A showed \(String(describing: pane.webView.url)); pane says \(String(describing: pane.currentURL)); editor list \(listDump(editorB, page))")
    }

    @Test("P2: Back to preview A, a swipe forward to B, then ⌘] goes on to the editor")
    func forwardAfterSwipeForwardGoesOn() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        try await commitEditorPage(editorView, editorLink("47-9"))
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView)
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: Back to A")
        previewView.goForward() // a trackpad swipe forward
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading && previewView.backForwardList.backList.count == 1 }, "fixture: swipe forward: \(listDump(previewView, page))")
        pane.goForward()
        #expect(pane.webView === editorView, "⌘] after a swipe forward to B stayed: pane \(String(describing: pane.currentURL)), item \(String(describing: previewView.backForwardList.currentItem?.url))")
    }

    /// A preview restored after a restart on C, with a restored history A, B behind it.
    private func restoredPreviewABC(_ page: URL) async throws -> (pane: BrowserPanel, preview: WKWebView, a: URL, b: URL, c: URL) {
        try FigmaWrapperPage.install(at: page)
        let a = try previewURL("12-2", page), b = try previewURL("47-9", page), c = try previewURL("55-6", page)
        let pane = panel(on: c, wrapper: page)
        let previewView = pane.webView
        pane.navigate(to: c)
        try #require(await waitUntil { previewView.url == c && !previewView.isLoading }, "fixture: preview C")
        pane.restoreSessionNavigationHistory(backHistoryURLStrings: [a.absoluteString, b.absoluteString], forwardHistoryURLStrings: [], currentURLString: c.absoluteString)
        return (pane, previewView, a, b, c)
    }

    @Test("P8: after a restart, a switch, Back to the preview and Back into its restored history, Forward reverses")
    func restoredHistoryAfterCrossingForwardReverses() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        try await commitEditorPage(editorView, editorLink("55-6"))
        pane.publishObservedDocumentURL(editorLink("55-6"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "55-6", "fixture: Back to preview C")
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: Back into the restored history did not reach B: \(listDump(previewView, page))")
        pane.goForward()
        let forwardToC = await waitUntil(3) { liveNode(previewView, page) == "55-6" && !previewView.isLoading }
        #expect(forwardToC, "⌘] from restored B did not return to C: \(listDump(previewView, page)), canGoForward=\(pane.canGoForward)")
        pane.goForward()
        #expect(pane.webView === editorView, "a second ⌘] did not reach the editor: \(String(describing: pane.currentURL))")
    }

    @Test("P8b: after a restart and a crossing, ⌘[ from restored B goes on to A, not to C")
    func restoredHistoryAfterCrossingBackGoesOn() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try await commitEditorPage(pane.webView, editorLink("55-6"))
        pane.publishObservedDocumentURL(editorLink("55-6"))
        pane.goBack()
        try #require(pane.webView === previewView, "fixture: Back to preview C")
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: Back to restored B: \(listDump(previewView, page))")
        pane.goBack()
        _ = await waitUntil(3) { liveNode(previewView, page) != "47-9" && !previewView.isLoading }
        #expect(liveNode(previewView, page) == "12-2", "⌘[ from restored B did not reach A: \(listDump(previewView, page))")
    }

    @Test("P8c control: with no crossing, a restored preview's Back then Forward stay upstream's")
    func restoredHistoryWithoutCrossingIsUpstreams() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "CONTROL fixture: restored Back: \(listDump(previewView, page))")
        pane.goForward()
        let forwardToC = await waitUntil(3) { liveNode(previewView, page) == "55-6" && !previewView.isLoading }
        #expect(forwardToC, "CONTROL: Forward from restored B: \(listDump(previewView, page))")
    }

    @Test("Once a restored preview's history has become places, the page does not replay it again after the history ends")
    func restoredHistoryIsNotReplayedTwice() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "55-6", "fixture: Back to preview C")
        // The page's address moves to another file, which ends the history.
        pane.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/OTHER/another-screen")!)
        let starts = NavigationStarts()
        let observation = previewView.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == true { starts.record() }
        }
        defer { observation.invalidate() }
        pane.goBack()
        try await Task.sleep(for: .milliseconds(500))
        #expect(starts.count == 0, "⌘[ replayed the restored history a second time: \(listDump(previewView, page))")
    }

    @Test("A repeat goto of the board showing adds no Back step and no load, even with a quick switch after it")
    func repeatGotoOfShownBoardIsOnePlace() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        // Tom switches before the repeat load has finished.
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        try #require(await waitUntil { !previewView.isLoading }, "fixture: the repeat load finished behind the editor")
        try #require(previewView.backForwardList.backList.count == 1, "fixture: WebKit reused B's slot: \(listDump(previewView, page))")
        let starts = NavigationStarts()
        let observation = previewView.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == true { starts.record() }
        }
        defer { observation.invalidate() }
        pane.goBack()
        try #require(pane.webView === previewView)
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "47-9" && starts.count == 0, "Back to B loaded it again: \(starts.count) loads, \(listDump(previewView, page))")
        pane.goBack()
        try #require(await waitUntil { !previewView.isLoading }, "fixture: Back settled")
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "12-2", "the repeat goto added a Back step: \(listDump(previewView, page))")
    }

    @Test("A switch made before the agent's board loads still comes Back to that board")
    func switchBeforeGotoCommitsComesBackToIt() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        try FigmaWrapperPage.install(at: page)
        let previewA = try previewURL("12-2", page)
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        pane.navigate(to: previewA)
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && !previewView.isLoading }, "fixture: preview A")
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(previewView.backForwardList.backList.isEmpty, "fixture: the switch must come before B commits")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try await commitEditorPage(pane.webView, editorLink("47-9"))
        try #require(await waitUntil { previewView.backForwardList.backList.count == 1 && !previewView.isLoading }, "fixture: B committed behind the editor: \(listDump(previewView, page))")
        pane.goBack()
        try #require(pane.webView === previewView)
        try await Task.sleep(for: .milliseconds(500))
        #expect(liveNode(previewView, page) == "47-9", "Back after a quick switch showed \(liveNode(previewView, page) ?? "nil"), not the agent's board: \(listDump(previewView, page))")
    }

    @Test("Back from an editor on Figma's sign-in page keeps that editor; Forward brings the same page back")
    func backFromSignInEditorKeepsIt() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewA = try previewURL("12-2", page)
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        pane.publishObservedDocumentURL(URL(string: "https://www.figma.com/login?cont=x")!)
        pane.goBack()
        try #require(showsPreview(pane, page), "fixture: Back from the sign-in page did not cross")
        #expect(pane.retainedFigmaPageAddress != nil, "Back released the editor on the sign-in page")
        pane.goForward()
        #expect(pane.webView === editorView, "Forward did not bring the same editor page back")
    }

    @Test("Forward at the newest place does not follow a page WebKit still holds from a dropped place")
    func forwardAtNewestPlaceIgnoresStaleWebKitPage() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading && previewView.backForwardList.forwardList.count == 1 }, "fixture: Back to A, B still forward in WebKit's list")
        // Two switches from A: the places after A go, but WebKit keeps B forward of A.
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.webView === previewView)
        pane.goForward()
        try await Task.sleep(for: .milliseconds(500))
        #expect(liveNode(previewView, page) == "12-2", "⌘] at the newest place went to the dropped board: \(listDump(previewView, page))")
    }

    @Test("A fit on a board, then Back from the editor and Back again, reaches the earlier board in one press")
    func fitKeepsBoardAsOnePlace() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("47-9", wrapper: page, purpose: .fit))
        try await Task.sleep(for: .milliseconds(300))
        try #require(await waitUntil { !previewView.isLoading }, "fixture: the fit reload never finished: \(listDump(previewView, page))")
        let afterFit = listDump(previewView, page)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        let starts = NavigationStarts()
        let observation = previewView.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == true { starts.record() }
        }
        defer { observation.invalidate() }
        pane.goBack()
        try #require(pane.webView === previewView)
        try await Task.sleep(for: .milliseconds(300))
        #expect(starts.count == 0, "Back to the fitted board loaded it again; list after the fit \(afterFit), now \(listDump(previewView, page))")
        pane.goBack()
        try #require(await waitUntil { !previewView.isLoading && liveNode(previewView, page) != nil }, "fixture: Back settled")
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "12-2", "Back after a fit showed \(liveNode(previewView, page) ?? "nil"); list after the fit \(afterFit), now \(listDump(previewView, page))")
    }

    @Test("A swipe between two editor places on one page, then a pointing: Back reopens the editor where Tom was")
    func swipeBetweenEditorPlacesThenPointingReopensWhereTomWas() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, _, editorB) = try await backThreeTimesCommitted(page)
        defer { pane.close() }
        pane.goForward()
        try #require(await waitUntil { pane.webView === editorB && editorB.url == editorLink("12-5") && !editorB.isLoading }, "fixture: editor A at slot 1")
        editorB.goBack() // a swipe into editor B's slot
        try #require(await waitUntil { editorB.url == editorLink("47-9") && !editorB.isLoading }, "fixture: the swipe: \(listDump(editorB, page))")
        pane.publishObservedDocumentURL(editorLink("47-9"))
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        pane.goBack()
        _ = await waitUntil(3) { !pane.webView.isLoading }
        #expect(!showsPreview(pane, page) && pane.currentURL == editorLink("47-9"), "Back after the pointing reopened \(String(describing: pane.currentURL)), not where Tom was")
    }

    // Cold review 3 (verify3/verify-3.md): its probes P9, P9d, P9p, P11 and P14, lifted as they are.

    @Test("Review 3 P9: restart on C, one restored ⌘[ to B, a switch, ⌘[ to preview B, then ⌘[ reaches A, not C")
    func review3RestoredWalkThenCrossing() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        pane.goBack() // restored history, before any crossing: upstream's replay loads B
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: restored Back to B: \(listDump(previewView, page))")
        let afterRestoredBack = listDump(previewView, page)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        try #require(editorView !== previewView, "fixture: switch made no editor")
        try await commitEditorPage(editorView, editorLink("47-9"))
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "47-9", "fixture: ⌘[ to preview B: \(listDump(previewView, page))")
        pane.goBack()
        _ = await waitUntil(3) { liveNode(previewView, page) != "47-9" && !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "12-2", "⌘[ from preview B showed \(liveNode(previewView, page) ?? "nil"); list after restored Back \(afterRestoredBack), now \(listDump(previewView, page))")
    }

    @Test("Review 3 P9d: restart on C, two restored ⌘[ to A, a switch, ⌘[ to preview A, one more ⌘[ stays on A")
    func review3RestoredWalkToOldestThenCrossing() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: restored Back to B")
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: restored Back to A: \(listDump(previewView, page))")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try await commitEditorPage(pane.webView, editorLink("12-2"))
        pane.publishObservedDocumentURL(editorLink("12-2"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "12-2", "fixture: ⌘[ to preview A: \(listDump(previewView, page))")
        pane.goBack()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(liveNode(previewView, page) == "12-2", "one more ⌘[ at A showed \(liveNode(previewView, page) ?? "nil"): \(listDump(previewView, page))")
    }

    @Test("Review 3 P9p: restart on C, one restored ⌘[ to B, the agent points at D, ⌘[ to B, then ⌘[ reaches A, not C")
    func review3RestoredWalkThenPointing() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: restored Back to B")
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        try #require(await waitUntil { liveNode(previewView, page) == "61-3" && !previewView.isLoading }, "fixture: goto D: \(listDump(previewView, page))")
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: ⌘[ to B: \(listDump(previewView, page))")
        pane.goBack()
        _ = await waitUntil(3) { liveNode(previewView, page) != "47-9" && !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "12-2", "⌘[ from B after a pointing showed \(liveNode(previewView, page) ?? "nil"): \(listDump(previewView, page))")
    }

    @Test("Review 3 P11: Tom's sequence, ⌘] x3, editor B moves itself, a swipe back in editor B, then ⌘[ x2 reaches editor A at its address")
    func review3EditorOwnNavigationThenSwipeBack() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, editorB) = try await backThreeTimesCommitted(page)
        defer { pane.close() }
        pane.goForward()
        _ = await waitUntil(3) { !pane.webView.isLoading }
        try #require(pane.webView === editorB && editorB.url == editorLink("12-5"), "fixture: ⌘] 1 to editor A: \(String(describing: pane.webView.url))")
        pane.goForward()
        try #require(await waitUntil { pane.webView === previewView && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: ⌘] 2 to preview B")
        pane.goForward()
        try #require(await waitUntil { pane.webView === editorB && editorB.backForwardList.backList.isEmpty && !editorB.isLoading }, "fixture: ⌘] 3 to editor B: \(listDump(editorB, page))")
        try await commitEditorPage(editorB, editorLink("47-20"))
        pane.publishObservedDocumentURL(editorLink("47-20"))
        editorB.goBack() // a trackpad swipe back within editor B
        try #require(await waitUntil { editorB.url == editorLink("47-9") && !editorB.isLoading && editorB.backForwardList.backList.isEmpty }, "fixture: swipe back: \(listDump(editorB, page))")
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "47-9", "fixture: ⌘[ to preview B: \(String(describing: pane.currentURL))")
        pane.goBack()
        _ = await waitUntil(3) { pane.webView === editorB && !editorB.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(pane.webView.url == editorLink("12-5"), "⌘[ to editor A showed \(String(describing: pane.webView.url)); pane \(String(describing: pane.currentURL)); editor list \(listDump(editorB, page))")
    }

    @Test("After review 3's P11, editor A's reload commits as editor A's place: ⌘] then reaches preview B")
    func reopenedEditorCommitIsItsPlace() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, editorB) = try await backThreeTimesCommitted(page)
        defer { pane.close() }
        pane.goForward()
        _ = await waitUntil(3) { !pane.webView.isLoading }
        try #require(pane.webView === editorB && editorB.url == editorLink("12-5"), "fixture: ⌘] 1 to editor A")
        pane.goForward()
        try #require(await waitUntil { pane.webView === previewView && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: ⌘] 2 to preview B")
        pane.goForward()
        try #require(await waitUntil { pane.webView === editorB && editorB.backForwardList.backList.isEmpty && !editorB.isLoading }, "fixture: ⌘] 3 to editor B")
        try await commitEditorPage(editorB, editorLink("47-20"))
        pane.publishObservedDocumentURL(editorLink("47-20"))
        editorB.goBack() // a trackpad swipe back within editor B
        try #require(await waitUntil { editorB.url == editorLink("47-9") && !editorB.isLoading && editorB.backForwardList.backList.isEmpty }, "fixture: swipe back")
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "47-9", "fixture: ⌘[ to preview B")
        pane.goBack()
        try #require(pane.webView === editorB && editorB.url == editorLink("12-5"), "fixture: ⌘[ reopens editor A: \(String(describing: editorB.url))")
        // Editor A's page arrives, as Figma's load of it would.
        try await commitEditorPage(editorB, editorLink("12-5"))
        pane.publishObservedDocumentURL(editorLink("12-5"))
        pane.goForward()
        #expect(await waitUntil(3) { pane.webView === previewView && liveNode(previewView, page) == "47-9" }, "⌘] from the reopened editor A did not reach preview B: pane \(String(describing: pane.currentURL)), editor list \(listDump(editorB, page))")
    }

    @Test("Review 3 P14: a Back the history loads (restored B), stopped before it commits, then ⌘] goes on to the editor")
    func review3StoppedHistoryLoadThenForward() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        try await commitEditorPage(editorView, editorLink("55-6"))
        pane.publishObservedDocumentURL(editorLink("55-6"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "55-6", "fixture: ⌘[ to preview C")
        pane.goBack()
        previewView.stopLoading()
        try await Task.sleep(for: .milliseconds(500))
        let afterStop = listDump(previewView, page)
        pane.goForward()
        try await Task.sleep(for: .milliseconds(500))
        // Known (fix round 3, the lead's call: no timing rule): this test's case only. A load the history starts
        // for Back or Forward, to reload a place WebKit no longer holds, and that is stopped before WebKit starts
        // it, sends no callback and keeps isLoading true with no commit for good (measured: progress 0.1 for 3 s,
        // fixes3/p14probe/run1.log). That looks the same as a load just issued, so ⌘] treats it as still on its
        // way. The pane has no Stop control, so a person cannot stop one.
        withKnownIssue("a history Back load stopped before it starts looks like one still on its way") {
            #expect(pane.webView === editorView, "⌘] after a stopped Back load: pane \(String(describing: pane.currentURL)), after stop \(afterStop), now \(listDump(previewView, page)), canGoForward=\(pane.canGoForward)")
        }
    }

    // Cold review 4 (verify4/verify-4.md): its probes V1, V3, V2, V2e and V2s, lifted as they are.

    @Test("Review 4 V1: restart on C, a switch, ⌘[ to preview C, ⌘[ starts restored B's load, ⌘] before it commits ends on C")
    func review4BackThenForwardBeforeRestoredLoadCommits() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = pane.webView
        try await commitEditorPage(editorView, editorLink("55-6"))
        pane.publishObservedDocumentURL(editorLink("55-6"))
        pane.goBack()
        try #require(pane.webView === previewView && liveNode(previewView, page) == "55-6", "fixture: ⌘[ to preview C")
        pane.goBack() // the history loads restored B into the preview
        let loadingAtForward = previewView.isLoading
        pane.goForward() // Tom's ⌘] before B commits
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "55-6", "⌘[ then ⌘] before the load committed showed \(liveNode(previewView, page) ?? "nil"), not C; loading at ⌘] \(loadingAtForward); \(listDump(previewView, page))")
        pane.goForward()
        #expect(pane.webView === editorView, "the next ⌘] did not reach the editor: \(String(describing: pane.currentURL))")
    }

    @Test("Review 4 V3: the agent's goto C on the preview, then one ⌘[ before C commits, ends on B")
    func review4BackDuringPointingLoad() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        let loadingAtBack = previewView.isLoading
        pane.goBack()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "47-9", "⌘[ during the goto's load showed \(liveNode(previewView, page) ?? "nil"), not B; loading at ⌘[ \(loadingAtBack); \(listDump(previewView, page))")
    }

    @Test("Review 4 V2: goto C, two ⌘[ before C commits, then ⌘] ⌘] shows C, not A")
    func review4TwoBacksDuringPointingLoadThenForward() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        pane.goBack()
        pane.goBack()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        let afterBacks = "\(liveNode(previewView, page) ?? "nil") \(listDump(previewView, page))"
        pane.goForward()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        let afterForward1 = "\(liveNode(previewView, page) ?? "nil") \(listDump(previewView, page))"
        pane.goForward()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "61-3", "⌘] ⌘] after two quick ⌘[ showed \(liveNode(previewView, page) ?? "nil"), not C; after backs \(afterBacks); after ⌘] 1 \(afterForward1); now \(listDump(previewView, page))")
    }

    @Test("Review 4 V2e: editor's own pages, a switch, Open in Figma moves the kept editor to 33-3; ⌘[ x3 before it commits, ⌘] x3 ends on 33-3")
    func review4OpenInFigmaThenThreeQuickBacks() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        try FigmaWrapperPage.install(at: page)
        let previewA = try previewURL("12-2", page)
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        pane.navigate(to: previewA)
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && !previewView.isLoading }, "fixture: preview A")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editor = pane.webView
        try #require(editor !== previewView, "fixture: no editor")
        try await commitEditorPage(editor, editorLink("12-2"))
        pane.publishObservedDocumentURL(editorLink("12-2"))
        try await commitEditorPage(editor, editorLink("12-5")) // the editor moves itself
        pane.publishObservedDocumentURL(editorLink("12-5"))
        try #require(editor.backForwardList.backList.count == 1, "fixture: editor's two pages: \(listDump(editor, page))")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.webView === previewView, "fixture: switch to preview")
        try clickOpenInFigma(pane, editorLink("33-3"))
        try #require(pane.webView === editor, "fixture: Open in Figma did not show the kept editor")
        let loadingAtBacks = editor.isLoading
        pane.goBack() // preview A
        pane.goBack() // editor 12-5
        pane.goBack() // editor 12-2
        try await Task.sleep(for: .milliseconds(1500))
        let afterBacks = "webView=\(pane.webView === editor ? "editor" : "preview") url=\(String(describing: editor.url)) \(listDump(editor, page))"
        pane.goForward()
        try await Task.sleep(for: .milliseconds(800))
        pane.goForward()
        try await Task.sleep(for: .milliseconds(800))
        let afterTwo = "webView=\(pane.webView === editor ? "editor" : "preview")"
        pane.goForward()
        try await Task.sleep(for: .milliseconds(800))
        #expect(pane.webView === editor && editor.url == editorLink("33-3"), "⌘] x3 after Open in Figma and three quick ⌘[ showed \(String(describing: editor.url)) (pane \(String(describing: pane.currentURL))); loading at the backs \(loadingAtBacks); after backs \(afterBacks); after ⌘] 2 \(afterTwo); \(listDump(editor, page))")
    }

    @Test("Review 4 V2s: goto C, a swipe back before C commits lands on A, then ⌘] goes on to B")
    func review4SwipeDuringPointingLoadThenForward() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        previewView.goBack() // a trackpad swipe back while the agent's board loads
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        let afterSwipe = "\(liveNode(previewView, page) ?? "nil") \(listDump(previewView, page))"
        pane.goForward()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "47-9", "⌘] after a swipe during the goto's load showed \(liveNode(previewView, page) ?? "nil"), not B; after swipe \(afterSwipe); now \(listDump(previewView, page))")
    }

    @Test("A pointing cancelled by a swipe stays cancelled: the page's next own load is a new place after the swipe's board")
    func swipeCancelledPointingDoesNotTakeALaterLoad() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        previewView.goBack() // a trackpad swipe back while the agent's board loads: lands on A
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: the swipe reached A: \(listDump(previewView, page))")
        try await Task.sleep(for: .milliseconds(300))
        // The page then loads another board itself, from A.
        pane.navigate(to: try previewURL("70-1", page))
        try #require(await waitUntil { liveNode(previewView, page) == "70-1" && !previewView.isLoading && previewView.backForwardList.forwardList.isEmpty }, "fixture: the page's own load: \(listDump(previewView, page))")
        try await Task.sleep(for: .milliseconds(300))
        pane.goBack()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        #expect(liveNode(previewView, page) == "12-2", "⌘[ after the page's own load showed \(liveNode(previewView, page) ?? "nil"), not A, the board it loaded from: \(listDump(previewView, page))")
    }

    // Cold review 5 (verify5/verify-5.md): its probe W3, lifted as it is.
    @Test("Review 5 W3: goto C, then ⌘[ and ⌘] before C commits, ends on C")
    func review5BackThenForwardDuringPointingLoad() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.gotoFigmaNode("61-3", wrapper: page))
        try #require(previewView.backForwardList.backList.count == 1, "fixture: C must not have committed")
        pane.goBack()
        pane.goForward()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !previewView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(liveNode(previewView, page) == "61-3", "⌘[ ⌘] during the goto's load showed \(liveNode(previewView, page) ?? "nil"), not C; loading \(previewView.isLoading); \(listDump(previewView, page))")
    }

    @Test("Tom's sequence fast: ⌘[ ⌘[ reopens editor A, then ⌘] ⌘] before it commits ends on editor B")
    func tomsSequenceFastForwardDuringReopen() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        try FigmaWrapperPage.install(at: page)
        let previewA = try previewURL("12-2", page)
        let pane = panel(on: previewA, wrapper: page)
        defer { pane.close() }
        let previewView = pane.webView
        pane.navigate(to: previewA)
        try #require(await waitUntil { previewView.backForwardList.currentItem != nil && !previewView.isLoading }, "fixture: preview A")
        try clickOpenInFigma(pane, editorLink("12-2"))
        let editorA = pane.webView
        try await commitEditorPage(editorA, editorLink("12-5"))
        pane.publishObservedDocumentURL(editorLink("12-5"))
        try #require(pane.gotoFigmaNode("47-9", wrapper: page))
        try #require(await waitUntil { previewView.backForwardList.backList.count == 1 && liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: goto B")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editorB = pane.webView
        try await commitEditorPage(editorB, editorLink("47-9"))
        pane.publishObservedDocumentURL(editorLink("47-9"))
        pane.goBack()
        try #require(pane.webView === previewView && node(pane, page) == "47-9", "fixture: ⌘[ to preview B")
        pane.goBack() // editor A reopens in editor B's page, from figma.com
        try #require(pane.webView === editorB, "fixture: ⌘[ reopens editor A in the held editor page")
        pane.goForward() // before editor A commits
        pane.goForward()
        try await Task.sleep(for: .milliseconds(300))
        _ = await waitUntil(3) { !editorB.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(pane.webView === editorB && editorB.url == editorLink("47-9"), "⌘] ⌘] during editor A's reopen showed \(pane.webView === editorB ? "the editor" : "the preview") at \(String(describing: pane.webView.url)); \(listDump(editorB, page))")
    }

    @Test("At the newest place, Forward is not offered even when WebKit still holds a page forward")
    func canGoForwardMatchesTheHistoryAtTheNewestPlace() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView) = try await committedPreviewAB(page)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.webView.stopLoading()
        pane.goBack()
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading && previewView.backForwardList.forwardList.count == 1 }, "fixture: Back to A, B still forward in WebKit's list")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try #require(pane.webView === previewView && previewView.canGoForward, "fixture: WebKit still offers B forward")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!pane.canGoForward, "Forward is offered at the newest place, where ⌘] does nothing")
        #expect(pane.canGoBack)
    }

    @Test("At the first place after a restart, Back is not offered even when WebKit holds the restored pages behind it")
    func canGoBackMatchesTheHistoryAtTheFirstPlace() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let (pane, previewView, _, _, _) = try await restoredPreviewABC(page)
        defer { pane.close() }
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "47-9" && !previewView.isLoading }, "fixture: restored Back to B")
        pane.goBack()
        try #require(await waitUntil { liveNode(previewView, page) == "12-2" && !previewView.isLoading }, "fixture: restored Back to A")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        try await commitEditorPage(pane.webView, editorLink("12-2"))
        pane.publishObservedDocumentURL(editorLink("12-2"))
        pane.goBack()
        try #require(pane.webView === previewView && previewView.canGoBack, "fixture: preview A with WebKit's replay pages behind it")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!pane.canGoBack, "Back is offered at the first place, where ⌘[ does nothing")
        #expect(pane.canGoForward)
    }

    private func mouseEvent(_ type: NSEvent.EventType, button: Int) throws -> NSEvent {
        let cgType: CGEventType = type == .otherMouseDown ? .otherMouseDown : .otherMouseUp
        let mouseButton = try #require(CGMouseButton(rawValue: UInt32(button)))
        let cgEvent = try #require(CGEvent(
            mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: .zero, mouseButton: mouseButton
        ))
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private final class NavigationStarts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class DocumentLoader: NSObject, WKNavigationDelegate {
        private var completion: CheckedContinuation<Void, Error>?
        private var expectedNavigation: WKNavigation?

        func seed(_ webView: WKWebView, value: String, baseURL: URL? = nil) async throws {
            let previous = webView.navigationDelegate
            defer {
                webView.navigationDelegate = previous
                expectedNavigation = nil
            }
            webView.navigationDelegate = self
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                completion?.resume(throwing: URLError(.timedOut))
                completion = nil
            }
            defer { deadline.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                expectedNavigation = webView.loadHTMLString("<html><body>Fixture</body></html>", baseURL: baseURL)
            }
            // A reload must erase this state; never bake it into the document.
            _ = try await webView.evaluateJavaScript("window.cm73Place='\(value)'")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === expectedNavigation else { return }
            completion?.resume()
            completion = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === expectedNavigation else { return }
            completion?.resume(throwing: error)
            completion = nil
        }
    }
}
