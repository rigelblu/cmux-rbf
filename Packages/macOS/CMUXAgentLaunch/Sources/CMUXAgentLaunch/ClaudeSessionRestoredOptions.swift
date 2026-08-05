import Foundation

/// Strips the options Claude Code restores for itself from a cmux-generated resume/fork argv.
///
/// Claude Code persists a session's model and reasoning effort and restores both on
/// `--resume` — that is why the command it prints when you exit is a bare
/// `claude --resume <id>` with no flags. An explicit flag *overrides* that restore,
/// with ordinary CLI precedence: you typed `--model X`, so you get X.
///
/// cmux, however, rebuilds the resume command from the **live process argv captured at
/// snapshot time** (`VaultAgentProcessScanner`). That argv records launch-time intent
/// Claude has already consumed and the user may since have revoked with `/model` or
/// `/effort`. Replaying it re-asserts a choice the user retracted — and because the
/// resumed session then runs on a different model, the whole conversation re-enters as
/// fresh input tokens instead of a prompt-cache hit. The user pays to rebuild context
/// they already had, on a model they did not pick.
///
/// So the fix is a subtraction, not an addition: emit the command Claude itself
/// prescribes and let it restore its own state.
///
/// **Scoped to the claude builders on purpose — never to `claudePolicy.droppedOptions`.**
/// That policy is shared with `AgentLaunchSanitizer.sanitizedLaunchArguments`, which has
/// six production callers, at least one of which starts a *fresh* session
/// (`TerminalForegroundCommandCapture` save-layout replay). A fresh launch has no session
/// state to restore, so dropping `--model` there would silently discard the model the user
/// explicitly asked for — the same class of bug, in the opposite direction.
///
/// Verified before it was written: a session set to `opus-5`/`xhigh`, restarted, came back
/// on the launch model; resumed instead with Claude's own flagless command, it came back
/// exactly as left. https://github.com/manaflow-ai/cmux — cmux-rbf `#cm-30`
extension AgentResumeArgv {
    /// Options Claude Code restores from its own session state, so cmux must not replay them.
    ///
    /// A *list* rather than a boolean: if another option turns out to be session-restored,
    /// it joins here without new vocabulary. Every entry must be an option Claude restores
    /// — an option it does not restore would be silently lost instead.
    static let claudeSessionRestoredOptions = ["--model", "--effort"]

    /// Returns `preserved` without the options Claude restores for itself.
    ///
    /// Handles both spellings the sanitizer can emit: the two-token form (`--model sonnet`)
    /// and the joined form (`--model=sonnet`). Every other argument survives untouched —
    /// the drop is targeted, not a blanket strip, so `--dangerously-skip-permissions` and
    /// any unknown flag still ride along.
    public static func claudeArgumentsDroppingSessionRestoredOptions(_ preserved: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(preserved.count)
        var index = 0
        while index < preserved.count {
            let argument = preserved[index]
            if claudeSessionRestoredOptions.contains(argument) {
                // Two-token form: skip the option and its value. A trailing option with no
                // value needs no special case — stepping past the end just ends the loop.
                // Mutation testing proved the guard that used to sit here was dead code:
                // no test could discriminate it, because both step sizes exit identically.
                index += 2
                continue
            }
            if claudeSessionRestoredOptions.contains(where: { argument.hasPrefix($0 + "=") }) {
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }
}
