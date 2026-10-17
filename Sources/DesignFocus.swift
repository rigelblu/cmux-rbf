// cmux-rbf #cm-73.2a
import Foundation
import CoreGraphics

/// Pure types and rules for Design Focus (cm-73.2a).
///
/// Holds `DesignFocusPair` (which terminal tab and which Figma tab are shown,
/// the shared-area ratio orientation) and `DesignFocusRouting` (the
/// routing decision table for pages, tabs, splits and moves entering a workspace).
enum DesignFocusPair {

    enum Orientation: Equatable, Sendable {
        case beside
        case below
    }

    enum Refusal: Error, Equatable, Sendable {
        case canvasLayout
        case noFigmaTab
        case noTerminalTab
    }

    struct Tab: Equatable, Sendable {
        let id: UUID
        let paneId: UUID
        let isTerminal: Bool
        let isFigma: Bool

        init(
            id: UUID,
            paneId: UUID,
            isTerminal: Bool,
            isFigma: Bool
        ) {
            self.id = id
            self.paneId = paneId
            self.isTerminal = isTerminal
            self.isFigma = isFigma
        }
    }

    struct Pane: Equatable, Sendable {
        let id: UUID
        let frame: CGRect
        let tabs: [Tab]
        let selectedTabId: UUID?

        init(
            id: UUID,
            frame: CGRect,
            tabs: [Tab],
            selectedTabId: UUID? = nil
        ) {
            self.id = id
            self.frame = frame
            self.tabs = tabs
            self.selectedTabId = selectedTabId
        }
    }

    struct Selection: Equatable, Sendable {
        let terminalTab: Tab
        let figmaTab: Tab

        init(terminalTab: Tab, figmaTab: Tab) {
            self.terminalTab = terminalTab
            self.figmaTab = figmaTab
        }
    }

    typealias PickResult = Result<Selection, Refusal>

    // cmux-rbf #cm-73.2a
    static let entryAspectRatioLine: CGFloat = 1.0
    static let besideSwitchAspectRatio: CGFloat = 1.1
    static let belowSwitchAspectRatio: CGFloat = 0.9
    static let aspectRatioTolerance: CGFloat = 1e-9

    /// Decides whether the pair sits beside each other or stacked below, by the shared area's aspect ratio.
    /// On entry (current == nil), ratio >= 1.0 -> beside, else below.
    /// With current orientation, band prevents jitter: switch to beside at >= 1.1, back to below at < 0.9.
    static func orientation(areaSize: CGSize, current: Orientation? = nil) -> Orientation {
        guard areaSize.height > 0 else {
            return current ?? .below
        }
        let ratio = areaSize.width / areaSize.height
        switch current {
        case nil:
            return ratio >= entryAspectRatioLine ? .beside : .below
        case .below:
            return ratio >= besideSwitchAspectRatio - aspectRatioTolerance ? .beside : .below
        case .beside:
            return ratio < belowSwitchAspectRatio - aspectRatioTolerance ? .below : .beside
        }
    }

    /// Picks the terminal tab and Figma tab to pair, or returns a refusal.
    ///
    /// The focused Figma pane wins; else the Figma pane nearest the focused pane;
    /// the terminal side is the focused terminal, else the terminal nearest the Figma side;
    /// nearest is by pane frame centres; no history.
    static func pick(
        isCanvasLayout: Bool,
        focusedPaneId: UUID?,
        panes: [Pane]
    ) -> PickResult {
        if isCanvasLayout {
            return .failure(.canvasLayout)
        }

        let figmaPanes = panes.filter { pane in
            pane.tabs.contains(where: { $0.isFigma })
        }
        if figmaPanes.isEmpty {
            return .failure(.noFigmaTab)
        }

        let terminalPanes = panes.filter { pane in
            pane.tabs.contains(where: { $0.isTerminal })
        }
        if terminalPanes.isEmpty {
            return .failure(.noTerminalTab)
        }

        func center(of rect: CGRect) -> CGPoint {
            CGPoint(x: rect.midX, y: rect.midY)
        }

        func distanceSquared(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
            let dx = p1.x - p2.x
            let dy = p1.y - p2.y
            return dx * dx + dy * dy
        }

        let focusedPane = panes.first(where: { $0.id == focusedPaneId })

        // Which Figma pane wins?
        // Focused Figma pane wins; else Figma pane nearest the focused pane (or first Figma pane).
        let chosenFigmaPane: Pane
        if let focusedPane, figmaPanes.contains(where: { $0.id == focusedPane.id }) {
            chosenFigmaPane = focusedPane
        } else if let focusedPane {
            let focusCenter = center(of: focusedPane.frame)
            chosenFigmaPane = figmaPanes.min(by: { p1, p2 in
                distanceSquared(from: focusCenter, to: center(of: p1.frame)) <
                distanceSquared(from: focusCenter, to: center(of: p2.frame))
            }) ?? figmaPanes[0]
        } else {
            chosenFigmaPane = figmaPanes[0]
        }

        let chosenFigmaTab: Tab
        if let selectedId = chosenFigmaPane.selectedTabId,
           let selected = chosenFigmaPane.tabs.first(where: { $0.id == selectedId && $0.isFigma }) {
            chosenFigmaTab = selected
        } else {
            chosenFigmaTab = chosenFigmaPane.tabs.first(where: { $0.isFigma })!
        }

        // Which terminal pane wins?
        // Focused terminal pane wins (meaning focused pane's selected tab is a terminal);
        // else terminal pane nearest the Figma side (Figma pane itself has distance 0).
        let isFocusedTerminal: Bool
        if let focusedPane,
           let selectedId = focusedPane.selectedTabId,
           let selectedTab = focusedPane.tabs.first(where: { $0.id == selectedId }),
           selectedTab.isTerminal {
            isFocusedTerminal = true
        } else {
            isFocusedTerminal = false
        }

        let chosenTerminalPane: Pane
        if isFocusedTerminal, let focusedPane {
            chosenTerminalPane = focusedPane
        } else {
            let figmaCenter = center(of: chosenFigmaPane.frame)
            chosenTerminalPane = terminalPanes.min(by: { p1, p2 in
                distanceSquared(from: figmaCenter, to: center(of: p1.frame)) <
                distanceSquared(from: figmaCenter, to: center(of: p2.frame))
            }) ?? terminalPanes[0]
        }

        let chosenTerminalTab: Tab
        if let selectedId = chosenTerminalPane.selectedTabId,
           let selected = chosenTerminalPane.tabs.first(where: { $0.id == selectedId && $0.isTerminal }) {
            chosenTerminalTab = selected
        } else {
            chosenTerminalTab = chosenTerminalPane.tabs.first(where: { $0.isTerminal })!
        }

        return .success(Selection(terminalTab: chosenTerminalTab, figmaTab: chosenFigmaTab))
    }
}

enum DesignFocusRouting {

    enum Target: Equatable, Sendable {
        case newTab
        case newSplit
        case movedIntoPairPane
        case pairTabNavigated
        case hiddenTabNavigated
    }

    enum Asker: Equatable, Sendable {
        case user
        case agent
        case page
    }

    enum Outcome: Equatable, Sendable {
        case intoFigmaSide(selectKeyboard: Bool)
        case externalBrowser
        case behind
        case madeOutOfSight
        case endModeThenAsToday
        case asToday
    }

    /// Pure routing table decision for Design Focus.
    static func decide(
        url: URL?,
        showsAddressBar: Bool = false,
        target: Target,
        asker: Asker,
        wantsFocus: Bool = false,
        modeEnabled: Bool = true,
        wrapper: URL = FigmaPaneURL.wrapperFileURL()
    ) -> Outcome {
        guard modeEnabled else {
            return .asToday
        }

        // Whatever the row, an agent's call that asks for focus ends the mode and shows what it made or moved.
        if wantsFocus && asker == .agent {
            return .endModeThenAsToday
        }

        // Tom's own Move Surface ends the mode
        if asker == .user && target == .movedIntoPairPane {
            return .endModeThenAsToday
        }

        let isFigma = FigmaTabMark.applies(address: url, showsAddressBar: showsAddressBar, wrapper: wrapper)

        if isFigma {
            switch target {
            case .newTab, .newSplit:
                switch asker {
                case .user:
                    return .intoFigmaSide(selectKeyboard: true)
                case .agent:
                    return .intoFigmaSide(selectKeyboard: false)
                case .page:
                    return .endModeThenAsToday
                }
            case .movedIntoPairPane:
                return .behind
            case .pairTabNavigated, .hiddenTabNavigated:
                return .asToday
            }
        }

        let scheme = url?.scheme?.lowercased()
        let isHttp = (scheme == "http" || scheme == "https")

        if isHttp {
            switch target {
            case .newTab, .newSplit:
                switch asker {
                case .user, .agent:
                    return .externalBrowser
                case .page:
                    return .endModeThenAsToday
                }
            case .movedIntoPairPane:
                return .behind
            case .pairTabNavigated:
                return .externalBrowser
            case .hiddenTabNavigated:
                return .asToday
            }
        }

        let isBlank = (url == nil || url?.absoluteString == "about:blank")

        if isBlank {
            switch target {
            case .newTab:
                switch asker {
                case .user, .page:
                    return .endModeThenAsToday
                case .agent:
                    return .behind
                }
            case .newSplit:
                switch asker {
                case .user:
                    return .endModeThenAsToday
                case .agent:
                    return .madeOutOfSight
                case .page:
                    return .endModeThenAsToday
                }
            case .movedIntoPairPane:
                return .behind
            case .pairTabNavigated, .hiddenTabNavigated:
                return .asToday
            }
        }

        // Row 4: cmux pages (cmux-diff-viewer://) and local HTML (file://)
        switch target {
        case .newTab:
            switch asker {
            case .user, .page:
                return .endModeThenAsToday
            case .agent:
                return .behind
            }
        case .newSplit:
            switch asker {
            case .user:
                return .endModeThenAsToday
            case .agent:
                return .madeOutOfSight
            case .page:
                return .endModeThenAsToday
            }
        case .movedIntoPairPane:
            return .behind
        case .pairTabNavigated, .hiddenTabNavigated:
            return .asToday
        }
    }
}
