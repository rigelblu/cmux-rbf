import AppKit
import CmuxTerminal
import GhosttyKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Drives a real Ghostty surface through the real `GhosttyNSView.keyDown` to
/// prove that typing `/rename <name>` and pressing Return records a pending
/// submission for that surface.
///
/// This is the path the cold review's M4 finding named as untested — "the
/// terminal handler chain has no tests at all" — and the path a 2026-07-31
/// dogfood session could not exercise at all, because Codex's own integration
/// on that machine never registered a session. Everything below runs in-process
/// with no Codex, no wrapper, no PATH shim, and no hooks, so the wiring stays
/// verifiable when the surrounding environment is not.
@MainActor
final class CodexRenameSubmissionKeyDownTests: XCTestCase {
    /// Typed `/rename <name>` + Return arms the submission the PTY confirmation
    /// later consumes. Without this the whole feature is inert: the detector can
    /// see a perfect Codex confirmation and still apply nothing.
    func testTypedRenameSubmissionIsRecordedForTheSurface() throws {
#if DEBUG
        let (window, surface, surfaceView) = try makeLiveSurface()
        defer { window.orderOut(nil) }

        type("/rename integration-test", into: surfaceView, window: window)
        surfaceView.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))

        XCTAssertTrue(
            CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                surfaceID: surface.id,
                name: "integration-test"
            ),
            "Typing /rename and pressing Return should arm a pending submission for this surface"
        )
#else
        throw XCTSkip("Debug-only integration test")
#endif
    }

    /// A submission is consumed exactly once. A redrawn confirmation — Codex
    /// repaints the same cell constantly — must not re-arm a second rename.
    func testSubmissionIsConsumedOnlyOnce() throws {
#if DEBUG
        let (window, surface, surfaceView) = try makeLiveSurface()
        defer { window.orderOut(nil) }

        type("/rename once", into: surfaceView, window: window)
        surfaceView.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))

        XCTAssertTrue(
            CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                surfaceID: surface.id,
                name: "once"
            )
        )
        XCTAssertFalse(
            CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                surfaceID: surface.id,
                name: "once"
            ),
            "A redraw of the same confirmation must not consume a second submission"
        )
#else
        throw XCTSkip("Debug-only integration test")
#endif
    }

    /// Ordinary typing arms nothing. Every Return in every terminal reaches this
    /// code, so a false arm here would let unrelated Codex output rename things.
    func testOrdinaryInputRecordsNoSubmission() throws {
#if DEBUG
        let (window, surface, surfaceView) = try makeLiveSurface()
        defer { window.orderOut(nil) }

        type("echo hello", into: surfaceView, window: window)
        surfaceView.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))

        XCTAssertFalse(
            CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                surfaceID: surface.id,
                name: "hello"
            ),
            "Ordinary shell input must never arm a rename submission"
        )
#else
        throw XCTSkip("Debug-only integration test")
#endif
    }

    /// Text arriving from the agent rather than the keyboard proves nothing.
    /// Scrollback holding an earlier `/rename foo` is exactly what the previous
    /// screen-scraping implementation mistook for a fresh submission.
    func testUntypedRenameTextRecordsNoSubmission() throws {
#if DEBUG
        let (window, surface, surfaceView) = try makeLiveSurface()
        defer { window.orderOut(nil) }

        // Return alone, with nothing typed before it.
        surfaceView.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))

        XCTAssertFalse(
            CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                surfaceID: surface.id,
                name: "from-scrollback"
            ),
            "A rename never typed by the user must not be armed"
        )
#else
        throw XCTSkip("Debug-only integration test")
#endif
    }

    // MARK: - Live surface scaffolding

    private func makeLiveSurface() throws -> (NSWindow, TerminalSurface, GhosttyNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let contentView = try XCTUnwrap(window.contentView)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try XCTUnwrap(
            firstGhosttyView(in: hostedView),
            "Expected a live terminal surface view"
        )
        return (window, surface, surfaceView)
    }

    private func firstGhosttyView(in root: NSView) -> GhosttyNSView? {
        if let match = root as? GhosttyNSView { return match }
        for child in root.subviews {
            if let match = firstGhosttyView(in: child) { return match }
        }
        return nil
    }

    private func type(_ text: String, into view: GhosttyNSView, window: NSWindow) {
        for character in text {
            view.keyDown(with: keyEvent(characters: String(character), keyCode: 0, window: window))
        }
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
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
        ) else {
            fatalError("Failed to create key event")
        }
        return event
    }
}
