import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-83.3` — the `⌄` menu, built once and opened by both the click and `⌥0`.
///
/// The running panel is what proves it opens; these guard what it contains.
/// The key equivalents especially: they are derived per row from **one**
/// configured binding, which no other consumer in this codebase does, so
/// nothing else would notice if the derivation broke.
@MainActor
@Suite
struct ReplyLabelMenuTests {
    private func make(
        labels: [String],
        shortcut: StoredShortcut = StoredShortcut(
            key: "1", command: false, shift: false, option: true, control: false
        )
    ) -> NSMenu {
        ReplyLabelMenu.make(labels: labels, shortcut: shortcut, apply: { _ in }, edit: {})
    }

    /// The rows below the `⌥0` caption and its separator. The caption is only
    /// present when the opening key actually dispatches, so this computes the
    /// offset from the menu rather than hardcoding it — a test that hardcodes 2
    /// passes when the caption silently disappears.
    private func labelRows(_ menu: NSMenu) -> [NSMenuItem] {
        guard let sep = menu.items.firstIndex(where: \.isSeparatorItem) else { return menu.items }
        return menu.items[0].isEnabled ? menu.items : Array(menu.items[(sep + 1)...])
    }

    /// Every label, a separator, then `Edit labels…` — the menu is the full
    /// list now, not the chips' overflow, because the keyboard has no chips.
    @Test
    func holdsEveryLabelPlusTheEditItem() {
        let menu = make(labels: ["lgtm", "why?", "redline"])
        // caption, separator, 3 labels, separator, Edit labels…
        #expect(menu.items.count == 7)
        // The caption shifts them, so the raw prefix is no longer the labels.
        #expect(menu.items[0].isEnabled == false)
        #expect(menu.items[1].isSeparatorItem)
        #expect(labelRows(menu).prefix(3).map(\.title) == ["lgtm", "why?", "redline"])
        #expect(menu.items[5].isSeparatorItem)
        #expect(menu.items[6].isSeparatorItem == false)
        #expect(menu.items[6].title == labelRows(menu).last?.title)
    }

    /// The row naming the key that opens this menu — laid out like every other
    /// row, text left and key right — and the two states where it must not
    /// appear, because `⌥0` does not dispatch for an unbound or chord binding
    /// either and a legend for a dead key is worse than none.
    ///
    /// The modifier assertion is the load-bearing one: it is the only thing
    /// separating a row DERIVED from the binding from a hardcoded `⌥0`, and a
    /// hardcoded one goes stale the moment anyone rebinds in Settings.
    @Test
    func captionsTheOpeningKeyOnlyWhenThatKeyWorks() {
        let menu = make(labels: ["lgtm"])
        let caption = menu.items[0]
        #expect(caption.title == "Open this menu")
        #expect(caption.keyEquivalent == "0")
        #expect(caption.keyEquivalentModifierMask == .option)
        // Inert three ways: nothing to send, disabled, and the menu does not
        // auto-enable. A key equivalent on a live item would fire while tracking.
        #expect(caption.action == nil)
        #expect(caption.isEnabled == false)

        // Derived, not hardcoded: a different binding moves the glyph.
        let rebound = StoredShortcut(
            key: "1", command: true, shift: false, option: false, control: true
        )
        let reboundRow = ReplyLabelMenu.openingKeyRow(rebound)
        #expect(reboundRow?.keyEquivalentModifierMask == [.command, .control])
        #expect(reboundRow?.keyEquivalent == "0")

        var chord = StoredShortcut(key: "g", command: false, shift: false, option: false, control: false)
        chord.chordKey = "1"
        #expect(ReplyLabelMenu.openingKeyRow(chord) == nil)

        let unbound = StoredShortcut(key: "", command: false, shift: false, option: false, control: false)
        #expect(ReplyLabelMenu.openingKeyRow(unbound) == nil)
        #expect(make(labels: ["a"], shortcut: unbound).items[0].isEnabled)  // no row, label is first
    }

    /// With no labels there is nothing to separate, so no stray divider above
    /// the only remaining item.
    @Test
    func withNoLabelsItIsJustTheEditItem() {
        let menu = make(labels: [])
        // caption, separator, Edit labels… — no second divider with nothing above it
        #expect(menu.items.count == 3)
        #expect(menu.items.last?.isSeparatorItem == false)
        #expect(menu.items.filter(\.isSeparatorItem).count == 1)
    }

    /// The digit is derived per row from one stored binding — row 1 gets "1",
    /// row 3 gets "3" — carrying that binding's modifiers.
    @Test
    func derivesOneKeyEquivalentPerRowFromTheConfiguredBinding() {
        let menu = make(labels: ["a", "b", "c"])
        let rows = labelRows(menu)
        #expect(rows[0].keyEquivalent == "1")
        #expect(rows[1].keyEquivalent == "2")
        #expect(rows[2].keyEquivalent == "3")
        #expect(rows[0].keyEquivalentModifierMask == .option)
        #expect(rows[2].keyEquivalentModifierMask == .option)
    }

    /// Rebinding in Settings changes what the menu draws, because the mask
    /// comes from the binding rather than a literal.
    @Test
    func followsAReboundModifier() {
        let menu = make(
            labels: ["a"],
            shortcut: StoredShortcut(
                key: "1", command: true, shift: false, option: false, control: true
            )
        )
        #expect(labelRows(menu)[0].keyEquivalentModifierMask == [.command, .control])
    }

    /// The digits run out at nine. Labels past it stay in the menu and stay
    /// clickable, with no equivalent rather than a wrong one.
    @Test
    func stopsDrawingKeysAfterTheNinth() {
        let labels = (1...11).map { "label\($0)" }
        let menu = make(labels: labels)
        let rows = labelRows(menu)
        #expect(rows[8].keyEquivalent == "9")
        #expect(rows[9].keyEquivalent == "")
        #expect(rows[10].keyEquivalent == "")
        #expect(rows[9].title == "label10")
    }

    /// A chord binding cannot be expressed as a menu key equivalent, so the
    /// menu draws none rather than the chord's first stroke — which would be
    /// a key that does something else.
    @Test
    func drawsNothingForAChordOrUnboundBinding() {
        // `hasChord` is `secondStroke != nil`; `isUnbound` is an empty key.
        var chord = StoredShortcut(key: "g", command: false, shift: false, option: false, control: false)
        chord.chordKey = "1"
        #expect(chord.hasChord)
        #expect(make(labels: ["a"], shortcut: chord).items[0].keyEquivalent == "")

        let unbound = StoredShortcut(key: "", command: false, shift: false, option: false, control: false)
        #expect(unbound.isUnbound)
        #expect(make(labels: ["a"], shortcut: unbound).items[0].keyEquivalent == "")
    }

    /// What the menu *does*, not what it draws. Every other test in this file
    /// reads titles, counts and key equivalents — all of which stay right
    /// while the wiring rots. A cold review found five single-line mutations
    /// to `ReplyLabelMenu.make` that leave all six of them green, including
    /// one where every row stamps the *first* label.
    ///
    /// Proven by mutation 2026-09-12: M1 (`apply(label)` → `apply(labels[0])`)
    /// and M3 (delete `item.target`) each redden this test alone.
    @Test
    func eachRowFiresItsOwnLabel() {
        var stamped: [String] = []
        var opened = 0
        let menu = ReplyLabelMenu.make(
            labels: ["lgtm", "why?", "redline"],
            shortcut: StoredShortcut(
                key: "1", command: false, shift: false, option: true, control: false
            ),
            apply: { stamped.append($0) },
            edit: { opened += 1 }
        )
        for item in labelRows(menu).prefix(3) {
            // Firing the singleton by hand works whatever the item's target
            // is, so without this the "no target, menu inert" mutation lives.
            #expect(item.target === ReplyLabelMenuTarget.shared)
            ReplyLabelMenuTarget.shared.fire(item)
        }
        #expect(stamped == ["lgtm", "why?", "redline"])
        #expect(opened == 0)
    }

    /// The way into Settings is the last item, and it is the *only* item that
    /// goes there — the swap mutation (label rows carrying `edit`, the edit
    /// row carrying `apply`) is invisible to every assertion about titles.
    ///
    /// Proven by mutation 2026-09-12: M2 (`ReplyLabelMenuAction(edit)` →
    /// `ReplyLabelMenuAction { }`) reddens this test alone.
    @Test
    func theEditItemOpensSettingsAndNothingElseDoes() {
        var stamped: [String] = []
        var opened = 0
        let menu = ReplyLabelMenu.make(
            labels: ["lgtm"],
            shortcut: StoredShortcut(
                key: "1", command: false, shift: false, option: true, control: false
            ),
            apply: { stamped.append($0) },
            edit: { opened += 1 }
        )
        // caption, separator, one label, separator, Edit labels…
        #expect(menu.items.count == 5)
        let edit = menu.items[4]
        #expect(edit.keyEquivalent == "")
        #expect(edit.target === ReplyLabelMenuTarget.shared)
        ReplyLabelMenuTarget.shared.fire(edit)
        #expect(opened == 1)
        #expect(stamped.isEmpty)
    }
}
