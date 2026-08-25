import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The input line proves a Codex `/rename` came from the user rather than from
/// rendered output. It must accept exactly what the person typed and refuse
/// everything it cannot reconstruct.
struct TerminalInputLineBufferTests {
    /// The core case: typing `/rename test` and pressing Return submits it.
    @Test func typedRenameSubmitsOnReturn() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == "/rename test")
    }

    /// Submitting consumes the line, so a bare Return afterwards proves nothing.
    /// Without this, one `/rename` could arm every later Return on the surface.
    @Test func submittingClearsTheLine() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)
        _ = buffer.consume(event: Self.key(keyCode: 36), committedText: [])

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == "")
    }

    /// Backspace edits the line rather than invalidating it — correcting a typo
    /// mid-name is ordinary use and must still produce a proven rename.
    @Test func backspaceEditsTheLine() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename tesx", into: &buffer)
        _ = buffer.consume(event: Self.key(keyCode: 51), committedText: [])
        Self.type("t", into: &buffer)

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == "/rename test")
    }

    /// Ctrl-U and Escape clear the composer, so the line restarts clean and
    /// still trusted rather than being poisoned for the rest of the session.
    @Test func killLineAndEscapeRestartCleanly() {
        for event in [Self.key(keyCode: 32, characters: "u", modifiers: .control),
                      Self.key(keyCode: 53)] {
            var buffer = TerminalInputLineBuffer()
            Self.type("garbage", into: &buffer)
            _ = buffer.consume(event: event, committedText: [])
            Self.type("/rename after", into: &buffer)

            #expect(
                buffer.consume(event: Self.key(keyCode: 36), committedText: []) == "/rename after"
            )
        }
    }

    /// Anything that moves the cursor makes the buffer's copy of the line a
    /// guess. It must fail closed: a wrong rename is the defect this feature
    /// exists to prevent, and a missed one is merely a shrug.
    @Test func cursorMovementInvalidatesTheLine() {
        for keyCode in [UInt16(123), 124, 125, 126, 115, 116, 117, 119, 121] {
            var buffer = TerminalInputLineBuffer()
            Self.type("/rename test", into: &buffer)
            _ = buffer.consume(event: Self.key(keyCode: keyCode), committedText: [])

            #expect(
                buffer.consume(event: Self.key(keyCode: 36), committedText: []) == nil,
                "keyCode \(keyCode) must invalidate the line"
            )
        }
    }

    /// An unproven submit must be distinguishable from an ordinary keystroke.
    ///
    /// `consume` returns `nil` for both, and that ambiguity is what made the
    /// real-world failure invisible: the user typed a rename after pressing Up,
    /// nothing armed, and the only trace was a `detectedButUnarmed` line whose
    /// cause sat several seconds earlier in the log with nothing connecting
    /// them. A caller must be able to log the poisoned submit without logging
    /// every keypress on the typing path `CLAUDE.md` protects.
    @Test func unprovenSubmitIsDistinguishableFromAnOrdinaryKeystroke() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)

        // An ordinary keystroke is not a submit and must not claim to be one.
        #expect(buffer.lastSubmitWasUnproven == false)

        _ = buffer.consume(event: Self.key(keyCode: 126), committedText: [])
        #expect(
            buffer.lastSubmitWasUnproven == false,
            "invalidating the line is not itself a submit"
        )

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == nil)
        #expect(
            buffer.lastSubmitWasUnproven,
            "a Return on an invalidated line is an unproven submit"
        )
    }

    /// The flag must describe **this** key event, not a previous one.
    ///
    /// A cold review caught the original of this: the flag was set only on
    /// Return and never cleared, while the caller reads it on the `nil` path
    /// that every ordinary keystroke takes. One unproven submit therefore made
    /// every following keypress log as one too — per-keystroke I/O on the path
    /// `CLAUDE.md` protects, and a log whose timestamps point at keystrokes
    /// instead of at the submit. That is the exact cause-and-effect
    /// disconnection this diagnostic exists to remove.
    ///
    /// The earlier tests all asserted at submit boundaries, so none of them
    /// looked here.
    @Test func theUnprovenFlagDescribesOnlyTheEventJustHandled() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)
        _ = buffer.consume(event: Self.key(keyCode: 126), committedText: [])
        _ = buffer.consume(event: Self.key(keyCode: 36), committedText: [])
        #expect(buffer.lastSubmitWasUnproven, "precondition: the submit was unproven")

        // The documented recovery — Escape, then retype — must be silent.
        _ = buffer.consume(event: Self.key(keyCode: 53), committedText: [])
        #expect(
            buffer.lastSubmitWasUnproven == false,
            "Escape is not a submit and must not still read as an unproven one"
        )

        Self.type("/", into: &buffer)
        #expect(
            buffer.lastSubmitWasUnproven == false,
            "an ordinary keystroke must not inherit the previous submit's fault"
        )
    }

    /// The flag must not latch. A poisoned submit followed by a clean one has to
    /// report the clean one honestly, or the log would accuse every later rename
    /// of a fault that happened once.
    @Test func aProvenSubmitClearsTheUnprovenFlag() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename first", into: &buffer)
        _ = buffer.consume(event: Self.key(keyCode: 126), committedText: [])
        _ = buffer.consume(event: Self.key(keyCode: 36), committedText: [])
        #expect(buffer.lastSubmitWasUnproven)

        Self.type("/rename second", into: &buffer)

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == "/rename second")
        #expect(
            buffer.lastSubmitWasUnproven == false,
            "the previous line's fault must not follow a proven submit"
        )
    }

    /// Command-modified keys are app or shell actions — paste and history recall
    /// among them — that rewrite the composer where this cannot follow.
    @Test func commandChordInvalidatesTheLine() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)
        _ = buffer.consume(
            event: Self.key(keyCode: 9, characters: "v", modifiers: .command),
            committedText: []
        )

        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == nil)
    }

    /// A multi-line paste commits text containing a newline. The composer then
    /// holds content this never saw, so the line stops being evidence.
    @Test func multiLinePasteInvalidatesTheLine() {
        var buffer = TerminalInputLineBuffer()
        buffer.appendCommitted("/rename test\nsomething else")

        #expect(buffer.provenLine == nil)
    }

    /// Shift-Return inserts a newline instead of submitting, so the line
    /// continues in a shape this cannot track and must not later be claimed.
    @Test func shiftReturnInvalidatesRatherThanSubmits() {
        var buffer = TerminalInputLineBuffer()
        Self.type("/rename test", into: &buffer)

        #expect(
            buffer.consume(
                event: Self.key(keyCode: 36, modifiers: .shift),
                committedText: []
            ) == nil
        )
        #expect(buffer.consume(event: Self.key(keyCode: 36), committedText: []) == nil)
    }

    /// An unbounded line would let a long paste sit in memory on the typing hot
    /// path. `/rename` names are short; anything longer is not one.
    @Test func overlongInputInvalidatesTheLine() {
        var buffer = TerminalInputLineBuffer()
        buffer.appendCommitted(String(repeating: "x", count: 1024))

        #expect(buffer.provenLine == nil)
    }

    private static func type(_ text: String, into buffer: inout TerminalInputLineBuffer) {
        for character in text {
            _ = buffer.consume(
                event: key(keyCode: 0, characters: String(character)),
                committedText: [String(character)]
            )
        }
    }

    private static func key(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
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
