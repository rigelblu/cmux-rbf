/// Cached pane state used to filter physical keys and phone typing without I/O.
///
/// The owner projects the first three values from agent lifecycle and session
/// settings. Accepting input never clears the projected wait flag itself.
public struct TerminalAgentInputState: Sendable {
    /// Whether the pane's projected lifecycle includes a real open wait.
    public var needsInput: Bool
    /// Whether the pane's projected lifecycle includes a running agent.
    public var isRunning: Bool {
        didSet { if !isRunning { previousWasEscape = false } }
    }
    /// Whether a running Claude session requires two consecutive Escape keys.
    public var usesVimEditor: Bool {
        didSet { if !usesVimEditor { previousWasEscape = false } }
    }
    private var previousWasEscape = false

    /// Creates an input filter, initially uninterested unless agent state is supplied.
    /// - Parameters:
    ///   - needsInput: Whether a wait is open; defaults to false.
    ///   - isRunning: Whether an agent is running; defaults to false.
    ///   - usesVimEditor: Whether running Escape uses vim's double-key rule.
    public init(needsInput: Bool = false, isRunning: Bool = false, usesVimEditor: Bool = false) {
        self.needsInput = needsInput
        self.isRunning = isRunning
        self.usesVimEditor = usesVimEditor
    }

    /// Reports whether a key can change attention state or reset an Escape sequence.
    /// - Parameter isEscape: True only for a physical Escape, never committed text.
    /// - Returns: Whether the caller needs to inspect Ghostty's binding result.
    public func requiresKeyInspection(isEscape: Bool) -> Bool {
        isEscape ? needsInput || isRunning : needsInput || previousWasEscape
    }

    /// Reads Ghostty's pre-dispatch binding answer for the filter.
    ///
    /// Ghostty binds Escape to a performable `end_search` by default. cmux closes its own find before the key
    /// reaches Ghostty, so that binding never performs and the Escape reaches the program like any other key.
    /// - Parameters:
    ///   - isBinding: Whether Ghostty reported a binding for the key.
    ///   - isPerformable: Whether that binding only fires when its action can perform.
    ///   - isEscape: True only for a physical Escape, never committed text.
    /// - Returns: Whether `acceptKey` should treat the key as a binding.
    public static func countsAsBinding(isBinding: Bool, isPerformable: Bool, isEscape: Bool) -> Bool {
        isBinding && !(isEscape && isPerformable)
    }

    /// Filters an accepted key after the caller's pre-dispatch Ghostty binding check.
    /// - Parameters:
    ///   - isEscape: True only for a physical Escape, never committed text.
    ///   - isBinding: Whether Ghostty consumed this key as a binding.
    /// - Returns: Nil for no journal action; otherwise whether to declare unknown after resolving.
    public mutating func acceptKey(isEscape: Bool, isBinding: Bool) -> Bool? {
        if isBinding { previousWasEscape = false; return nil }
        if needsInput { previousWasEscape = false; return isEscape }
        guard isEscape, isRunning else { previousWasEscape = false; return nil }
        if usesVimEditor, !previousWasEscape { previousWasEscape = true; return nil }
        previousWasEscape = false
        return true
    }

    /// Filters text accepted by a phone typing lane, excluding scrolls and taps.
    /// - Returns: False when a wait should resolve, otherwise nil.
    public mutating func acceptPhoneText() -> Bool? {
        previousWasEscape = false
        return needsInput ? false : nil
    }
}
