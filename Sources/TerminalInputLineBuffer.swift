import AppKit

/// Accumulates the text the user has committed on the current terminal input
/// line, so an explicit `/rename <name>` submission can be proven from what the
/// user actually typed.
///
/// This replaces reading the name back off the screen. Screen text cannot tell
/// what the user authored from what the agent rendered: a resumed transcript, a
/// queued message echo, or scrollback holding an earlier `/rename foo` all read
/// identically to a fresh submission, and any of them would claim a rename
/// nobody asked for. Committed keystrokes are the actual proof of authorship.
///
/// It is also the same evidence model the embedded entrypoint already uses —
/// `CodexAppServerSession.submit` inspects the text it is handed rather than
/// scraping — so both launch paths prove intent the same way.
///
/// **Fails closed.** Any edit it cannot model exactly invalidates the line, and
/// an invalidated line proves nothing. Missing a rename is a shrug; renaming
/// because Codex auto-named is the defect this whole feature guards against.
///
/// Deliberately free of Ghostty, AppKit view state, and locks: it runs on the
/// typing hot path, where `CLAUDE.md` forbids allocations, I/O, and FFI.
struct TerminalInputLineBuffer {
    /// Longest input line worth tracking. `/rename` names are short; a longer
    /// line is a paste or a prompt, neither of which this proves anything about.
    private static let maxTrackedCharacters = 512

    private var characters: String = ""
    private var isTrustworthy: Bool = true

    /// The line as typed, or `nil` when nothing since the last reset can be
    /// trusted as authored by the user.
    var provenLine: String? {
        isTrustworthy ? characters : nil
    }

    /// Records text the input system committed for one key event.
    ///
    /// A newline arrives here only from a bracketed or multi-line paste — a
    /// plain Return commits no text — so it invalidates rather than submits.
    mutating func appendCommitted(_ text: String) {
        guard !text.isEmpty else { return }
        guard !text.contains(where: \.isNewline) else {
            invalidate()
            return
        }
        // More than one committed string in a single key event, or a long one,
        // means a paste or an IME bulk commit rather than a typed character.
        guard characters.count + text.count <= Self.maxTrackedCharacters else {
            invalidate()
            return
        }
        characters.append(text)
    }

    /// Removes the last character, as Backspace does.
    mutating func deleteBackward() {
        guard isTrustworthy else { return }
        if !characters.isEmpty { characters.removeLast() }
    }

    /// Clears the line and returns it to a trusted state, as Ctrl-U, Ctrl-C,
    /// and Escape do — each leaves the composer empty and unambiguous.
    mutating func reset() {
        characters.removeAll(keepingCapacity: true)
        isTrustworthy = true
    }

    /// Marks the line unusable. Cursor movement, history recall, and paste all
    /// land here: the buffer cannot reconstruct what the composer now holds, so
    /// it must not claim to.
    mutating func invalidate() {
        characters.removeAll(keepingCapacity: true)
        isTrustworthy = false
    }

    /// Consumes the line on submit, returning it only if it is proven.
    mutating func takeSubmittedLine() -> String? {
        defer { reset() }
        return provenLine
    }

    /// Folds one key event in, given the text the input system committed for it.
    /// Returns the proven line when this event submits it, otherwise `nil`.
    ///
    /// - Parameters:
    ///   - event: The key event being handled.
    ///   - committedText: Text the input system produced for this event.
    /// - Returns: The proven submitted line, or `nil`.
    mutating func consume(
        event: NSEvent,
        committedText: [String]
    ) -> String? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // Command-modified keys are app or shell actions this cannot model —
        // paste and history recall among them.
        if mods.contains(.command) {
            invalidate()
            return nil
        }

        switch event.keyCode {
        case 36, 76:                                   // Return, numpad Enter
            guard mods.isEmpty else {
                // Shift-Return and friends insert a newline instead of
                // submitting, so the line continues in a shape we cannot track.
                invalidate()
                return nil
            }
            return takeSubmittedLine()
        case 51:                                       // Backspace
            guard mods.isEmpty else { invalidate(); return nil }
            deleteBackward()
            return nil
        case 53:                                       // Escape
            reset()
            return nil
        case 123, 124, 125, 126,                       // Arrows
             115, 116, 117, 119, 121:                  // Home, PageUp, FwdDelete, End, PageDown
            invalidate()
            return nil
        default:
            break
        }

        if mods.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "u", "c":                             // kill-line, cancel
                reset()
            default:
                invalidate()
            }
            return nil
        }

        for text in committedText { appendCommitted(text) }
        return nil
    }
}
