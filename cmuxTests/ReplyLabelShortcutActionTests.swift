import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-83.2` — the label key as a *configured* action.
///
/// The running panel is what proves a press inserts a label; these guard the
/// parts a press cannot show. Two of them exist because the decision they
/// protect is encoded as an **absence**, which no compiler enforces: the
/// action is deliberately not dock-scoped, and it is deliberately a
/// numbered-digit action. Adding or removing either would compile clean and
/// change behaviour silently — the shape that shipped a dead key in
/// `cm-78.1`.
@Suite
struct ReplyLabelShortcutActionTests {
    /// Bare Option, and the digit normalised to "1" the way every numbered
    /// action stores it. The binding reversed three times on 2026-09-11
    /// (⌥⌘ → ⌃ → ⌥) and this is what Tom accepted on a running build.
    @Test
    func defaultsToBareOptionDigit() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .insertReplyLabelByNumber)
        #expect(shortcut.eventModifiers == .option)
        #expect(shortcut.keyEquivalent == KeyEquivalent("1"))
        #expect(shortcut.isUnbound == false)
        #expect(shortcut.hasChord == false)
    }

    /// One action covers 1…9 by digit substitution rather than nine bindings.
    /// Without this the Settings row records a single literal key and ⌥2…⌥9
    /// never resolve.
    @Test
    func isANumberedDigitAction() {
        #expect(KeyboardShortcutSettings.Action.insertReplyLabelByNumber.usesNumberedDigitMatching)
    }

    /// The contested row, stated as a test so nobody "tidies" the default onto
    /// it: ⌃1–⌃5 are the sidebar mode switches and ⌃1–⌃9 is surface selection,
    /// and both have priority routing while the sidebar holds focus — which is
    /// the state a note field is in.
    @Test
    func doesNotLandOnTheContestedControlRow() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .insertReplyLabelByNumber)
        #expect(shortcut.eventModifiers.contains(.control) == false)
        let sidebarModes = KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFiles)
        let surfaces = KeyboardShortcutSettings.shortcut(for: .selectSurfaceByNumber)
        #expect(shortcut.eventModifiers != sidebarModes.eventModifiers)
        #expect(shortcut.eventModifiers != surfaces.eventModifiers)
    }

    /// Decided by absence on 2026-09-11: a Reply-panel key is not dock-scoped,
    /// because the Dock's surfaces never hold a note field. Nothing but this
    /// test says so.
    @Test
    func isNotDockScoped() {
        #expect(
            KeyboardShortcutSettings.Action.insertReplyLabelByNumber
                .dockShortcutRoutingDisposition != .dockScoped
        )
    }
}
