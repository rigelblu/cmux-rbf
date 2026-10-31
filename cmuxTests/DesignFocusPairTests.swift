// cmux-rbf #cm-73.2a
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DesignFocusPair")
struct DesignFocusPairTests {

    private func makeTab(
        id: UUID = UUID(),
        paneId: UUID,
        isTerminal: Bool,
        isFigma: Bool,
        stableSurfaceId: UUID? = nil,
        owner: UUID? = nil
    ) -> DesignFocusPair.Tab {
        DesignFocusPair.Tab(
            id: id,
            paneId: paneId,
            isTerminal: isTerminal,
            isFigma: isFigma,
            stableSurfaceId: stableSurfaceId,
            ownerTerminalSurfaceId: owner
        )
    }

    private func makePane(
        id: UUID = UUID(),
        frame: CGRect,
        tabs: [DesignFocusPair.Tab],
        selectedTabId: UUID? = nil
    ) -> DesignFocusPair.Pane {
        DesignFocusPair.Pane(
            id: id,
            frame: frame,
            tabs: tabs,
            selectedTabId: selectedTabId ?? tabs.first?.id
        )
    }

    @Test("Refusal: canvas layout returns canvasLayout refusal")
    func canvasLayoutRefusal() {
        let paneId = UUID()
        let tTab = makeTab(paneId: paneId, isTerminal: true, isFigma: false)
        let fTab = makeTab(paneId: paneId, isTerminal: false, isFigma: true)
        let pane = makePane(id: paneId, frame: CGRect(x: 0, y: 0, width: 800, height: 600), tabs: [tTab, fTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: true,
            focusedPaneId: paneId,
            panes: [pane]
        )
        #expect(result == .failure(.canvasLayout))
    }

    @Test("Refusal: no Figma tab in workspace")
    func noFigmaTabRefusal() {
        let paneId = UUID()
        let tTab = makeTab(paneId: paneId, isTerminal: true, isFigma: false)
        let pane = makePane(id: paneId, frame: CGRect(x: 0, y: 0, width: 800, height: 600), tabs: [tTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: paneId,
            panes: [pane]
        )
        #expect(result == .failure(.noFigmaTab))
    }

    @Test("Refusal: no terminal tab in workspace")
    func noTerminalTabRefusal() {
        let paneId = UUID()
        let fTab = makeTab(paneId: paneId, isTerminal: false, isFigma: true)
        let pane = makePane(id: paneId, frame: CGRect(x: 0, y: 0, width: 800, height: 600), tabs: [fTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: paneId,
            panes: [pane]
        )
        #expect(result == .failure(.noTerminalTab))
    }

    // cmux-rbf #cm-73.2a
    @Test("Orientation entry: 1518x2822 (portrait window) -> below")
    func orientationEntry_1518x2822_below() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 1518, height: 2822)) == .below)
    }

    @Test("Orientation entry: 1272x917 (MacBook full screen) -> beside")
    func orientationEntry_1272x917_beside() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 1272, height: 917)) == .beside)
    }

    @Test("Orientation entry: 1000x1000 (exactly 1.0) -> beside")
    func orientationEntry_1000x1000_beside() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 1000, height: 1000)) == .beside)
    }

    @Test("Orientation entry: 990x1000 -> below")
    func orientationEntry_990x1000_below() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 990, height: 1000)) == .below)
    }

    @Test("Orientation entry: 4880x2850 (5K full) -> beside")
    func orientationEntry_4880x2850_beside() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 4880, height: 2850)) == .beside)
    }

    @Test("Orientation band: from below, 1.05 (1050x1000) stays below")
    func orientationBand_fromBelow_1050x1000_below() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 1050, height: 1000), current: .below) == .below)
    }

    @Test("Orientation band: from below, 1.10 (1100x1000) goes beside")
    func orientationBand_fromBelow_1100x1000_beside() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 1100, height: 1000), current: .below) == .beside)
    }

    @Test("Orientation band: from beside, 0.95 (950x1000) stays beside")
    func orientationBand_fromBeside_950x1000_beside() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 950, height: 1000), current: .beside) == .beside)
    }

    @Test("Orientation band: from beside, 0.89 (890x1000) goes below")
    func orientationBand_fromBeside_890x1000_below() {
        #expect(DesignFocusPair.orientation(areaSize: CGSize(width: 890, height: 1000), current: .beside) == .below)
    }

    @Test("Pick: focused Figma pane wins over other Figma panes")
    func focusedFigmaPaneWins() {
        let figmaPane1Id = UUID()
        let figmaPane2Id = UUID()
        let terminalPaneId = UUID()

        let fTab1 = makeTab(paneId: figmaPane1Id, isTerminal: false, isFigma: true)
        let fTab2 = makeTab(paneId: figmaPane2Id, isTerminal: false, isFigma: true)
        let tTab = makeTab(paneId: terminalPaneId, isTerminal: true, isFigma: false)

        let fPane1 = makePane(id: figmaPane1Id, frame: CGRect(x: 0, y: 0, width: 400, height: 600), tabs: [fTab1])
        let fPane2 = makePane(id: figmaPane2Id, frame: CGRect(x: 400, y: 0, width: 400, height: 600), tabs: [fTab2])
        let tPane = makePane(id: terminalPaneId, frame: CGRect(x: 800, y: 0, width: 400, height: 600), tabs: [tTab])

        // Focus is on figmaPane2
        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: figmaPane2Id,
            panes: [fPane1, fPane2, tPane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.figmaTab.id == fTab2.id)
        #expect(selection.terminalTab.id == tTab.id)
    }

    @Test("Pick: Figma pane nearest the focused terminal wins")
    func nearestFigmaPaneToFocusedTerminalWins() {
        let termPaneId = UUID()
        let nearFigmaId = UUID()
        let farFigmaId = UUID()

        let tTab = makeTab(paneId: termPaneId, isTerminal: true, isFigma: false)
        let nearFTab = makeTab(paneId: nearFigmaId, isTerminal: false, isFigma: true)
        let farFTab = makeTab(paneId: farFigmaId, isTerminal: false, isFigma: true)

        let tPane = makePane(id: termPaneId, frame: CGRect(x: 0, y: 0, width: 300, height: 600), tabs: [tTab])
        let nearFPane = makePane(id: nearFigmaId, frame: CGRect(x: 350, y: 0, width: 300, height: 600), tabs: [nearFTab])
        let farFPane = makePane(id: farFigmaId, frame: CGRect(x: 1000, y: 0, width: 300, height: 600), tabs: [farFTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: termPaneId,
            panes: [farFPane, nearFPane, tPane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.figmaTab.id == nearFTab.id)
        #expect(selection.terminalTab.id == tTab.id)
    }

    @Test("Pick: terminal nearest the chosen Figma side wins when focus is in Figma")
    func terminalNearestFigmaSideWins() {
        let figmaPaneId = UUID()
        let nearTermId = UUID()
        let farTermId = UUID()

        let fTab = makeTab(paneId: figmaPaneId, isTerminal: false, isFigma: true)
        let nearTTab = makeTab(paneId: nearTermId, isTerminal: true, isFigma: false)
        let farTTab = makeTab(paneId: farTermId, isTerminal: true, isFigma: false)

        let fPane = makePane(id: figmaPaneId, frame: CGRect(x: 0, y: 0, width: 300, height: 600), tabs: [fTab])
        let nearTPane = makePane(id: nearTermId, frame: CGRect(x: 320, y: 0, width: 300, height: 600), tabs: [nearTTab])
        let farTPane = makePane(id: farTermId, frame: CGRect(x: 1200, y: 0, width: 300, height: 600), tabs: [farTTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: figmaPaneId,
            panes: [farTPane, nearTPane, fPane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.figmaTab.id == fTab.id)
        #expect(selection.terminalTab.id == nearTTab.id)
    }

    @Test("Pick: both terminal and Figma tab in the same pane")
    func bothTabsInSamePane() {
        let paneId = UUID()
        let tTab = makeTab(paneId: paneId, isTerminal: true, isFigma: false)
        let fTab = makeTab(paneId: paneId, isTerminal: false, isFigma: true)
        let pane = makePane(id: paneId, frame: CGRect(x: 0, y: 0, width: 800, height: 600), tabs: [tTab, fTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: paneId,
            panes: [pane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.terminalTab.id == tTab.id)
        #expect(selection.figmaTab.id == fTab.id)
        #expect(selection.terminalTab.paneId == selection.figmaTab.paneId)
    }

    @Test("Pick: nearest calculation uses pane frame centres")
    func nearestByFrameCentres() {
        // Pane 1: center (100, 100)
        // Pane 2: center (100, 250), distance to center is 150
        // Pane 3: center (200, 100), distance to center is 100 (closer!)
        let focusId = UUID()
        let closerId = UUID()
        let fartherId = UUID()

        let tTab = makeTab(paneId: focusId, isTerminal: true, isFigma: false)
        let closerFTab = makeTab(paneId: closerId, isTerminal: false, isFigma: true)
        let fartherFTab = makeTab(paneId: fartherId, isTerminal: false, isFigma: true)

        let tPane = makePane(id: focusId, frame: CGRect(x: 50, y: 50, width: 100, height: 100), tabs: [tTab])
        let closerFPane = makePane(id: closerId, frame: CGRect(x: 150, y: 50, width: 100, height: 100), tabs: [closerFTab])
        let fartherFPane = makePane(id: fartherId, frame: CGRect(x: 50, y: 200, width: 100, height: 100), tabs: [fartherFTab])

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: focusId,
            panes: [fartherFPane, closerFPane, tPane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.figmaTab.id == closerFTab.id)
    }

    @Test("Pick: focus on pane holding [Figma (selected), shell] picks the shell in the same pane (distance 0)")
    func figmaSelectedInMixedPanePicksSamePaneShell() {
        let mixedPaneId = UUID()
        let separateTerminalPaneId = UUID()

        let fTab = makeTab(paneId: mixedPaneId, isTerminal: false, isFigma: true)
        let sTab = makeTab(paneId: mixedPaneId, isTerminal: true, isFigma: false)
        let tTab = makeTab(paneId: separateTerminalPaneId, isTerminal: true, isFigma: false)

        let mixedPane = makePane(
            id: mixedPaneId,
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            tabs: [fTab, sTab],
            selectedTabId: fTab.id
        )
        let tPane = makePane(
            id: separateTerminalPaneId,
            frame: CGRect(x: 400, y: 0, width: 400, height: 600),
            tabs: [tTab],
            selectedTabId: tTab.id
        )

        let result = DesignFocusPair.pick(
            isCanvasLayout: false,
            focusedPaneId: mixedPaneId,
            panes: [mixedPane, tPane]
        )

        guard case .success(let selection) = result else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(selection.figmaTab.id == fTab.id)
        #expect(selection.terminalTab.id == sTab.id)
        #expect(selection.terminalTab.paneId == mixedPaneId)
    }

    // MARK: - cm-73.45: the owner, then the terminal Tom was last in (Scenario 273)

    /// Three panes left to right: agent A, free terminal B (the nearest to F), Figma F.
    /// `owner` is what F's tab names; `aBehind` puts A behind another tab in its pane.
    private struct Row {
        let panes: [DesignFocusPair.Pane]
        let a: DesignFocusPair.Tab
        let b: DesignFocusPair.Tab
        let f: DesignFocusPair.Tab
        let aPane: UUID
        let bPane: UUID
        let fPane: UUID
        let aStable: UUID
    }

    private func row(owner: UUID?, aBehind: Bool = false, withTerminals: Bool = true, ownerIsA: Bool = false) -> Row {
        let aPane = UUID(), bPane = UUID(), fPane = UUID()
        let aStable = UUID(), bStable = UUID()
        let a = makeTab(paneId: aPane, isTerminal: true, isFigma: false, stableSurfaceId: aStable)
        let b = makeTab(paneId: bPane, isTerminal: true, isFigma: false, stableSurfaceId: bStable)
        let f = makeTab(paneId: fPane, isTerminal: false, isFigma: true, owner: ownerIsA ? aStable : owner)
        var aTabs = [a]
        var aSelected = a.id
        if aBehind {
            let front = makeTab(paneId: aPane, isTerminal: true, isFigma: false, stableSurfaceId: UUID())
            aTabs = [a, front]
            aSelected = front.id
        }
        let panes = [
            makePane(id: aPane, frame: CGRect(x: 0, y: 0, width: 300, height: 600), tabs: aTabs, selectedTabId: aSelected),
            makePane(id: bPane, frame: CGRect(x: 300, y: 0, width: 300, height: 600), tabs: [b]),
            makePane(id: fPane, frame: CGRect(x: 600, y: 0, width: 300, height: 600), tabs: [f])
        ]
        return Row(panes: panes, a: a, b: b, f: f, aPane: aPane, bPane: bPane, fPane: fPane, aStable: aStable)
    }

    private func picked(
        _ r: Row, focused: UUID, last: UUID? = nil
    ) -> (terminal: UUID, rule: DesignFocusPair.TerminalRule)? {
        guard case .success(let picked) = DesignFocusPair.pickWithRule(
            isCanvasLayout: false, focusedPaneId: focused, panes: r.panes, lastTerminalTabId: last
        ) else { return nil }
        return (picked.selection.terminalTab.id, picked.rule)
    }

    @Test("273 (1) keyboard in F, F owned by A: A's tab, though B is nearer")
    func ownerBeatsNearest() {
        let r = row(owner: nil, ownerIsA: true)
        let result = picked(r, focused: r.fPane)
        #expect(result?.terminal == r.a.id)
        #expect(result?.rule == .owner)
    }

    @Test("273 (2) keyboard in B, F owned by A: B, as today")
    func focusedTerminalBeatsOwner() {
        let r = row(owner: nil, ownerIsA: true)
        let result = picked(r, focused: r.bPane)
        #expect(result?.terminal == r.b.id)
        #expect(result?.rule == .focused)
    }

    @Test("273 (3) F owned by A, A a background tab behind another tab in its pane: A's tab, not that pane's selected tab")
    func ownerInABackgroundTab() {
        let r = row(owner: nil, aBehind: true, ownerIsA: true)
        let result = picked(r, focused: r.fPane)
        #expect(result?.terminal == r.a.id)
        #expect(result?.rule == .owner)
    }

    @Test("273 (4) F's owner matches no tab, last terminal A: A")
    func staleOwnerFallsToLast() {
        let r = row(owner: UUID())
        let result = picked(r, focused: r.fPane, last: r.a.id)
        #expect(result?.terminal == r.a.id)
        #expect(result?.rule == .last)
    }

    @Test("273 (5) no owner, last A, which is not the nearest: A")
    func lastBeatsNearest() {
        let r = row(owner: nil)
        let result = picked(r, focused: r.fPane, last: r.a.id)
        #expect(result?.terminal == r.a.id)
        #expect(result?.rule == .last)
    }

    @Test("273 (6) no owner, no last: B, the nearest, as today")
    func nothingNamedPairsTheNearest() {
        let r = row(owner: nil)
        let result = picked(r, focused: r.fPane)
        #expect(result?.terminal == r.b.id)
        #expect(result?.rule == .nearest)
    }

    @Test("273 (7) owner and last both stale: the nearest")
    func staleOwnerAndLastFallToNearest() {
        let r = row(owner: UUID())
        let result = picked(r, focused: r.fPane, last: UUID())
        #expect(result?.terminal == r.b.id)
        #expect(result?.rule == .nearest)
    }

    @Test("273 (8) A and F in one pane, F owned by A: A")
    func ownerInTheFigmaPanesOwnPane() {
        let shared = UUID(), bPane = UUID()
        let aStable = UUID()
        let a = makeTab(paneId: shared, isTerminal: true, isFigma: false, stableSurfaceId: aStable)
        let f = makeTab(paneId: shared, isTerminal: false, isFigma: true, owner: aStable)
        let b = makeTab(paneId: bPane, isTerminal: true, isFigma: false, stableSurfaceId: UUID())
        let panes = [
            makePane(id: shared, frame: CGRect(x: 0, y: 0, width: 400, height: 600), tabs: [a, f], selectedTabId: f.id),
            makePane(id: bPane, frame: CGRect(x: 400, y: 0, width: 400, height: 600), tabs: [b])
        ]
        guard case .success(let picked) = DesignFocusPair.pickWithRule(
            isCanvasLayout: false, focusedPaneId: shared, panes: panes
        ) else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(picked.selection.terminalTab.id == a.id)
        #expect(picked.selection.terminalTab.paneId == shared)
        #expect(picked.rule == .owner)
    }

    @Test("273 (9) canvas layout, and no terminal, still refuse, owner and last or not")
    func refusalsAreUnchanged() {
        let r = row(owner: nil, ownerIsA: true)
        #expect(DesignFocusPair.pick(isCanvasLayout: true, focusedPaneId: r.fPane, panes: r.panes, lastTerminalTabId: r.a.id)
            == .failure(.canvasLayout))
        let onlyFigma = [r.panes[2]]
        #expect(DesignFocusPair.pick(isCanvasLayout: false, focusedPaneId: r.fPane, panes: onlyFigma, lastTerminalTabId: r.a.id)
            == .failure(.noTerminalTab))
    }

    @Test("a terminal tab that is not a terminal never matches an owner, even with the same stable id")
    func ownerMustBeATerminalTab() {
        let r = row(owner: nil, ownerIsA: true)
        // F's own stable id equal to the owner must not make the Figma tab the terminal side.
        let fPane = r.panes[2]
        let f2 = makeTab(id: r.f.id, paneId: r.fPane, isTerminal: false, isFigma: true, stableSurfaceId: r.aStable, owner: r.aStable)
        let panes = [r.panes[0], r.panes[1], makePane(id: fPane.id, frame: fPane.frame, tabs: [f2])]
        guard case .success(let picked) = DesignFocusPair.pickWithRule(isCanvasLayout: false, focusedPaneId: r.fPane, panes: panes) else {
            Issue.record("Expected successful selection")
            return
        }
        #expect(picked.selection.terminalTab.isTerminal)
        #expect(picked.selection.terminalTab.id == r.a.id)
    }
}
