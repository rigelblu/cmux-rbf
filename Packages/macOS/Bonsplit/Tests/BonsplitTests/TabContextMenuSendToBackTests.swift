// cmux-rbf #cm-128.13
import AppKit
import Testing
@testable import Bonsplit

/// The tab context menu's "Send to Back of Unread Queue" (cm-128.13, Scenarios 176 and 177): where the item sits, when it is
/// enabled, what choosing it reports, and that the enabled answer is asked when the menu is built and opened, not when the tab bar
/// renders (step 7, R1: a render-time value goes stale, since nothing in Bonsplit observes the notification store).
///
/// NOT driven by any test, because nothing here constructs `TabBarView`, `SurfaceCaptionView` or the tab strip's `TabItemView`: the two
/// closures in `TabBarView` (`tabItem(for:at:)` and `captionItem(for:)`, each `sendToBackAvailabilityProvider: { controller.isSendToBackAvailable(...) }`)
/// and the forwards in `TabItemView` and `SurfaceCaptionView` that hand it to the snapshot. A dropped forward fails to compile (the snapshot's
/// parameter is required), but `{ false }` in either closure passes every test, and no live check covers the tab-strip closure either: Scenarios 183
/// and 185 right-click a one-tab pane, which is the caption path.
@MainActor
@Suite(.serialized)
struct TabContextMenuSendToBackTests {
    private let itemTitle = "Send to Back of Unread Queue"

    private func state(isUnread: Bool) -> TabContextMenuState {
        TabContextMenuState(
            isPinned: false, isUnread: isUnread, isBrowser: false,
            isAudioMuted: false, isTerminal: true, hasCustomTitle: false,
            canCloseToLeft: true, canCloseToRight: true, canCloseOthers: true,
            canMoveToNewWorkspace: true, canMoveToLeftPane: false,
            canMoveToRightPane: true, forkConversationDefaultAction: .forkConversationRight,
            isZoomed: false, hasSplits: true, shortcuts: [:]
        )
    }

    private func snapshot(isUnread: Bool = false, sendToBack: @escaping () -> Bool) -> TabContextMenuSnapshot {
        TabContextMenuSnapshot(
            tabId: UUID(), state: state(isUnread: isUnread),
            moveDestinationsProvider: { [] },
            forkConversationAvailabilityProvider: { .hidden },
            sendToBackAvailabilityProvider: sendToBack
        )
    }

    private func buildMenu(isUnread: Bool = false, target: TabContextMenuActionTarget = TabContextMenuActionTarget(), sendToBack: @escaping () -> Bool) -> TabContextMenu {
        TabContextMenuBuilder.makeMenu(snapshot: snapshot(isUnread: isUnread, sendToBack: sendToBack), target: target)
    }

    private func sendToBackIndex(in menu: NSMenu) -> Int? {
        menu.items.firstIndex { ($0.representedObject as? String) == "sendToBack" }
    }

    @Test(arguments: [true, false])
    func itemSitsRightAfterTheReadUnreadItem(isUnread: Bool) throws {
        let menu = buildMenu(isUnread: isUnread, sendToBack: { true })
        let neighbour = isUnread ? "Mark Tab as Read" : "Mark Tab as Unread"
        let neighbourIndex = try #require(menu.items.firstIndex { $0.title == neighbour }, "\(neighbour) missing")
        let index = try #require(sendToBackIndex(in: menu), "Send to Back item missing")
        #expect(index == neighbourIndex + 1, "the item must sit right after \(neighbour)")
        #expect(menu.items[index].title == itemTitle)
        #expect(menu.items.filter { ($0.representedObject as? String) == "sendToBack" }.count == 1)
    }

    @Test(arguments: [true, false])
    func itemIsEnabledOnlyWhenTheProviderAllowsIt(allowed: Bool) throws {
        let menu = buildMenu(sendToBack: { allowed })
        let index = try #require(sendToBackIndex(in: menu), "Send to Back item missing")
        #expect(menu.items[index].isEnabled == allowed)
    }

    @Test
    func choosingTheItemReportsSendToBack() throws {
        let target = TabContextMenuActionTarget()
        var selected: [TabContextAction] = []
        target.onContextAction = { selected.append($0) }
        let menu = buildMenu(isUnread: true, target: target, sendToBack: { true })
        let index = try #require(sendToBackIndex(in: menu), "Send to Back item missing")
        menu.performActionForItem(at: index)
        #expect(selected == [.sendToBack])
    }

    // Step 7, R1: the answer is asked when the menu is built (and again as it opens), so a store change between the tab bar's last render
    // and the right-click shows in the menu. A snapshot made earlier must not hold the answer.
    @Test
    func menuAsksTheProviderWhenItIsBuiltNotWhenTheSnapshotIsMade() throws {
        var answer = false
        var asked = 0
        let made = snapshot(sendToBack: { asked += 1; return answer })
        #expect(asked == 0, "making the snapshot (the tab bar's render) asked the provider")

        answer = true // the store changed after the snapshot was made
        let menu = TabContextMenuBuilder.makeMenu(snapshot: made, target: TabContextMenuActionTarget())
        let index = try #require(sendToBackIndex(in: menu), "Send to Back item missing")
        #expect(menu.items[index].isEnabled, "the menu kept an answer from before the store changed")

        answer = false
        let later = TabContextMenuBuilder.makeMenu(snapshot: made, target: TabContextMenuActionTarget())
        let laterIndex = try #require(sendToBackIndex(in: later))
        #expect(!later.items[laterIndex].isEnabled, "the second menu built from the same snapshot kept the first answer")
    }

    @Test
    func openingTheMenuAsksTheProviderAgain() throws {
        var answer = false
        let menu = buildMenu(sendToBack: { answer })
        let index = try #require(sendToBackIndex(in: menu), "Send to Back item missing")
        #expect(!menu.items[index].isEnabled)

        answer = true
        menu.menuNeedsUpdate(menu)
        #expect(menu.items[index].isEnabled, "the menu did not re-ask the provider as it opened")
    }

    @Test
    func controllerAnswersFromItsProviderForTheTabAndPane() throws {
        let controller = BonsplitController(configuration: BonsplitConfiguration(appearance: .default))
        let pane = try #require(controller.internalController.focusedPane)
        let first = try #require(pane.selectedTab)
        let secondId = try #require(controller.createTab(title: "second", inPane: pane.id))
        let firstId = TabID(id: first.id)
        controller.tabContextSendToBackAvailabilityProvider = { tabId, paneId in
            tabId == firstId && paneId == pane.id
        }
        #expect(controller.isSendToBackAvailable(for: firstId, inPane: pane.id), "the provider said yes for this tab and pane")
        #expect(!controller.isSendToBackAvailable(for: secondId, inPane: pane.id), "the provider said no for the other tab")
        controller.tabContextSendToBackAvailabilityProvider = nil
        #expect(!controller.isSendToBackAvailable(for: firstId, inPane: pane.id), "with no provider the item is greyed")
    }
}
