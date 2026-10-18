import AppKit
import Bonsplit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized) struct FigmaFileSubscriptionWorkspaceTests {
    // A delivery barrier on the exact queue used by the browser subscription, not a time delay.
    private func drainBrowserSubscription() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    @Test func realPanelPublishesAddressThenTitleThroughSubscription() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let panel = try #require(w.newFigmaSurface(inPane: pane))
        await drainBrowserSubscription()
        panel.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/A/Link-name")!)
        await drainBrowserSubscription()
        #expect(w.figmaFiles.entries.first?.name == "Link name")
        panel.publishObservedDocumentTitle("Published name – Figma")
        await drainBrowserSubscription()
        #expect(w.figmaFiles.entries.first?.name == "Published name")
    }
    @Test func restoredPanelFirstEmissionOnlySetsBaseline() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let panel = try #require(w.newFigmaSurface(inPane: pane))
        await drainBrowserSubscription()
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/A/First")!)
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/B/Second")!)
        let before = w.figmaFiles.entries
        w.beginFigmaFileRestore(panelID: panel.id, address: URL(string: "https://www.figma.com/design/A/First")!)
        panel.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/A/First")!)
        await drainBrowserSubscription()
        #expect(w.figmaFiles.entries == before)
        panel.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/C/Third")!)
        await drainBrowserSubscription()
        #expect(w.figmaFiles.entries.map(\.key) == ["C", "B", "A"])
    }
}
