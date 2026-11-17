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

    // cmux-rbf: changed on purpose (#cm-126.13). Was `theMarkIsA32PixelPNG`, for `.3`'s SF Symbol `eyeglasses` at 32 px.
    // The mark is now Tom's window, a 64 px PNG: 64 so it stays sharp when the tab font scales the 14 pt slot.
    @Test("the mark is the window, a 64 by 64 pixel PNG")
    func theMarkIsTheWindowAt64Pixels() throws {
        let bitmap = try #require(NSBitmapImageRep(data: AgentPaneMark.shippedPicture))
        // Require, don't expect: the pixel reads below assume 64 × 64 and would run past a smaller picture's buffer.
        try #require(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
        // Read bytes, not `colorAt`, which converts colour spaces. Check the layout `rgba` assumes before reading.
        try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4 && !bitmap.isPlanar
            && !bitmap.bitmapFormat.contains(.alphaFirst))
        let bytes = try #require(bitmap.bitmapData)
        func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let p = bytes + y * bitmap.bytesPerRow + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
        }
        #expect(rgba(0, 0).a == 0, "the corner outside the frame is clear")
        let sash = rgba(9, 20), cross = rgba(32, 32)
        #expect(sash.r > 240 && sash.g > 240 && sash.b > 240 && sash.a == 255, "the frame is white: \(sash)")
        #expect(cross.r > 240 && cross.g > 240 && cross.b > 240 && cross.a == 255, "the cross is white: \(cross)")
        let sky = rgba(20, 21), sunset = rgba(44, 43)
        // 40 above both: `.3`'s grey mark (122, 122, 135) leans blue by 13, so a bare `>` passed on it.
        #expect(sky.b > sky.r + 40 && sky.b > sky.g + 40, "the top-left pane is the blue-purple sky: \(sky)")
        #expect(sunset.r > 200 && sunset.g < 120 && sunset.b < 100, "the bottom-right pane is red-orange: \(sunset)")
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
