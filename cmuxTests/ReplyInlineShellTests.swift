import AppKit
import Combine
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.1` Scenario 6's wiring, proven by driving a real `GhosttyNSView` in
/// a real window with the world outside it faked (`ReplyInlineEnvironment`).
///
/// Each test fails when its piece of wiring is cut: the release check not
/// calling the decision, the mount, the monitor's install and removal, the
/// sidebar observer, Reply's target. The pure decisions themselves are
/// `ReplyInlineTriggerTests`, `ReplyInlineDismissTests` and friends.
@MainActor
@Suite("Reply inline shell", .serialized)
struct ReplyInlineShellTests {
    /// The fake world: selection facts in, recorded effects out.
    @MainActor
    final class World: ReplyInlinePasteTarget {
        var settingEnabled = true
        var hasSelection = true
        var isAgentPane = true
        var selection = ReplyInlineSelectionGeometry(
            text: "hello world", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 20
        )
        var columns = 80
        var pollInterval: TimeInterval = 3600
        var sidebarShowingReply = false

        var monitorsInstalled = 0
        var monitorsRemoved = 0
        var monitorHandler: ((NSEvent) -> NSEvent?)?
        var sidebarObservers = 0
        var sidebarCancelled = 0
        var sidebarOnChange: (() -> Void)?
        var pastes: [(events: [TextBoxSubmit.DispatchEvent], panel: UUID)] = []
        var logs: [String] = []

        nonisolated func send(_ events: [TextBoxSubmit.DispatchEvent], toPanel id: UUID) -> Bool {
            MainActor.assumeIsolated {
                pastes.append((events, id))
                return true
            }
        }

        var environment: ReplyInlineEnvironment {
            ReplyInlineEnvironment(
                settingEnabled: { self.settingEnabled },
                isAgentPane: { _ in self.isAgentPane },
                hasSelection: { _ in self.hasSelection },
                readSelection: { _, _ in self.hasSelection ? self.selection : nil },
                grid: { _ in ReplyInlineGridGeometry(columns: self.columns, cellHeight: 17, paddingTop: 4) },
                sidebarShowingReply: { _ in self.sidebarShowingReply },
                observeSidebar: { _, onChange in
                    self.sidebarObservers += 1
                    self.sidebarOnChange = onChange
                    return AnyCancellable { self.sidebarCancelled += 1 }
                },
                installMonitor: { handler in
                    self.monitorsInstalled += 1
                    self.monitorHandler = handler
                    return NSObject()
                },
                removeMonitor: { _ in
                    self.monitorsRemoved += 1
                    self.monitorHandler = nil
                },
                pasteTarget: self,
                log: { self.logs.append($0) },
                selectionPollInterval: self.pollInterval
            )
        }
    }

    struct Rig {
        let surface: TerminalSurface
        let hosted: GhosttySurfaceScrollView
        let window: NSWindow
        let terminal: GhosttyNSView
        let world: World
        var controller: ReplyInlineToolbarController { hosted.replyInline }
    }

    private func makeRig(width: CGFloat = 360, height: CGFloat = 240, installWorld: Bool = true) async throws -> Rig {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            ioMode: .manualMirror,
            manualInputHandler: { _ in }
        )
        await Self.startAndWaitForLiveSurface(surface)
        let native = try #require(surface.surface)
        // Claude Code captures the mouse; that is also what lets a press reach the
        // terminal in a pane that wasn't focused (the policy forwards a captured click).
        let sequence = "\u{1B}[?1000h\u{1B}[?1006h"
        sequence.withCString { ghostty_surface_process_output(native, $0, UInt(sequence.utf8.count)) }
        let hosted = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let content = try #require(window.contentView)
        hosted.frame = content.bounds
        hosted.autoresizingMask = [.width, .height]
        content.addSubview(hosted)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        hosted.layoutSubtreeIfNeeded()

        let world = World()
        // The fake world goes on the pane, so a release can show before the controller exists.
        hosted.replyInlineEnvironmentForNewController = world.environment
        // A test of the very first statement of the hook must not make the pane's controller.
        if installWorld { hosted.replyInline.environment = world.environment }
        return Rig(surface: surface, hosted: hosted, window: window, terminal: hosted.surfaceView, world: world)
    }

    private static func startAndWaitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previous = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previous }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previous?()
                continuation.yield()
                continuation.finish()
            }
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        for await _ in readiness { break }
    }

    private func finish(_ rig: Rig) {
        rig.hosted.replyInline.hide(reason: .pane)
        // Detach the pane before freeing its surface, so no layer display
        // reaches a renderer that is already gone.
        rig.hosted.removeFromSuperview()
        rig.window.orderOut(nil)
        rig.surface.releaseSurfaceForTesting()
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, window: NSWindow,
        flags: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1.0
        ) else { preconditionFailure("Failed to create \(type) event") }
        return event
    }

    private func key(window: NSWindow) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ) else { preconditionFailure("Failed to create key event") }
        return event
    }

    /// Press and release in the terminal, the way a double-click selects a word.
    private func release(
        _ rig: Rig, clickCount: Int = 2, press: NSEvent.ModifierFlags = [], release: NSEvent.ModifierFlags = []
    ) {
        let point = rig.terminal.convert(NSPoint(x: 24, y: 24), to: nil)
        rig.terminal.mouseDown(with: mouse(.leftMouseDown, at: point, window: rig.window, flags: press, clickCount: clickCount))
        rig.terminal.mouseUp(with: mouse(.leftMouseUp, at: point, window: rig.window, flags: release, clickCount: clickCount))
    }

    private func click(_ toolbar: ReplyInlineToolbarView, window: NSWindow) {
        let point = toolbar.convert(NSPoint(x: toolbar.bounds.midX, y: toolbar.bounds.midY), to: nil)
        toolbar.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
        toolbar.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
    }

    // MARK: the release check calls the decision, and the mount follows

    @Test("A double-click in an agent pane mounts the toolbar inside the pane")
    func releaseMountsTheToolbar() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let shown = try #require(rig.controller.shown)
        #expect(shown.view.superview === rig.hosted)
        #expect(rig.hosted.bounds.contains(shown.view.frame), "toolbar must be held inside the pane")
        #expect(rig.world.logs.contains { $0.hasPrefix("shown ") })
    }

    @Test("The passage carries the pane's own id and the text taken at release")
    func passageCarriesThePaneAndTheText() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let shown = try #require(rig.controller.shown)
        #expect(shown.passage.sourcePanelID == rig.surface.id)
        #expect(shown.passage.rawText == "hello world")
        #expect(shown.passage.wrapColumns == 80)
    }

    @Test("A ⇧-click that extends the selection mounts it; the press's flags reach the decision")
    func shiftClickMounts() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig, clickCount: 1, press: [.shift], release: [.shift])
        #expect(rig.controller.shown != nil)
    }

    @Test("A drag mounts it")
    func dragMounts() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        let down = rig.terminal.convert(NSPoint(x: 24, y: 24), to: nil)
        let up = rig.terminal.convert(NSPoint(x: 120, y: 24), to: nil)
        rig.terminal.mouseDown(with: mouse(.leftMouseDown, at: down, window: rig.window, flags: [.shift]))
        rig.terminal.mouseDragged(with: mouse(.leftMouseDragged, at: up, window: rig.window, flags: [.shift]))
        rig.terminal.mouseUp(with: mouse(.leftMouseUp, at: up, window: rig.window, flags: [.shift]))
        #expect(rig.controller.shown != nil)
    }

    @Test("A drag with no ⇧ mounts it: the drag itself reaches the decision")
    func plainDragMounts() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        let down = rig.terminal.convert(NSPoint(x: 24, y: 24), to: nil)
        let up = rig.terminal.convert(NSPoint(x: 120, y: 24), to: nil)
        rig.terminal.mouseDown(with: mouse(.leftMouseDown, at: down, window: rig.window))
        rig.terminal.mouseDragged(with: mouse(.leftMouseDragged, at: up, window: rig.window))
        rig.terminal.mouseUp(with: mouse(.leftMouseUp, at: up, window: rig.window))
        #expect(rig.controller.shown != nil)
    }

    @Test("A single click that changes nothing mounts nothing")
    func plainClickMountsNothing() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig, clickCount: 1)
        #expect(rig.controller.shown == nil)
        #expect(rig.world.monitorsInstalled == 0)
    }

    @Test("A release with ⌘⇧ held is #cm-89's: no toolbar")
    func commandShiftMountsNothing() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig, press: [.command, .shift], release: [.command, .shift])
        #expect(rig.controller.shown == nil)
    }

    @Test("A release with ⌘⇧ held does not even make the pane's Reply controller")
    func commandShiftTouchesNothing() async throws {
        let rig = try await makeRig(installWorld: false)
        defer { finish(rig) }
        #expect(rig.hosted.replyInlineIfCreated == nil)
        release(rig, press: [.command, .shift], release: [.command, .shift])
        #expect(rig.hosted.replyInlineIfCreated == nil)
    }

    @Test("A plain release that shows makes the pane's controller (the control for the test above)")
    func releaseThatShowsMakesTheController() async throws {
        let rig = try await makeRig(installWorld: false)
        defer { finish(rig) }
        release(rig)
        #expect(rig.controller.shown != nil)
        #expect(rig.hosted.replyInlineIfCreated != nil)
    }

    @Test("A plain release with no selection makes no controller")
    func plainReleaseWithoutSelectionMakesNoController() async throws {
        let rig = try await makeRig(installWorld: false)
        defer { finish(rig) }
        rig.world.hasSelection = false
        release(rig)
        #expect(rig.hosted.replyInlineIfCreated == nil)
    }

    @Test("A pane with no live agent mounts nothing, and says why")
    func notAnAgentPane() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.isAgentPane = false
        release(rig)
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains { $0.hasPrefix("ignore reason=notAgentPane") })
    }

    @Test("No selection mounts nothing")
    func noSelection() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.hasSelection = false
        release(rig)
        #expect(rig.controller.shown == nil)
    }

    @Test("A pane narrower than the toolbar mounts nothing")
    func narrowPane() async throws {
        let rig = try await makeRig(width: 50)
        defer { finish(rig) }
        release(rig)
        #expect(rig.controller.shown == nil)
        #expect(rig.world.monitorsInstalled == 0)
    }

    @Test("A second selection replaces the first: one toolbar, one monitor")
    func secondSelectionReplaces() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        release(rig)
        let toolbars = rig.hosted.subviews.compactMap { $0 as? ReplyInlineToolbarView }
        #expect(toolbars.count == 1)
        #expect(rig.world.monitorsInstalled - rig.world.monitorsRemoved == 1)
        // The controller's own defence: a show over a showing toolbar hides it as `.newSelection`.
        #expect(rig.world.logs.contains("dismissed reason=newSelection"))
    }

    // MARK: Reply

    @Test("Reply pastes the quote and a newline into the source pane, once, and goes")
    func replyPastesIntoTheSourcePane() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.count == 1)
        #expect(rig.world.pastes.first?.panel == rig.surface.id)
        #expect(rig.world.pastes.first?.events == [.pasteText("> \"hello world\"\n")])
        #expect(rig.controller.shown == nil)
        #expect(toolbar.superview == nil)
        #expect(rig.world.logs.contains { $0.hasPrefix("reply ") && $0.contains("source=terminal") && $0.contains("fence=0") })
    }

    // Reads the system pasteboard: another app copying during the run can fail this test.
    @Test("Reply never writes the pasteboard (Q8)")
    func replyLeavesThePasteboardAlone() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        let before = NSPasteboard.general.changeCount
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.count == 1, "the click did reply")
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test("If the agent has gone by the click, Reply pastes nothing and says why")
    func agentGoneAtClick() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        rig.world.isAgentPane = false
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.isEmpty)
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=agentGone"))
        #expect(!rig.world.logs.contains { $0.hasPrefix("reply ") })
    }

    @Test("Reply sends the text taken at release, whatever the screen shows by the click")
    func replyUsesTheTextFromRelease() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "something the agent just wrote", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 20
        )
        let toolbar = try #require(rig.controller.shown?.view)
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.first?.events == [.pasteText("> \"hello world\"\n")])
    }

    @Test("A passage with line breaks is cleaned, then fenced")
    func replyFencesLineBreaks() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "⏺ first line\n\n  second paragraph", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 40
        )
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.first?.events == [.pasteText("```\nfirst line\n\nsecond paragraph\n```\n")])
        #expect(rig.world.logs.contains { $0.hasPrefix("reply ") && $0.contains("fence=1") })
    }

    @Test("A selection that is only a marker glyph pastes nothing")
    func markerOnlyPastesNothing() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "⏺ ", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 2
        )
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        click(toolbar, window: rig.window)
        #expect(rig.world.pastes.isEmpty)
        #expect(rig.controller.shown == nil)
    }

    @Test("Releasing the press outside the button cancels it")
    func pressReleasedOutsideCancels() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        let inside = toolbar.convert(NSPoint(x: toolbar.bounds.midX, y: toolbar.bounds.midY), to: nil)
        let outside = toolbar.convert(NSPoint(x: -40, y: -40), to: nil)
        toolbar.mouseDown(with: mouse(.leftMouseDown, at: inside, window: rig.window))
        toolbar.mouseDragged(with: mouse(.leftMouseDragged, at: outside, window: rig.window))
        toolbar.mouseUp(with: mouse(.leftMouseUp, at: outside, window: rig.window))
        #expect(rig.world.pastes.isEmpty)
        #expect(rig.controller.shown != nil)
    }

    @Test("A press that ends outside the button, with no drag in between, does not reply")
    func pressEndingOutsideWithoutDragCancels() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        let inside = toolbar.convert(NSPoint(x: toolbar.bounds.midX, y: toolbar.bounds.midY), to: nil)
        let outside = toolbar.convert(NSPoint(x: -40, y: -40), to: nil)
        toolbar.mouseDown(with: mouse(.leftMouseDown, at: inside, window: rig.window))
        toolbar.mouseUp(with: mouse(.leftMouseUp, at: outside, window: rig.window))
        #expect(rig.world.pastes.isEmpty)
        #expect(rig.controller.shown != nil)
    }

    @Test("Clicking Reply leaves the keyboard with the terminal")
    func keyboardStaysInTheTerminal() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        _ = rig.window.makeFirstResponder(rig.terminal)
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        #expect(!toolbar.acceptsFirstResponder)
        click(toolbar, window: rig.window)
        #expect(rig.window.firstResponder === rig.terminal)
    }

    @Test("The toolbar is a labelled button")
    func toolbarIsALabelledButton() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        #expect(toolbar.accessibilityRole() == .button)
        #expect(!(toolbar.accessibilityLabel() ?? "").isEmpty)
        #expect(toolbar.accessibilityTitle() == "Reply")
    }

    // MARK: dismissal: the monitor, the observers, and "only while shown"

    @Test("The monitor, the sidebar observer and the compare exist only while shown")
    func watchingOnlyWhileShown() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        #expect(!rig.controller.isWatching)
        #expect(rig.world.monitorsInstalled == 0)
        release(rig)
        #expect(rig.controller.isWatching)
        #expect(rig.world.monitorsInstalled == 1 && rig.world.sidebarObservers == 1)
        let timer = try #require(rig.controller.selectionTimerForTesting)
        #expect(timer.isValid)
        rig.controller.hide(reason: .click)
        #expect(!rig.controller.isWatching)
        #expect(rig.world.monitorsRemoved == 1 && rig.world.sidebarCancelled == 1)
        #expect(!timer.isValid, "the selection compare's timer must not outlive the toolbar")
    }

    @Test("A key anywhere in the window hides it, and the key still goes on")
    func keyHides() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let event = key(window: rig.window)
        let handler = try #require(rig.world.monitorHandler)
        #expect(handler(event) === event)
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=key"))
        #expect(rig.world.monitorsRemoved == 1)
    }

    @Test("A click elsewhere hides it; a click on the toolbar does not")
    func clickElsewhereHides() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let toolbar = try #require(rig.controller.shown?.view)
        let handler = try #require(rig.world.monitorHandler)

        let onToolbar = toolbar.convert(NSPoint(x: toolbar.bounds.midX, y: toolbar.bounds.midY), to: nil)
        _ = handler(mouse(.leftMouseDown, at: onToolbar, window: rig.window))
        #expect(rig.controller.shown != nil, "a press on the toolbar is Reply, not a dismissal")

        let elsewhere = NSPoint(x: 5, y: 5)
        _ = handler(mouse(.leftMouseDown, at: elsewhere, window: rig.window))
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=click"))
    }

    @Test("Another window's events do not hide it")
    func otherWindowEventsAreIgnored() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        let other = NSWindow(
            contentRect: NSRect(x: 400, y: 400, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        other.orderFront(nil)
        defer { other.orderOut(nil) }
        release(rig)
        let handler = try #require(rig.world.monitorHandler)
        _ = handler(key(window: other))
        _ = handler(mouse(.leftMouseDown, at: NSPoint(x: 5, y: 5), window: other))
        #expect(rig.controller.shown != nil)
    }

    @Test("A sidebar change that flips the label's destination hides it; one that doesn't, leaves it")
    func sidebarObserver() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let onChange = try #require(rig.world.sidebarOnChange)
        onChange()
        #expect(rig.controller.shown != nil, "width or focus changes leave the answer as it was")
        rig.world.sidebarShowingReply = true
        onChange()
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=sidebar"))
        #expect(rig.world.pastes.isEmpty)
    }

    @Test("Once hidden, a sidebar change or a new selection text records nothing more")
    func nothingHappensAfterHide() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        let onChange = try #require(rig.world.sidebarOnChange)
        rig.controller.hide(reason: .click)
        let logsAfterHide = rig.world.logs
        rig.world.sidebarShowingReply = true
        onChange()
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "different words", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 20
        )
        rig.controller.checkSelection()
        #expect(rig.world.logs == logsAfterHide, "no second dismiss, no check, no log line")
        #expect(rig.controller.shown == nil)
    }

    @Test("A toolbar shown while the sidebar already shows Reply stays until that answer flips")
    func sidebarAlreadyShowingReply() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.sidebarShowingReply = true
        release(rig)
        let onChange = try #require(rig.world.sidebarOnChange)
        onChange()
        #expect(rig.controller.shown != nil, "the label was read with the sidebar on Reply; nothing changed")
        rig.world.sidebarShowingReply = false
        onChange()
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=sidebar"))
    }

    @Test("The selection compare hides it when the selection is cleared, moved or changed")
    func selectionCompare() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }

        release(rig)
        rig.controller.checkSelection()
        #expect(rig.controller.shown != nil, "an unchanged selection keeps it")

        rig.world.hasSelection = false
        rig.controller.checkSelection()
        #expect(rig.controller.shown == nil, "cleared")

        rig.world.hasSelection = true
        release(rig)
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "hello world", topLeftX: 100, baselineY: 100, offsetStart: 500, distanceToBottomRight: 20
        )
        rig.controller.checkSelection()
        #expect(rig.controller.shown == nil, "moved")
        #expect(rig.world.logs.filter { $0 == "dismissed reason=selectionChanged" }.count == 2)
    }

    @Test("The text changing under a selection that stays on the same cells hides it (Q4, measured 2026-11-09)")
    func sameCellsNewTextHides() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "the agent redrew this row", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 20
        )
        rig.controller.checkSelection()
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=selectionChanged"))
    }

    @Test("The compare runs on its own timer while shown, with no event to prompt it")
    func timerRunsTheCompare() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        rig.world.pollInterval = 0.02
        rig.hosted.replyInline.environment = rig.world.environment
        release(rig)
        rig.world.selection = ReplyInlineSelectionGeometry(
            text: "the agent redrew this row", topLeftX: 100, baselineY: 100, offsetStart: 400, distanceToBottomRight: 20
        )
        // A bounded wait: up to 100 × 20 ms for the timer to hide the toolbar.
        var waits = 0
        while rig.controller.shown != nil, waits < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waits += 1
        }
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=selectionChanged"))
    }

    @Test("The pane leaving its window hides it")
    func paneLeavingHides() async throws {
        let rig = try await makeRig()
        defer { finish(rig) }
        release(rig)
        #expect(rig.controller.shown != nil)
        rig.hosted.removeFromSuperview()
        #expect(rig.controller.shown == nil)
        #expect(rig.world.logs.contains("dismissed reason=pane"))
        #expect(rig.world.monitorsRemoved == 1)
    }
}
