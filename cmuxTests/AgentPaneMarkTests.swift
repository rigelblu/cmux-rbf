import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf #cm-126.3: the Agent Pane's rules, over plain values.

@Suite("AgentPaneMark")
struct AgentPaneMarkTests {

    private let terminalA = UUID()
    private let terminalB = UUID()

    private func agentPane(_ owner: UUID, id: UUID = UUID()) -> AgentPaneMark.Candidate {
        .init(panelID: id, owner: owner, kind: .agentPane)
    }

    @Test("isAgentPaneKind needs an owner and the Agent Pane kind: a Figma pane with an owner and no kind is not one")
    func isAgentPaneKindNeedsOwnerAndKind() {
        #expect(AgentPaneMark.isAgentPaneKind(owner: terminalA, kind: .agentPane))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: terminalA, kind: nil))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: nil, kind: .agentPane))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: nil, kind: nil))
    }

    @Test("panes(ownedBy:) keeps only that terminal's panes, in the order given")
    func panesOwnedByKeepsTheOwnersOnly() {
        let first = agentPane(terminalA)
        let others = agentPane(terminalB)
        let figmaPane = AgentPaneMark.Candidate(panelID: UUID(), owner: terminalA, kind: nil)
        let second = agentPane(terminalA)
        let plain = AgentPaneMark.Candidate(panelID: UUID(), owner: nil, kind: nil)
        let found = AgentPaneMark.panes(ownedBy: terminalA, among: [first, others, figmaPane, second, plain])
        #expect(found == [first.panelID, second.panelID])
    }

    @Test("placement with no Agent Pane opens one")
    func placementWithNoneOpens() {
        #expect(AgentPaneMark.placement(panes: []) == .open)
    }

    @Test("placement with one Agent Pane steers it, with no others")
    func placementWithOneNavigates() {
        let id = UUID()
        #expect(AgentPaneMark.placement(panes: [id]) == .navigate(id, others: 0))
    }

    @Test("placement with two panes steers the first and counts the second")
    func placementWithTwoNavigatesTheFirst() {
        let first = UUID()
        let second = UUID()
        #expect(AgentPaneMark.placement(panes: [first, second]) == .navigate(first, others: 1))
    }

    @Test("picture is the mark for an Agent Pane, whatever the page's own icon")
    func pictureIsTheMarkForAnAgentPane() {
        let own = Data([1, 2, 3])
        #expect(AgentPaneMark.picture(isAgentPaneKind: true, own: own) == AgentPaneMark.shippedPicture)
        #expect(AgentPaneMark.picture(isAgentPaneKind: true, own: nil) == AgentPaneMark.shippedPicture)
    }

    @Test("picture is the page's own icon for a plain pane")
    func pictureIsTheOwnIconOtherwise() {
        let own = Data([1, 2, 3])
        #expect(AgentPaneMark.picture(isAgentPaneKind: false, own: own) == own)
        #expect(AgentPaneMark.picture(isAgentPaneKind: false, own: nil) == nil)
    }

    @Test("an Agent Pane title is its localized fixed caption")
    func agentPaneTitleIsFixed() {
        #expect(AgentPaneMark.title(isAgentPaneKind: true, own: "Page title") == "Agent Pane")
    }

    @Test("a plain browser pane keeps its own title")
    func plainPaneTitleIsUnchanged() {
        #expect(AgentPaneMark.title(isAgentPaneKind: false, own: "Page title") == "Page title")
    }

    @Test("the mark is a 32 by 32 pixel PNG that draws something")
    func theMarkIsA32PixelPNG() throws {
        let data = AgentPaneMark.shippedPicture
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 32)
        #expect(bitmap.pixelsHigh == 32)
        var opaque = 0
        for x in 0..<32 {
            for y in 0..<32 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
            }
        }
        #expect(opaque > 20, "only \(opaque) opaque pixels")
    }

    @Test("paneHoldsAgentPane is true only for a pane with an Agent Pane among its tabs")
    func paneHoldsAgentPane() {
        let plain = AgentPaneMark.Candidate(panelID: UUID(), owner: nil, kind: nil)
        let figmaPane = AgentPaneMark.Candidate(panelID: UUID(), owner: terminalA, kind: nil)
        #expect(AgentPaneMark.paneHoldsAgentPane([plain, agentPane(terminalA)]))
        #expect(!AgentPaneMark.paneHoldsAgentPane([plain, figmaPane]))
        #expect(!AgentPaneMark.paneHoldsAgentPane([]))
    }

    @Test("the app's own page check refuses other schemes and Figma addresses, and takes file, https and http")
    func appRefusesSchemesAndFigma() throws {
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "javascript:alert(1)"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "data:text/html,x"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "about:blank"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "https://www.figma.com/design/K/x?node-id=1-2"))) == .figmaAddress)
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.previewPageURL) == .badScheme)
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.wrapperFileURL()) == .figmaAddress)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "https://example.org/"))) == nil)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "http://localhost:8000/p.html"))) == nil)
        #expect(AgentPaneMark.refusal(for: URL(fileURLWithPath: "/tmp/p1.html")) == nil)
    }
}
