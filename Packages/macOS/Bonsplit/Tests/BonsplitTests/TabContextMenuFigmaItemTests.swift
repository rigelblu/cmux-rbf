// cmux-rbf #cm-73.15
import AppKit
import Testing
@testable import Bonsplit

@MainActor
@Suite(.serialized)
struct TabContextMenuFigmaItemTests {
    @Test(arguments: [false, true])
    func figmaFollowsBrowserAndDispatches(isBrowser: Bool) throws {
        let target = TabContextMenuActionTarget()
        var selected: TabContextAction?
        target.onContextAction = { selected = $0 }
        let state = TabContextMenuState(
            isPinned: false, isUnread: false, isBrowser: isBrowser,
            isAudioMuted: false, isTerminal: !isBrowser, hasCustomTitle: false,
            canCloseToLeft: true, canCloseToRight: true, canCloseOthers: true,
            canMoveToNewWorkspace: true, canMoveToLeftPane: false,
            canMoveToRightPane: true, forkConversationDefaultAction: .forkConversationRight,
            isZoomed: false, hasSplits: true, shortcuts: [:]
        )
        let menu = TabContextMenuBuilder.makeMenu(
            snapshot: TabContextMenuSnapshot(tabId: UUID(), state: state,
                moveDestinationsProvider: { [] }, forkConversationAvailabilityProvider: { .hidden }),
            target: target
        )
        let browser = try #require(menu.items.firstIndex { ($0.representedObject as? String) == "newBrowserToRight" })
        let figma = try #require(menu.items.firstIndex { ($0.representedObject as? String) == "newFigmaToRight" }, "Figma item missing")
        #expect(figma == browser + 1)
        #expect(menu.items[figma].title == "New Figma Tab to Right")
        #expect(menu.items[figma].submenu == nil)
        #expect(menu.items[figma].isEnabled)
        menu.performActionForItem(at: figma)
        #expect(selected == .newFigmaToRight)
    }
}
