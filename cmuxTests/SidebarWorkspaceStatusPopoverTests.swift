import AppKit
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Test fixture providing Tom's 14 custom statuses in file order.
enum TomStatusesFixture {
    static let ids = [
        "dogfood", "done", "review", "paused", "stuck",
        "doing-primary", "doing-secondary", "working-background", "doing-external",
        "snooze", "next", "upcoming", "parked", "todo"
    ]

    static let entries: [WorkspaceStatusEntry] = [
        WorkspaceStatusEntry(id: "dogfood", name: "Dogfood", extends: .review),
        WorkspaceStatusEntry(id: "done", name: "Done"),
        WorkspaceStatusEntry(id: "review", name: "Review"),
        WorkspaceStatusEntry(id: "paused", name: "Paused", extends: .needsAttention),
        WorkspaceStatusEntry(id: "stuck", name: "Stuck", extends: .needsAttention),
        WorkspaceStatusEntry(id: "doing-primary", name: "Doing (Primary)", extends: .working),
        WorkspaceStatusEntry(id: "doing-secondary", name: "Doing (Secondary)", extends: .working),
        WorkspaceStatusEntry(id: "working-background", name: "Working (Background)", extends: .working),
        WorkspaceStatusEntry(id: "doing-external", name: "Doing (External)", extends: .working),
        WorkspaceStatusEntry(id: "snooze", name: "Snooze", extends: .needsAttention),
        WorkspaceStatusEntry(id: "next", name: "Next", extends: .todo),
        WorkspaceStatusEntry(id: "upcoming", name: "Upcoming", extends: .todo),
        WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo),
        WorkspaceStatusEntry(id: "todo", name: "Todo")
    ]

    static let list = WorkspaceStatusList(entries: entries, source: .file)
}

@MainActor
@Suite("SidebarWorkspaceStatusPopoverTests", .serialized)
struct SidebarWorkspaceStatusPopoverTests {
    private func resetTestState() {
        SidebarWorkspaceStatusPopover.highlightedLaneForTesting = nil
        SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting = false
        SidebarWorkspaceStatusPopover.rowFramesForTesting = [:]
        SidebarRowSwiftUIPopoverPresenter.screenVisibleFrameOverrideForTesting = nil
        TodoPopoverHostTestProbe.screenVisibleFrameOverrideForTesting = nil
        PopoverPointerTracker.seedLocationProvider = { NSEvent.mouseLocation }
        TodoPopoverHostTestProbe.lastCoordinator = nil
    }

    private final class KeyableTestWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private func makeOffscreenWindow(size: NSSize = NSSize(width: 400, height: 800)) -> NSWindow {
        let window = KeyableTestWindow(
            contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView {
            return sv
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func sendMouseMoved(
        to winPoint: NSPoint,
        tracker: NSView,
        window: NSWindow
    ) {
        let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: winPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        (tracker as? PopoverPointerTracker.TrackerView)?.mouseMoved(with: event)
    }

    private func sendClick(
        at winPoint: NSPoint,
        window: NSWindow
    ) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: winPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        window.sendEvent(down)
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: winPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
        )!
        window.sendEvent(up)
    }

    private func sendKeyDown(
        characters: String,
        keyCode: UInt16,
        window: NSWindow
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        window.sendEvent(event)
    }

    private func pump(duration: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    private func findTrackerView(in view: NSView) -> PopoverPointerTracker.TrackerView? {
        if let tracker = view as? PopoverPointerTracker.TrackerView {
            return tracker
        }
        for subview in view.subviews {
            if let found = findTrackerView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func makeWorkspaceModel(
        resolution: WorkspaceStatusResolution = .detected(.todo),
        inferred: WorkspaceTaskStatus = .todo,
        activeOverride: WorkspaceTaskStatus? = nil
    ) -> SidebarWorkspaceStatusPopoverModel {
        let picker = WorkspaceStatusPicker().rows(
            resolution: resolution,
            inferred: inferred,
            isHidden: false,
            list: TomStatusesFixture.list
        )
        return SidebarWorkspaceStatusPopoverModel(
            inferred: inferred,
            activeOverride: activeOverride,
            picker: picker,
            colorHexes: [:]
        )
    }

    private func makeGroupModel(
        activeOverride: WorkspaceTaskStatus? = nil
    ) -> SidebarWorkspaceStatusPopoverModel {
        let groupLanes = [
            WorkspaceTodoStatusLane(
                status: nil,
                title: WorkspaceStatusPresentation.noneTitle,
                isSelected: activeOverride == nil,
                action: .hide,
                isNone: true
            )
        ] + TomStatusesFixture.entries.map { entry in
            let title: String = {
                switch entry.label {
                case .named(let text): return text
                case .cmux: return entry.id
                }
            }()
            return WorkspaceTodoStatusLane(
                status: entry.behavesAs,
                title: title,
                isSelected: activeOverride?.rawValue == entry.id,
                action: .status(id: entry.id)
            )
        }
        return SidebarWorkspaceStatusPopoverModel(
            inferred: .todo,
            activeOverride: activeOverride,
            picker: WorkspaceStatusPickerState(rows: []),
            colorHexes: [:],
            lanesOverride: groupLanes
        )
    }

    // MARK: - 1. Pure function tests (availableScreenHeight)

    @Test func availableScreenHeightRules() throws {
        resetTestState()
        let screenVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorRect = NSRect(x: 100, y: 200, width: 24, height: 24)

        // 1. .maxX / .minX edge: available height is screen visible height minus margin (900 - 40 = 860)
        let hMaxX = SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
            anchorRect: anchorRect,
            screenVisibleFrame: screenVisibleFrame,
            preferredEdge: .maxX,
            margin: 40
        )
        #expect(hMaxX == 860)

        let hMinX = SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
            anchorRect: anchorRect,
            screenVisibleFrame: screenVisibleFrame,
            preferredEdge: .minX,
            margin: 40
        )
        #expect(hMinX == 860)

        // 2. .maxY edge: space above anchor (screenVisibleFrame.maxY - anchorRect.maxY = 900 - 224 = 676)
        // vs space below anchor (anchorRect.minY - screenVisibleFrame.minY = 200 - 0 = 200).
        // Larger space is above (676), less margin 40 = 636.
        let hMaxY = SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
            anchorRect: anchorRect,
            screenVisibleFrame: screenVisibleFrame,
            preferredEdge: .maxY,
            margin: 40
        )
        #expect(hMaxY == 636)

        // 3. .minY edge: when anchor is near screen top (y = 800)
        let topAnchorRect = NSRect(x: 100, y: 800, width: 24, height: 24)
        // Space above is 900 - 824 = 76. Space below is 800 - 0 = 800.
        // Larger space is below (800), less margin 40 = 760.
        let hMinY = SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
            anchorRect: topAnchorRect,
            screenVisibleFrame: screenVisibleFrame,
            preferredEdge: .minY,
            margin: 40
        )
        #expect(hMinY == 760)

        // 4. Floor calculation when available space is small (100 - 40 = 60)
        let tinyScreen = NSRect(x: 0, y: 0, width: 800, height: 210)
        let hFloored = SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
            anchorRect: NSRect(x: 100, y: 100, width: 24, height: 24),
            screenVisibleFrame: tinyScreen,
            preferredEdge: .maxY,
            margin: 40
        )
        #expect(hFloored == 60)
    }

    // MARK: - 2. Measured Heights for 6 configurations

    @Test func measuredHeightsForLanes() throws {
        resetTestState()
        // 1. 16 lanes without footnote
        let model16 = makeWorkspaceModel(resolution: .detected(.todo), inferred: .todo, activeOverride: nil)
        let view16 = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model16,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h16 = ceil(view16.fittingSize.height)

        // 2. 16 lanes with footnote (activeOverride != nil)
        let model16f = makeWorkspaceModel(resolution: .detected(.todo), inferred: .todo, activeOverride: .working)
        let view16f = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model16f,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h16f = ceil(view16f.fittingSize.height)

        // 3. 17 lanes with greyed row without footnote
        let entry17 = WorkspaceStatusEntry(id: "external-status", name: "External", extends: .working)
        let list17 = WorkspaceStatusList(entries: TomStatusesFixture.entries + [entry17], source: .file)
        let picker17 = WorkspaceStatusPicker().rows(
            resolution: .ownNotListed(id: "unlisted-status", detected: .todo),
            inferred: .todo,
            isHidden: false,
            list: list17
        )
        let model17 = SidebarWorkspaceStatusPopoverModel(
            inferred: .todo,
            activeOverride: nil,
            picker: picker17,
            colorHexes: [:]
        )
        let view17 = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model17,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h17 = ceil(view17.fittingSize.height)

        // 4. 17 lanes with greyed row and footnote
        let model17f = SidebarWorkspaceStatusPopoverModel(
            inferred: .todo,
            activeOverride: .working,
            picker: picker17,
            colorHexes: [:]
        )
        let view17f = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model17f,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h17f = ceil(view17f.fittingSize.height)

        // 5. Group 15 lanes without footnote
        let model15g = makeGroupModel(activeOverride: nil)
        let view15g = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model15g,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h15g = ceil(view15g.fittingSize.height)

        // 6. Group 15 lanes with footnote
        let model15gf = makeGroupModel(activeOverride: .working)
        let view15gf = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model15gf,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        let h15gf = ceil(view15gf.fittingSize.height)

        // Print measured heights into test log
        print("statusPopover.measuredHeights: 16lanes=\(h16) 16lanes+footnote=\(h16f) 17lanes=\(h17) 17lanes+footnote=\(h17f) group15=\(h15g) group15+footnote=\(h15gf)")

        // Invariants: heights must be positive and non-zero
        #expect(h16 > 400)
        #expect(h16f > h16)
        #expect(h17 > h16)
        #expect(h17f > h17)
        #expect(h15g > 350)
        #expect(h15gf > h15g)
    }

    // MARK: - 3. Grown height and ViewThatFits ScrollView branch (Scenario 97 & Change 3)

    @Test func grownHeightAndViewThatFitsScrollViewBranch() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 400, height: 800))
        defer { window.close() }

        let model = makeWorkspaceModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        )

        // Case A: Unconstrained height (room permits)
        let hostingViewA = NSHostingView(rootView: popoverView)
        hostingViewA.frame = NSRect(x: 0, y: 0, width: 250, height: 600)
        window.contentView = hostingViewA
        hostingViewA.layoutSubtreeIfNeeded()
        pump(duration: 0.05)

        #expect(SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting == false)

        // Case B: Clamped height shorter than fitting height (no room boundary, e.g. 250 pt)
        let clampedContainer = popoverView.frame(width: 250, height: 250)
        let hostingViewB = NSHostingView(rootView: clampedContainer)
        hostingViewB.frame = NSRect(x: 0, y: 0, width: 250, height: 250)
        window.contentView = hostingViewB
        hostingViewB.layoutSubtreeIfNeeded()
        pump(duration: 0.05)

        #expect(SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting == true)

        // Injected pointer on lowest visible lane highlights it
        let tracker = try #require(findTrackerView(in: hostingViewB))
        let dogfoodFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: dogfoodFrame.midX, y: dogfoodFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: window)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // MARK: - 4. Pointer sweeps: 16-lane workspace and 15-lane group (Scenarios 95 & 98)

    @Test func sweepWorkspace16LanesInjectedPointer() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 400, height: 800))
        defer { window.close() }

        let model = makeWorkspaceModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: popoverView)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let tracker = try #require(findTrackerView(in: hostingView))

        // Sweep center y for each of the 16 lanes starting from dogfood (not initial lane auto)
        let expectedLanes = [
            "dogfood", "done", "review", "paused", "stuck",
            "doing-primary", "doing-secondary", "working-background", "doing-external",
            "snooze", "next", "upcoming", "parked", "todo", "none", "auto"
        ]

        for expectedId in expectedLanes {
            let frame = try #require(
                SidebarWorkspaceStatusPopover.rowFramesForTesting[expectedId],
                "Missing row frame for lane \(expectedId)"
            )
            let winPoint = tracker.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            sendMouseMoved(to: winPoint, tracker: tracker, window: window)
            pump(duration: 0.02)
            let highlighted = SidebarWorkspaceStatusPopover.highlightedLaneForTesting
            #expect(highlighted == expectedId, "Expected lane \(expectedId) at y=\(frame.midY), got \(String(describing: highlighted))")
        }
    }

    @Test func sweepGroup15LanesInjectedPointer() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 400, height: 800))
        defer { window.close() }

        let model = makeGroupModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: popoverView)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let tracker = try #require(findTrackerView(in: hostingView))

        // Start from dogfood (not initial lane none)
        let expectedLanes = [
            "dogfood", "done", "review", "paused", "stuck",
            "doing-primary", "doing-secondary", "working-background", "doing-external",
            "snooze", "next", "upcoming", "parked", "todo", "none"
        ]

        for expectedId in expectedLanes {
            let frame = try #require(
                SidebarWorkspaceStatusPopover.rowFramesForTesting[expectedId],
                "Missing group row frame for lane \(expectedId)"
            )
            let winPoint = tracker.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            sendMouseMoved(to: winPoint, tracker: tracker, window: window)
            pump(duration: 0.02)
            let highlighted = SidebarWorkspaceStatusPopover.highlightedLaneForTesting
            #expect(highlighted == expectedId, "Expected group lane \(expectedId) at y=\(frame.midY), got \(String(describing: highlighted))")
        }
    }

    // MARK: - 5. Resting pointer at open & dynamic update 17 -> 16 (Scenario 96 & Change 4)

    @Test func restingPointerAtOpenAndDynamicUpdate17To16() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 250, height: 450))
        defer { window.close() }

        // Seed location from window frame plus known offset (independent oracle:
        // window.frame.maxY - 50 places the pointer 50 pt below the top of the window,
        // which lands in row 2: dogfood)
        let seededLocation = NSPoint(x: window.frame.minX + 50, y: window.frame.maxY - 50)
        PopoverPointerTracker.seedLocationProvider = { seededLocation }
        defer { PopoverPointerTracker.seedLocationProvider = { NSEvent.mouseLocation } }

        // 17 lanes with greyed Working row
        let workingEntry = WorkspaceStatusEntry(id: "working", name: "Working")
        let model17 = makeWorkspaceModel(
            resolution: .cmuxInEffect(workingEntry, offered: false),
            inferred: .todo,
            activeOverride: nil
        )

        let hostingView = NSHostingView(rootView: SidebarWorkspaceStatusPopover(
            model: model17,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        ))
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        // Case 1: Resting pointer at open highlights dogfood before any move event
        #expect(
            SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood",
            "Resting pointer at open must highlight dogfood"
        )

        let activeTracker = try #require(findTrackerView(in: hostingView))
        // Position resting pointer at the held row's frame in 17 lanes using real mouseMoved
        let heldFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting[WorkspaceStatusPickerRow.heldRowID])
        let winPoint = activeTracker.convert(NSPoint(x: heldFrame.midX, y: heldFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: activeTracker, window: window)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")

        // Now dynamically update model to 16 lanes where "none" shifts into that position
        let model16 = makeWorkspaceModel(resolution: .detected(.todo), inferred: .todo, activeOverride: nil)
        hostingView.rootView = SidebarWorkspaceStatusPopover(
            model: model16,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        )
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        // Case 2: Frame change re-evaluates resting pointer to "none"
        #expect(
            SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "none",
            "Dynamic 17 -> 16 update must re-evaluate resting pointer to none"
        )
    }

    // MARK: - 6. Keyboard navigation & press moves highlight (Scenario 99 & Change 5)

    @Test func keyboardNavigationAndPressMovesHighlight() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 300, height: 700))
        defer { window.close() }

        var selectedAction: WorkspaceStatusPickAction?
        var didClose = false
        let model = makeWorkspaceModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { action in selectedAction = action },
            onSelectNone: { selectedAction = .hide },
            onClose: { didClose = true }
        )
        let hostingView = NSHostingView(rootView: popoverView)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        // Initial highlight is on auto (index 0)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "auto")

        // (a) Arrow down moves highlight: 0 (auto) -> 1 (dogfood)
        sendKeyDown(characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, window: window)
        pump(duration: 0.02)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")

        // (a) Arrow up moves highlight back: 1 (dogfood) -> 0 (auto)
        sendKeyDown(characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126, window: window)
        pump(duration: 0.02)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "auto")

        // (c) First-letter jump: typing "u" jumps to upcoming
        sendKeyDown(characters: "u", keyCode: 32, window: window)
        pump(duration: 0.02)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "upcoming")

        // (d) Arrow up moves highlight away to next
        sendKeyDown(characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126, window: window)
        pump(duration: 0.02)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "next")

        // Click on upcoming moves highlight back
        let upcomingFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["upcoming"])
        let clickPoint = NSPoint(x: 120, y: window.contentView!.bounds.height - upcomingFrame.midY)
        sendClick(at: clickPoint, window: window)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "upcoming")
        #expect(selectedAction == .status(id: "upcoming"))
        #expect(didClose == true)

        // (b) Return key applies highlighted lane and closes popover
        selectedAction = nil
        didClose = false
        let window2 = makeOffscreenWindow(size: NSSize(width: 300, height: 700))
        defer { window2.close() }
        let popoverView2 = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { action in selectedAction = action },
            onSelectNone: { selectedAction = .hide },
            onClose: { didClose = true }
        )
        let hostingView2 = NSHostingView(rootView: popoverView2)
        window2.contentView = hostingView2
        window2.makeKeyAndOrderFront(nil)
        hostingView2.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        // Jump to upcoming and press Return
        sendKeyDown(characters: "u", keyCode: 32, window: window2)
        pump(duration: 0.02)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "upcoming")

        sendKeyDown(characters: "\r", keyCode: 36, window: window2)
        pump(duration: 0.05)
        #expect(selectedAction == .status(id: "upcoming"))
        #expect(didClose == true)
    }

    // MARK: - Click in a row's empty middle
    @Test func clickInRowEmptyMiddleAppliesLane() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 300, height: 700))
        defer { window.close() }

        var selectedAction: WorkspaceStatusPickAction?
        var didClose = false
        let model = makeWorkspaceModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { action in selectedAction = action },
            onSelectNone: { selectedAction = .hide },
            onClose: { didClose = true }
        )
        let hostingView = NSHostingView(rootView: popoverView)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let dogfoodFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        // Click at x = 120 in the gap between title (x ≈ 40) and checkmark (x ≈ 185)
        let clickPoint = NSPoint(x: 120, y: window.contentView!.bounds.height - dogfoodFrame.midY)
        sendClick(at: clickPoint, window: window)
        pump(duration: 0.05)

        #expect(selectedAction == .status(id: "dogfood"), "Click in empty middle must apply the lane")
        #expect(didClose == true, "Click in empty middle must close popover")
    }

    // MARK: - 7. Five Opener Tests (Scenario 98 & Change 6)

    // Opener 1: AppKit row glyph (SidebarWorkspaceRowTableCellView)
    @Test func opener1AppKitRowGlyphPresentsUncapped() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer { window.close() }

        let workspace = Workspace()
        workspace.setOwnStatus(try #require(TomStatusesFixture.list.entry(id: "upcoming")), list: TomStatusesFixture.list)

        let suite = "Opener1Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false,
            todoControlsEnabled: true,
            statusList: TomStatusesFixture.list,
            statusColorHexes: [:]
        ).makeSnapshot()

        let rowModel = SidebarWorkspaceRowModel(
            workspaceId: workspace.id, index: 0, snapshot: snapshot, settings: settings,
            isActive: false, isMultiSelected: false, hasUserCustomTitle: false, canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1, unreadCount: 0, latestNotificationText: nil,
            showsAgentActivity: false, rowSpacing: 0, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false, isGrouped: false,
            isColorSectionMember: false, isFirstRow: true, shortcutHintText: nil, showsShortcutHints: false,
            colorSchemeIsDark: true, contrastBackgroundHex: "#202020",
            globalFontMagnificationPercent: 100, isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0, isChecklistPopoverPresented: false, editingChecklistItemId: nil,
            todoControlsEnabled: true, isMetadataExpanded: false, isMarkdownExpanded: false
        )

        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 50, y: 100, width: 320, height: 40))
        cell.configurePresentation(model: rowModel)
        window.contentView?.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        pump(duration: 0.05)

        // Toggle popover open
        cell.toggleStatusPopoverForTesting()
        pump(duration: 0.08)

        #expect(cell.isStatusPopoverShownForTesting)
        let presenter = cell.statusPopoverPresenterForTesting
        let contentSize = try #require(presenter.contentSizeForTesting)

        // Content height must be greater than 400 (uncapped fitting height)
        #expect(contentSize.height > 400)

        // Injected pointer on dogfood highlights it
        let popover = try #require(presenter.popoverForTesting)
        let popoverWindow = try #require(popover.contentViewController?.view.window)
        let tracker = try #require(findTrackerView(in: popover.contentViewController!.view))
        let targetFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: popoverWindow)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // Opener 2: AppKit group header (SidebarWorkspaceGroupStatusPopoverHost)
    @Test func opener2AppKitGroupHeaderPresentsUncapped() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer { window.close() }

        let host = SidebarWorkspaceGroupStatusPopoverHost()
        host.install(in: window.contentView!)
        host.button.frame = NSRect(x: 50, y: 200, width: 24, height: 24)

        let rows = [
            SidebarWorkspaceGroupStatusMenu.Row(
                action: .hide,
                title: WorkspaceStatusPresentation.noneTitle,
                isSelected: false,
                glyph: nil
            )
        ] + TomStatusesFixture.entries.map { entry in
            let title: String = {
                switch entry.label {
                case .named(let text): return text
                case .cmux: return entry.id
                }
            }()
            return SidebarWorkspaceGroupStatusMenu.Row(
                action: .status(id: entry.id),
                title: title,
                isSelected: entry.id == "upcoming",
                glyph: nil
            )
        } + [
            // 16th row so fitting height > 400
            SidebarWorkspaceGroupStatusMenu.Row(
                action: .status(id: "extra-lane"),
                title: "Extra Lane",
                isSelected: false,
                glyph: nil
            )
        ]
        let menu = SidebarWorkspaceGroupStatusMenu(rows: rows)

        host.configure(menu: menu, showsGlyph: true, name: "Upcoming") { _ in }
        pump(duration: 0.05)

        // Toggle open
        host.toggleForTesting()
        pump(duration: 0.08)

        let presenter = host.presenterForTesting
        #expect(presenter.isShown)
        let contentSize = try #require(presenter.contentSizeForTesting)

        // Fitting height of 16 lanes is > 400 pt (uncapped)
        #expect(contentSize.height > 400)
        #expect(presenter.maxHeight == SidebarWorkspaceStatusPopover.uncappedMaxHeight)

        // Injected pointer highlights lane
        let popover = try #require(presenter.popoverForTesting)
        let popoverWindow = try #require(popover.contentViewController?.view.window)
        let tracker = try #require(findTrackerView(in: popover.contentViewController!.view))
        let targetFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: popoverWindow)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // Opener 3: Todo pane header host (SidebarWorkspaceTodoPopoverHost with .maxY)
    @Test func opener3TodoPaneHeaderHostPresentsUncapped() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer { window.close() }

        var isPresented = true
        let model = makeWorkspaceModel()
        let hostView = NSHostingView(
            rootView: SidebarWorkspaceTodoPopoverHost(
                isPresented: Binding(get: { isPresented }, set: { isPresented = $0 }),
                model: model,
                minWidth: 200,
                maxHeight: WorkspaceTodoPanelView.statusPopoverMaxHeight,
                preferredEdge: .maxY
            ) { m, close in
                SidebarWorkspaceStatusPopover(
                    model: m,
                    onSelectLane: { _ in },
                    onSelectNone: {},
                    onClose: close
                )
            }
        )
        hostView.frame = NSRect(x: 50, y: 200, width: 300, height: 40)
        window.contentView?.addSubview(hostView)
        hostView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let coordinator = try #require(TodoPopoverHostTestProbe.lastCoordinator)
        let contentSize = try #require(coordinator.contentSizeForTesting)

        // Height is greater than 400 (uncapped)
        #expect(contentSize.height > 400)
        #expect(coordinator.maxHeight == SidebarWorkspaceStatusPopover.uncappedMaxHeight)

        // Injected pointer highlights lane
        let popover = try #require(coordinator.popoverForTesting)
        let popoverWindow = try #require(popover.contentViewController?.view.window)
        let tracker = try #require(findTrackerView(in: popover.contentViewController!.view))
        let targetFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: popoverWindow)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // Opener 4: SwiftUI group glyph host (SidebarWorkspaceGroupStatusGlyphButton)
    @Test func opener4SwiftUIGroupGlyphHostPresentsUncapped() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer { window.close() }

        let rows = [
            SidebarWorkspaceGroupStatusMenu.Row(
                action: .hide,
                title: WorkspaceStatusPresentation.noneTitle,
                isSelected: false,
                glyph: nil
            )
        ] + TomStatusesFixture.entries.map { entry in
            let title: String = {
                switch entry.label {
                case .named(let text): return text
                case .cmux: return entry.id
                }
            }()
            return SidebarWorkspaceGroupStatusMenu.Row(
                action: .status(id: entry.id),
                title: title,
                isSelected: entry.id == "upcoming",
                glyph: nil
            )
        } + [
            SidebarWorkspaceGroupStatusMenu.Row(
                action: .status(id: "extra-lane"),
                title: "Extra Lane",
                isSelected: false,
                glyph: nil
            )
        ]
        let menu = SidebarWorkspaceGroupStatusMenu(rows: rows)
        let glyph = SidebarWorkspaceGroupStatusGlyph(status: .working, name: "Doing", glyph: nil, colorHex: nil)
        let band = SidebarGroupHeaderBandPalette(
            tintHex: nil,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            renderedAppearance: .darkAqua
        )

        let button = SidebarWorkspaceGroupStatusGlyphButton(
            glyph: glyph,
            menu: menu,
            fontScale: 1.0,
            colorScheme: .dark,
            band: band,
            apply: { _ in },
            isPresentedForTesting: true
        )
        let hostView = NSHostingView(rootView: button)
        hostView.frame = NSRect(x: 50, y: 200, width: 300, height: 40)
        window.contentView?.addSubview(hostView)
        hostView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let coordinator = try #require(TodoPopoverHostTestProbe.lastCoordinator)
        let contentSize = try #require(coordinator.contentSizeForTesting)

        #expect(contentSize.height > 400)
        #expect(coordinator.maxHeight == SidebarWorkspaceStatusPopover.uncappedMaxHeight)

        let popover = try #require(coordinator.popoverForTesting)
        let popoverWindow = try #require(popover.contentViewController?.view.window)
        let tracker = try #require(findTrackerView(in: popover.contentViewController!.view))
        let targetFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: popoverWindow)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // Opener 5: SwiftUI row glyph host (SidebarWorkspaceManualStatusIndicatorMenu)
    @Test func opener5SwiftUIRowGlyphHostPresentsUncapped() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer { window.close() }

        let workspace = Workspace()
        workspace.setOwnStatus(try #require(TomStatusesFixture.list.entry(id: "upcoming")), list: TomStatusesFixture.list)

        let suite = "Opener5Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false,
            todoControlsEnabled: true,
            statusList: TomStatusesFixture.list,
            statusColorHexes: [:]
        ).makeSnapshot()

        let menuModel = try #require(snapshot.statusMenuModel(controlsEnabled: true))

        let menuView = SidebarWorkspaceManualStatusIndicatorMenu(
            status: .todo,
            model: menuModel,
            workspaceId: workspace.id,
            applyTodoStatus: { _, _ in },
            hideTodoStatus: { _ in },
            usesMonochrome: false,
            monochromeColor: .gray,
            neutralColor: .gray,
            fontScale: 1.0,
            contrastBackground: nil,
            drawnAlpha: 1.0,
            isPresentedForTesting: true
        )
        let hostView = NSHostingView(rootView: menuView)
        hostView.frame = NSRect(x: 50, y: 200, width: 300, height: 40)
        window.contentView?.addSubview(hostView)
        hostView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let coordinator = try #require(TodoPopoverHostTestProbe.lastCoordinator)
        let contentSize = try #require(coordinator.contentSizeForTesting)

        #expect(contentSize.height > 400)
        #expect(coordinator.maxHeight == SidebarWorkspaceStatusPopover.uncappedMaxHeight)

        let popover = try #require(coordinator.popoverForTesting)
        let popoverWindow = try #require(popover.contentViewController?.view.window)
        let tracker = try #require(findTrackerView(in: popover.contentViewController!.view))
        let targetFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["dogfood"])
        let winPoint = tracker.convert(NSPoint(x: targetFrame.midX, y: targetFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: popoverWindow)
        pump(duration: 0.05)
        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "dogfood")
    }

    // MARK: - 8. Screen Clamp & ScrollTo Tests (Changes 1 & 3)

    @Test func screenClampInRowPresenter() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer {
            window.close()
            SidebarRowSwiftUIPopoverPresenter.screenVisibleFrameOverrideForTesting = nil
        }

        // Clamp screen height to 300 pt (margin 20 pt -> available <= 280 pt)
        SidebarRowSwiftUIPopoverPresenter.screenVisibleFrameOverrideForTesting = NSRect(x: 0, y: 0, width: 800, height: 300)

        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 50, y: 100, width: 320, height: 40))
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(TomStatusesFixture.list.entry(id: "upcoming")), list: TomStatusesFixture.list)
        let suite = "ClampRowTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false,
            todoControlsEnabled: true,
            statusList: TomStatusesFixture.list,
            statusColorHexes: [:]
        ).makeSnapshot()
        let rowModel = SidebarWorkspaceRowModel(
            workspaceId: workspace.id, index: 0, snapshot: snapshot, settings: settings,
            isActive: false, isMultiSelected: false, hasUserCustomTitle: false, canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1, unreadCount: 0, latestNotificationText: nil,
            showsAgentActivity: false, rowSpacing: 0, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false, isGrouped: false,
            isColorSectionMember: false, isFirstRow: true, shortcutHintText: nil, showsShortcutHints: false,
            colorSchemeIsDark: true, contrastBackgroundHex: "#202020",
            globalFontMagnificationPercent: 100, isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0, isChecklistPopoverPresented: false, editingChecklistItemId: nil,
            todoControlsEnabled: true, isMetadataExpanded: false, isMarkdownExpanded: false
        )
        cell.configurePresentation(model: rowModel)
        window.contentView?.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        pump(duration: 0.05)

        cell.toggleStatusPopoverForTesting()
        pump(duration: 0.08)

        let presenter = cell.statusPopoverPresenterForTesting
        let contentSize = try #require(presenter.contentSizeForTesting)
        #expect(contentSize.height <= 280, "Content height \(contentSize.height) must be clamped to available height <= 280")
        #expect(SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting == true)
    }

    @Test func screenClampInTodoPresenter() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 500, height: 900))
        defer {
            window.close()
            TodoPopoverHostTestProbe.screenVisibleFrameOverrideForTesting = nil
        }

        // Clamp screen height to 300 pt
        TodoPopoverHostTestProbe.screenVisibleFrameOverrideForTesting = NSRect(x: 0, y: 0, width: 800, height: 300)

        var isPresented = true
        let model = makeWorkspaceModel()
        let hostView = NSHostingView(
            rootView: SidebarWorkspaceTodoPopoverHost(
                isPresented: Binding(get: { isPresented }, set: { isPresented = $0 }),
                model: model,
                minWidth: 200,
                maxHeight: WorkspaceTodoPanelView.statusPopoverMaxHeight,
                preferredEdge: .maxY
            ) { m, close in
                SidebarWorkspaceStatusPopover(
                    model: m,
                    onSelectLane: { _ in },
                    onSelectNone: {},
                    onClose: close
                )
            }
        )
        hostView.frame = NSRect(x: 50, y: 200, width: 300, height: 40)
        window.contentView?.addSubview(hostView)
        hostView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        let coordinator = try #require(TodoPopoverHostTestProbe.lastCoordinator)
        let contentSize = try #require(coordinator.contentSizeForTesting)
        #expect(contentSize.height <= 280, "Content height \(contentSize.height) must be clamped to available height <= 280")
        #expect(SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting == true)
    }

    @Test func scrollToInScrollViewBranch() throws {
        resetTestState()
        let window = makeOffscreenWindow(size: NSSize(width: 300, height: 250))
        defer { window.close() }

        let model = makeWorkspaceModel()
        let popoverView = SidebarWorkspaceStatusPopover(
            model: model,
            onSelectLane: { _ in },
            onSelectNone: {},
            onClose: {}
        )
        let clampedContainer = popoverView.frame(width: 250, height: 250)
        let hostingView = NSHostingView(rootView: clampedContainer)
        hostingView.frame = NSRect(x: 0, y: 0, width: 250, height: 250)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        pump(duration: 0.08)

        #expect(SidebarWorkspaceStatusPopover.isScrollViewActiveForTesting == true)

        let scrollView = try #require(findScrollView(in: hostingView))
        #expect(scrollView.documentVisibleRect.origin.y == 0, "Initial scroll offset must be 0")

        // 1. Pointer move to a lane must NOT scroll
        let tracker = try #require(findTrackerView(in: hostingView))
        let upcomingFrame = try #require(SidebarWorkspaceStatusPopover.rowFramesForTesting["upcoming"])
        let winPoint = tracker.convert(NSPoint(x: upcomingFrame.midX, y: upcomingFrame.midY), to: nil)
        sendMouseMoved(to: winPoint, tracker: tracker, window: window)
        pump(duration: 0.05)

        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "upcoming")
        #expect(scrollView.documentVisibleRect.origin.y == 0, "Pointer move must not scroll")

        // 2. Key move DOES scroll
        sendKeyDown(characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, window: window)
        pump(duration: 0.05)

        #expect(SidebarWorkspaceStatusPopover.highlightedLaneForTesting == "parked")
        #expect(scrollView.documentVisibleRect.origin.y > 0, "Key move must scroll")
    }
}
