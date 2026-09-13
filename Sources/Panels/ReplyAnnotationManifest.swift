import AppKit
import CmuxAgentChat
import SwiftUI

/// Footer geometry, read off the Figma frames rather than derived from prose.
///
/// All seven drawn footers — `N1 101:758`, `N2 101:928`, `N3 102:858`,
/// `N9 138:1308`, `N10 138:1476`, `N11 274:901`, `L5 89:650` — are one
/// 10pt-gutter stack: first line at `y = 9`, rows 12pt, 7pt between them.
/// The `⤢` sits at `(258, 9)` 8×12 in **all seven**, which is what says it is
/// pinned to the footer's corner and not to any row.
///
/// These lived as a sentence in a companion brief (*"aligned to the first
/// content row's line"*) and got built twice from arithmetic on it, wrong
/// both times. A paraphrase of geometry drops what only the numbers carry.
/// Which mark the panel is treating as in focus.
///
/// One rule, named once, because **two** surfaces draw it — the highlight in
/// the message and the row in the footer — and the brief states it for both
/// at once: *"a different tone marks the one in focus — hovered, or open in
/// the footer's field"*. Written out at each call site it drifted: the page
/// resolved `hoveredID ?? editingID` and the row resolved `hoveredID` alone,
/// so opening a note lit the span and left its own row plain (Tom, dogfood
/// 2026-09-07).
///
/// Hover wins while it lasts, so moving the pointer still answers *"which one
/// is that?"* without losing where you were.
enum ReplyMarkFocus {
    static func id(hovered: UUID?, editing: UUID?) -> UUID? { hovered ?? editing }
}

/// Which note an ↑/↓ step lands on — `#cm-82`.
///
/// Wraps at both ends, because Tom chose it (2026-09-10) — but **not on a
/// held key**. At normal repeat rate a held ↓ laps a nine-note list about
/// once a second, so wherever it was released would be random. Held, it
/// walks to the end and stops; one fresh press wraps.
///
/// `nil` means "there is nowhere to go": one note (wrap would land on
/// itself), none, or an index the list has re-numbered out from under. The
/// caller then lets the key fall through to the text field's own caret move.
enum ReplyNoteStep {
    enum Direction { case previous, next }

    static func target(from index: Int, count: Int, _ direction: Direction, isRepeat: Bool = false) -> Int? {
        guard count > 1, (0..<count).contains(index) else { return nil }
        let raw = direction == .next ? index + 1 : index - 1
        let wraps = raw < 0 || raw >= count
        if wraps && isRepeat { return nil }
        return (raw + count) % count
    }
}

/// The `⌄` menu, as AppKit — `#cm-83.3`.
///
/// An `NSMenu` rather than SwiftUI's `Menu` because a key has to open it and
/// SwiftUI offers no way to do that — nothing in this codebase opens a SwiftUI
/// menu from code. One menu serves both the click and `⌥0`, so the two
/// entrances cannot drift apart.
///
/// Anchoring in an `NSView` is a **choice**, not a constraint, and an earlier
/// version of this comment claimed otherwise. Of the eight pre-existing
/// `popUp(positioning:at:in:)` call sites, seven pass a view and one
/// (`FilePreviewPanel.swift:344`) passes `nil` and opens at the mouse. The
/// view is used here so the menu opens at the chevron rather than wherever
/// the pointer happens to be — which matters precisely because `⌥0` opens it
/// with no pointer involved at all.
///
/// It also carries the key equivalents `#cm-83.2` owes: macOS draws `⌥1`…`⌥9`
/// in the menu's own right-hand column, from the **configured** binding, so
/// rebinding in Settings changes what the menu shows. Labels past the ninth
/// appear without one — the digits run out.
@MainActor
enum ReplyLabelMenu {
    /// How far below the anchor's centre the menu's top-left should land.
    /// The anchor is centred on the chevron chip: an 8pt glyph with 3pt of
    /// padding above and below, so 7pt clears its bottom edge and 4pt is the
    /// gap. Written out because the value it replaced was `bounds.height + 4`
    /// on a zero-size view — always 4, and in the wrong direction.
    static let dropBelowChevron: CGFloat = 11

    static func make(
        labels: [String],
        shortcut: StoredShortcut,
        apply: @escaping (String) -> Void,
        edit: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // `#cm-83.3`, added 2026-09-12 on Tom's dogfood: the menu listed every
        // label's key and never the key that opens it, so `⌥0` had **no
        // discoverability surface anywhere in the product** — the changelog was
        // the only place it existed. A cold review found the same gap.
        //
        // It is a dimmed, unselectable caption rather than a key equivalent on
        // `Edit labels…`, which is what a first reading suggests: that column
        // means "press this to run this row", and the opening key does not run
        // any row. Drawn from the **configured** modifiers, so a rebind moves it
        // — and omitted entirely when the binding is unbound or a chord, because
        // then no digit dispatches and `⌥0` does not work either. A caption for a
        // key that does nothing is worse than no caption.
        if let caption = openingKeyRow(shortcut) {
            menu.addItem(caption)
            menu.addItem(.separator())
        }
        for (index, label) in labels.enumerated() {
            let item = NSMenuItem(
                title: label,
                action: #selector(ReplyLabelMenuTarget.fire(_:)),
                keyEquivalent: ""
            )
            // Derived per row from one stored binding, the way
            // `cmuxApp.swift:1106-1138` does for `selectWorkspaceByNumber`.
            // An unbound or chord binding draws nothing rather than a wrong key.
            if index < 9, !shortcut.isUnbound, !shortcut.hasChord {
                item.keyEquivalent = String(index + 1)
                item.keyEquivalentModifierMask = shortcut.firstStroke.modifierFlags
            }
            item.target = ReplyLabelMenuTarget.shared
            item.representedObject = ReplyLabelMenuAction { apply(label) }
            item.isEnabled = true
            menu.addItem(item)
        }
        if !labels.isEmpty { menu.addItem(.separator()) }
        let editItem = NSMenuItem(
            title: String(localized: "reply.labels.editLabels", defaultValue: "Edit labels…"),
            action: #selector(ReplyLabelMenuTarget.fire(_:)),
            keyEquivalent: ""
        )
        editItem.target = ReplyLabelMenuTarget.shared
        editItem.representedObject = ReplyLabelMenuAction(edit)
        editItem.isEnabled = true
        menu.addItem(editItem)
        return menu
    }

    /// The row above the labels naming the key that opens this menu, or `nil`
    /// when that key is dead.
    ///
    /// **Laid out like every other row** — text left, key right (Tom, dogfood
    /// 2026-09-12) — rather than folding the glyph into the title. The digit
    /// and modifiers go in the item's own key-equivalent column, so macOS
    /// aligns it with the labels' `⌥1`…`⌥9` instead of it reading as prose.
    ///
    /// **Inert by three separate means**, because a key equivalent on a menu
    /// item is normally live while the menu tracks: `action` is `nil` so there
    /// is nothing to send, `isEnabled` is false, and the menu sets
    /// `autoenablesItems = false` so nothing re-enables it. It is a legend,
    /// not a command.
    ///
    /// Mirrors the `"0"` handler's own guard in `ReplyPanelView` — same two
    /// refusals, so the row cannot advertise a key the handler will decline.
    static func openingKeyRow(_ shortcut: StoredShortcut) -> NSMenuItem? {
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        let modifiers = shortcut.firstStroke.modifierFlags
        guard !modifiers.isEmpty else { return nil }
        let item = NSMenuItem(
            title: String(
                localized: "reply.labels.openThisMenu",
                defaultValue: "Open this menu"
            ),
            action: nil,
            keyEquivalent: "0"
        )
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = false
        return item
    }
}

/// Carries a menu item's closure, since `NSMenuItem` takes a selector.
final class ReplyLabelMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@MainActor
final class ReplyLabelMenuTarget: NSObject {
    static let shared = ReplyLabelMenuTarget()
    @objc func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? ReplyLabelMenuAction)?.run()
    }
}

/// A zero-size AppKit view the menu anchors to, co-located with the chevron.
/// Anchoring at the chevron needs an `NSView`, and SwiftUI has none to give.
/// (`popUp` itself accepts `nil` — that opens at the mouse, which is wrong for
/// a menu a key press opens.)
///
/// The view is handed back through a **reference box, not `@State`**: writing
/// SwiftUI state from `makeNSView`/`updateNSView` happens during a view update,
/// where it is deferred or dropped — which is why the first version of this
/// left the anchor nil and the menu never opened.
@MainActor
final class ReplyMenuAnchorBox {
    weak var view: NSView?
}

struct ReplyMenuAnchor: NSViewRepresentable {
    /// Flipped so `popUp`'s `y` grows downward, the way the call site reads.
    /// An unflipped `NSView` put the menu 4pt *above* the chevron's centre,
    /// covering the control it belongs to.
    final class Anchor: NSView {
        override var isFlipped: Bool { true }
    }
    let box: ReplyMenuAnchorBox
    func makeNSView(context: Context) -> Anchor {
        let v = Anchor(frame: .zero)
        box.view = v
        return v
    }
    func updateNSView(_ nsView: Anchor, context: Context) { box.view = nsView }
}

/// Which note Tab opens when the keyboard is in the reply body — `#cm-83.1`.
///
/// Deliberately **not** part of ``ReplyNoteStep``, which answers a different
/// question and answers it differently: the step refuses a single note
/// (`count > 1`, so a lone note has nowhere to go) where the entrance must
/// open it, since the single note is exactly what has no keyboard route
/// today. Folding the two together would make one of them wrong.
///
/// `editingIndex` is the note already open, if any. It is a **target, not a
/// refusal**: a note can be open while the keyboard sits in the reply body
/// (click any unmarked text and `onMarkClicked` leaves it open), and in that
/// state the field's own Tab handler never fires because the field is not
/// focused. Refusing there would ship a key that does nothing with a note
/// visibly on screen.
enum ReplyNoteEntrance {
    static func target(count: Int, editingIndex: Int?, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        if let editingIndex, (0..<count).contains(editingIndex) { return editingIndex }
        return backwards ? count - 1 : 0
    }
}

/// One keyboard step's request to bring a note into view — `#cm-82`.
///
/// `seq` bumps on every step, so stepping back to the same note still
/// scrolls, while re-sending the same request on an unrelated pass does not.
struct ReplyRevealRequest: Equatable {
    let id: UUID
    let seq: Int
}

enum ReplyFooterMetrics {
    static let topInset: CGFloat = 9
    static let rowGap: CGFloat = 7

    /// The `✕`'s column, as a trailing inset from the 266 gutter.
    ///
    /// `N3 102:920` draws it at x 251–260 — six points inside the `⤢`'s 266.
    /// That works in the frame because `N3` hovers **row 2**, and no frame
    /// ever draws a hovered row 1: at 260 the `✕` would sit under the glyph's
    /// 258–266. So the column moves out to 250, clear of the glyph, and it is
    /// the same column on every row.
    ///
    /// The first version reserved the glyph's width by padding *row 1* — which
    /// took that row's `✕` with it, so the glyph sat at one x on row 1 and
    /// another on every row below and jumped as the pointer moved down the
    /// list (Tom, dogfood 2026-09-06). A column that moves is not a column.
    static let removeInset: CGFloat = 16

    /// `N3 102:919`: an 18pt hover band around a 12pt row.
    static let hoverPadding: CGFloat = 3

    /// How far the hover band reaches past the row's text sideways.
    ///
    /// `N3 102:919` is a 256-wide band at the gutter with its text at x=4
    /// inside it. Drawn that way the text shifts 4pt right on hover, so the
    /// band grows **outward** here instead and nothing moves under the
    /// pointer — the identical call the vertical band already makes against
    /// the same frame, which pushes every row below it down by six.
    ///
    /// Without it the band ended exactly where the text did and the row read
    /// as clipped rather than highlighted (Tom, dogfood 2026-09-06).
    static let hoverInset: CGFloat = 4

    /// The open note field's box, inside its border.
    ///
    /// Named so the `✕` beside it can read the same numbers: the box's text
    /// starts `vertical` below the box's top edge, and that is the offset the
    /// glyph needs to land on the field's **first line** rather than on the
    /// row's.
    static let fieldInset = (horizontal: CGFloat(6), vertical: CGFloat(4))

    /// One line of the row's own font, so the `✕` can be centred on the text
    /// beside it rather than pinned to the row's top.
    ///
    /// **Derived, not typed.** The frames give rows as 12pt, which is the
    /// cap-to-baseline box a designer draws — not the line box the text
    /// actually occupies. Typing either number in would make the glyph's
    /// position an assumption about a font; asking the font makes it a fact
    /// about the one being drawn. `ReplyAnnotationManifestRenderTests`
    /// checks the result against the rendered text, which is the only place
    /// the two can be compared.
    static let rowLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: rowFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    static let rowFontSize: CGFloat = 11
}

/// The footer's manifest: what `Paste` will send, in the order it will send
/// it, with the `⤢` pinned to the corner.
///
/// **A view over plain data, deliberately.** This is the exact part of the
/// panel the Figma frames specify, so it is the exact part that needs a render
/// check — and it can only have one if it does not drag a store, a `WKWebView`
/// and a bound workspace along with it. `ReplyAnnotationManifestTests` renders
/// it at 276pt and writes a PNG to put beside the frame.
struct ReplyAnnotationManifest<Field: View>: View {
    let entries: [NumberedAnnotation]
    let editingID: UUID?
    @Binding var hoveredID: UUID?

    /// The row in focus: under the pointer, or with its note open.
    ///
    /// **One value, because the message's mark resolves the same way.** The
    /// brief states the rule once for both surfaces — *"a different tone
    /// marks the one in focus — hovered, or open in the footer's field"* —
    /// and the panel passes `hoveredID ?? editingID` to the page. The row
    /// resolved `hoveredID` alone, so opening a note lit the span in the
    /// message and left its own row plain, and moving the pointer away
    /// mid-note took the row's state with it (Tom, dogfood 2026-09-07).
    ///
    /// The `✕` deliberately does **not** follow this: removal is a control on
    /// the *hovered* row (settled 2026-09-04), and a delete button appearing
    /// under a cursor that is elsewhere is a different promise.
    private var focusedID: UUID? { ReplyMarkFocus.id(hovered: hoveredID, editing: editingID) }
    let placeholder: String
    let gutter: CGFloat

    /// What the open note field's box is filled with — the page's own canvas,
    /// so the box and the reply it quotes come from one palette.
    let fieldFill: Color

    /// What a hovered row is washed with.
    ///
    /// The **same** colour the mark takes in the page, because one
    /// `hoveredID` lights both and they are one object. Shipped as a neutral
    /// grey it read as two unrelated things answering one pointer (Tom,
    /// dogfood 2026-09-06). Passed in rather than derived here: the hue
    /// belongs to the page's theme, and this view deliberately knows nothing
    /// about themes.
    let hoverFill: Color

    /// What text sits on `hoverFill`.
    ///
    /// Needed only since the fill went opaque. While it was a wash the row's
    /// own colours kept reading through it; a solid fill has no ground
    /// showing through, so the row has to say what goes on top — the same
    /// reason the page's mark gained `onAccentHover` in the same change.
    let hoverTextFill: Color

    /// How tall the list may grow before it scrolls.
    let ceiling: CGFloat
    /// Scroll this note's row into view, once per `seq` — `#cm-82`. Only a
    /// keyboard step sets it; clicks and new selections leave it alone.
    var revealRequest: ReplyRevealRequest? = nil

    /// How tall the rows actually are. Written back so the list can size to
    /// its content *and* stop at the ceiling, and so the count line knows
    /// whether rows are hidden.
    @Binding var measuredHeight: CGFloat

    let onBeginEditing: (NumberedAnnotation) -> Void
    let onRemove: (UUID) -> Void
    let onPreview: () -> Void
    /// `cm-69.3`'s quick labels, in order. Handed in rather than read here:
    /// no view below the list's `ForEach` may hold a settings or store
    /// reference (the `#2586` spin-loop rule).
    var labels: [String] = []
    /// Puts a label's text into the open note.
    var onApplyLabel: (NumberedAnnotation, String) -> Void = { _, _ in }
    /// `#cm-83.3` — the owner pops the AppKit label menu; the manifest only
    /// says when, because the menu needs the panel's state to build itself.
    var onOpenLabelMenu: (NumberedAnnotation) -> Void = { _ in }
    /// Holds the zero-size view the menu anchors to.
    var labelMenuAnchorBox: ReplyMenuAnchorBox = ReplyMenuAnchorBox()
    /// A click on the open row's band, outside its controls: close the note,
    /// keeping its text (Tom, dogfood 2026-09-11).
    var onCloseEditing: () -> Void = {}
    @ViewBuilder let field: (NumberedAnnotation) -> Field

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: ReplyFooterMetrics.rowGap) {
                // **The header is always there, and that is what makes the
                // `⤢` unambiguous.** `N10 138:1477` draws it — `12 notes` at
                // y=9, list from y=28 — and only `N10`, so the other footers
                // left the glyph sitting beside whatever their first line
                // happened to be. That reads as *expand this row*, which is
                // exactly the wrong claim: it opens the whole payload.
                //
                // A row of its own gives it something to belong to. It also
                // ends the bug that cost two rounds of dogfood — the glyph
                // "moving" was never a position error, it was the glyph
                // having no anchor of its own (Tom, 2026-09-06: *"that will
                // also resolve that to not create the association of the
                // expanding is for a specific item"*).
                //
                // **Shown at every count, because this is the section's
                // label and not a readout.** Below the ceiling the number is
                // redundant — the rows are numbered, so the last one *is* the
                // count. Dropping it there was tempting and wrong: the header
                // line still has to exist to anchor the `⤢`, so removing the
                // text leaves a blank strip with a glyph floating in it.
                //
                // Naming it well therefore matters more, not less. A
                // *highlight* exists from the instant the span is marked and
                // does not wait on any text — which `notes` stopped being
                // true of the moment `Paste` stopped requiring one.
                Text(
                    String(
                        localized: "reply.annotation.count",
                        defaultValue: "\(entries.count) highlights"
                    )
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, gutter)

                list
            }
            // Pinned to the corner, not to a row: the frames put it at the
            // same `(258, 9)` whether the first line is a quote, a note, or a
            // count.
            previewButton
                .padding(.trailing, gutter)
        }
    }

    /// Whether rows are hidden below the fold.
    ///
    /// Measured, not estimated from a row count: rows are as tall as their
    /// notes, and a long note is exactly the case that reaches the ceiling
    /// first.
    private var atCeiling: Bool { measuredHeight > ceiling }

    /// A `ScrollView` only once there is something to scroll.
    ///
    /// It used to be one unconditionally, which forced the explicit measured
    /// height: a `ScrollView` is greedy, so `maxHeight` alone made the footer
    /// full-height at one note, and `fixedSize` then ignored the ceiling and
    /// drew the footer over the reply.
    ///
    /// **`maxHeight` was the second version of that same bug, and it lasted
    /// longer because it looked right in a render.** `.frame(maxHeight:)`
    /// does not cap a view — it makes it *flexible up to* that height, so in
    /// a space-distributing parent it takes everything offered. With one
    /// highlight the footer filled the panel and squeezed the reply to a
    /// couple of lines (Tom, dogfood 2026-09-07). The comment here used to
    /// claim "a plain `VStack` is not greedy, so `maxHeight` does exactly the
    /// right thing"; the greed belongs to the modifier, not the content.
    ///
    /// So the height is stated, not bounded: natural under the ceiling,
    /// exactly the ceiling above it. The measurement only decides *which*.
    ///
    /// It also keeps the list renderable: `ImageRenderer` lays out no
    /// `ScrollView` content at all, so the first render of this view came back
    /// as a blank 276×301 with only the count line and the `⤢` on it.
    private var list: some View {
        // Wraps the whole group, not just the `ScrollView`: the scroll view
        // exists only at the ceiling. Below it every row is already on
        // screen, so `scrollTo` finding nothing to scroll is correct.
        ScrollViewReader { proxy in
            Group {
                if atCeiling {
                    // A proportion, not a row count: the panel is as tall as the
                    // window, so "nine rows" would be right at exactly one height.
                    ScrollView { rows }
                        .frame(height: ceiling)
                } else {
                    rows
                }
            }
            .onChange(of: revealRequest) { request in
                // No anchor: SwiftUI then scrolls only as far as needed, and
                // not at all when the row is already visible.
                guard let request else { return }
                proxy.scrollTo(request.id, anchor: nil)
            }
            // A step can change the list's height across the ceiling, which
            // swaps in a fresh `ScrollView` scrolled to the top — after the
            // reveal above already ran. Repeat it for the note still open.
            .onChange(of: atCeiling) { _ in
                guard let request = revealRequest, request.id == editingID else { return }
                proxy.scrollTo(request.id, anchor: nil)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: ReplyFooterMetrics.rowGap) {
            ForEach(entries) { row($0).id($0.id) }
        }
        .padding(.horizontal, gutter)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measuredHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { measuredHeight = $0 }
            }
        )
    }

    private func row(_ entry: NumberedAnnotation) -> some View {
        VStack(alignment: .leading, spacing: ReplyFooterMetrics.rowGap) {
            if editingID == entry.id {
                // The quote belongs to the entry being edited, not to the
                // footer's top. `N2 126:1001` draws `quote while editing` at
                // y=47 — between rows 2 and 4, inside the entry — which is how
                // *"the list stays the list"* and *"the footer shows quote ·
                // field"* are both true at once.
                //
                // Leaving it out is what made the `⤢` look misplaced: with no
                // quote the field became the footer's first line, so the glyph
                // sat beside the box instead of above it.
                Text(verbatim: "\u{201C}\(displayQuote(entry.quote))\u{201D}")
                    .font(.system(size: ReplyFooterMetrics.rowFontSize))
                    // On the band it takes the band's ink, like everything
                    // else in the row. Missed when the row's other text was
                    // converted, because the quote only exists while editing
                    // — so it is invisible in every state the render tests
                    // cover except one (Tom, dogfood 2026-09-07).
                    .foregroundStyle(
                        focusedID == entry.id
                            ? AnyShapeStyle(hoverTextFill)
                            : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Clicks go through to the band behind it, which closes
                    // the note — the quote is part of the band, not a control.
                    .allowsHitTesting(false)

                labelRow(entry)
            }

            HStack(alignment: .top, spacing: 6) {
                if editingID == entry.id {
                    // `N11 274:912` draws the field as a **frame** — a 256×56
                    // box with its input inset (6, 4) — and the number sits
                    // *inside* it, which the render confirms: the box reads
                    // `1.  Does this hold when…`.
                    //
                    // The box belongs here rather than beside the `TextField`,
                    // because it is chrome the manifest owns. Put on the
                    // control instead, it was invisible to the render check
                    // that is supposed to catch exactly this (Tom, dogfood
                    // 2026-09-06: *"the box background should be white"*).
                    HStack(alignment: .top, spacing: 6) {
                        // The editing row keeps its number: the numeral is the
                        // only thing tying an open field to its marker in the
                        // message, and edit time is when that link is
                        // load-bearing.
                        Text("\(entry.number).")
                            .font(.system(size: ReplyFooterMetrics.rowFontSize, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        field(entry)
                    }
                    .padding(.horizontal, ReplyFooterMetrics.fieldInset.horizontal)
                    .padding(.vertical, ReplyFooterMetrics.fieldInset.vertical)
                    .background(RoundedRectangle(cornerRadius: 4).fill(fieldFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    )
                } else {
                    // Never truncated. The list is a manifest of what Paste
                    // will send, and a row showing less than it sends defeats
                    // the footer's one job.
                    Text(text(for: entry, hovered: focusedID == entry.id))
                        .font(.system(size: ReplyFooterMetrics.rowFontSize))
                        .foregroundStyle(
                            focusedID == entry.id
                                ? AnyShapeStyle(hoverTextFill)
                                : AnyShapeStyle(entry.note.isEmpty ? .tertiary : .primary)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onBeginEditing(entry) }
                }

                removeButton(entry, isEditing: editingID == entry.id)
            }
        }
        // No row-1 special case: the `✕` column is held on every row, and it
        // already stops the text short of the glyph.
        .background(
            // Outside the flow. `N3 102:919` grows the hovered row from 12pt
            // to 18 and pushes everything below it down by six; rows that move
            // under the pointer cost more than the band is worth.
            RoundedRectangle(cornerRadius: 3)
                .fill(focusedID == entry.id ? hoverFill : .clear)
                .padding(.vertical, -ReplyFooterMetrics.hoverPadding)
                .padding(.horizontal, -ReplyFooterMetrics.hoverInset)
                // While the note is open, a click on the band itself — the
                // quote, the padding, the gaps between chips — closes it. The
                // chips, `⌄`, field and `✕` sit above the band and take their
                // own clicks first.
                .contentShape(RoundedRectangle(cornerRadius: 3))
                .onTapGesture { if editingID == entry.id { onCloseEditing() } }
                .allowsHitTesting(editingID == entry.id)
        )
        .onHover { hoveredID = $0 ? entry.id : (hoveredID == entry.id ? nil : hoveredID) }
    }

    /// The quote as one flowing run, so truncation can say it was truncated.
    ///
    /// **Why collapsing is the fix and a longer `lineLimit` is not.** The
    /// quote is markdown now, so it arrives with real newlines — blank lines
    /// between blocks, fences, list breaks. SwiftUI truncates per *line*, so
    /// a quote whose first two lines are short (`"` then a heading) fits
    /// them both, overflows nothing, and silently drops everything after
    /// with **no ellipsis at all**. That is what Tom saw: an opening quote
    /// mark, one short line, and no sign the rest existed.
    ///
    /// Flattened to a single run, the same two lines overflow honestly and
    /// `.truncationMode(.tail)` appends the ellipsis itself — so the mark
    /// comes from the layout that actually did the cutting, rather than from
    /// a character budget guessing at the panel's width.
    private func displayQuote(_ quote: String) -> String {
        quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `n.  note` as one run, so a wrapped line returns to the gutter.
    /// `N9 138:1311` draws a four-line note as a single 256-wide text, not a
    /// hanging indent under a separate number column.
    private func text(for entry: NumberedAnnotation, hovered: Bool) -> AttributedString {
        var marker = AttributedString("\(entry.number).  ")
        // The numeral tracks the fill it sits on, not the page — the same
        // rule the page's numeral follows inside an active mark.
        marker.foregroundColor = hovered ? hoverTextFill : .secondary
        return marker + AttributedString(entry.note.isEmpty ? placeholder : entry.note)
    }

    /// The quick labels above an open note — `cm-69.3`, `N5`.
    ///
    /// As many chips as fit the row, in order. The `⌄` beside them is always
    /// present, and since `cm-83.3` it holds **every** label rather than only
    /// the ones the chips left out — so the chips are a shortcut to a subset,
    /// not a partition. The way into editing them is in there too.
    /// The count follows the panel's width (Tom, 2026-09-11:
    /// *"we should just fit as many that fit horizontally"*) — it was a fixed
    /// three, which wasted a wide panel and forced Settings to explain which
    /// labels were chips. One row that never wraps: the list is the user's,
    /// so wrapping would grow the footer with every label they add.
    ///
    /// `ViewThatFits` tries the row with every label as a chip, then one
    /// fewer, down to none, and shows the first that fits — no measuring.
    /// It instantiates this row once per candidate, so anything captured in
    /// here is captured `labels.count + 1` times; see `ReplyMenuAnchorBox`.
    ///
    /// **Never focusable.** A chip that took focus on click would pull the
    /// keyboard out of the note field it is writing into — the one thing a
    /// label must not do (Full Keyboard Access lets plain buttons take focus).
    private func labelRow(_ entry: NumberedAnnotation) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach((0...labels.count).reversed(), id: \.self) { shown in
                labelLine(entry, chips: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One candidate row: the first `chips` labels as chips, the rest in `⌄`.
    private func labelLine(_ entry: NumberedAnnotation, chips: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.prefix(chips).enumerated()), id: \.offset) { _, label in
                Button {
                    onApplyLabel(entry, label)
                } label: {
                    Text(verbatim: label)
                        .font(.system(size: ReplyFooterMetrics.rowFontSize))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(chipFill))
                        .replyHoverHighlight(cornerRadius: 4)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(Text(verbatim: label))
            }
            // `#cm-83.3`: one AppKit menu, opened by this click and by `⌥0`.
            // A SwiftUI `Menu` cannot be opened from code, and two menus would
            // drift apart — so the click loses its SwiftUI menu rather than the
            // keyboard gaining a second one.
            Button {
                onOpenLabelMenu(entry)
            } label: {
                // Padding and fill live INSIDE the label, exactly as the chips
                // above do. Outside `.buttonStyle(.plain)` they are not part of
                // the control, so the button would listen only on the 8pt glyph
                // while painting a chip-sized target — `#cm-85`'s defect, in a
                // control that never had it until this rework.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(chipFill))
                    .replyHoverHighlight(cornerRadius: 4)
            }
            .buttonStyle(.plain)
            .background(ReplyMenuAnchor(box: labelMenuAnchorBox).frame(width: 0, height: 0))
            .focusable(false)
            .accessibilityLabel(String(localized: "reply.labels.more", defaultValue: "More labels"))
        }
    }

    /// The chips' ground — the note field's own fill, lightened.
    ///
    /// The chips only ever appear in the open row, which carries the focused
    /// band (`#cm-86`'s iris). A neutral grey tint disappeared into it (Tom,
    /// dogfood 2026-09-10: *"they blend in too much"*); the field's material
    /// at partial alpha reads as a small light button on the band, and as the
    /// same family as the field right below it, in either appearance.
    private var chipFill: Color { fieldFill.opacity(0.6) }

    private func removeButton(_ entry: NumberedAnnotation, isEditing: Bool) -> some View {
        Button {
            // Takes its note and its mark and nothing else — no cascade, no
            // clearing of the whole-message block. That is the condition that
            // makes no-undo defensible.
            onRemove(entry.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    focusedID == entry.id
                        ? AnyShapeStyle(hoverTextFill)
                        : AnyShapeStyle(.secondary)
                )
        }
        .buttonStyle(.plain)
        // Centred on the row's first line, not pinned to its top.
        //
        // The `HStack` is `.top` so the `✕` stays on line one when a note
        // wraps — but `.top` aligns the glyph's own box, which is shorter
        // than the text's, so it sat high in the row (Tom, dogfood
        // 2026-09-06: *"the `x` is top vertically aligned instead of
        // centered vertically"*). Giving it the line's height first, and
        // centring inside that, keeps both true at once.
        .frame(height: ReplyFooterMetrics.rowLineHeight, alignment: .center)
        // ...and when the row is a *box*, that line starts below the box's
        // own top inset. Centring on the box's full height would be right at
        // one line and wrong at eight — the field grows to `lineLimit(1...8)`
        // — so the glyph tracks the field's **first line**, which is the same
        // rule a wrapped note already follows (Tom, dogfood 2026-09-06:
        // *"the `x` is still top aligned with the text box"*).
        .padding(.top, isEditing ? ReplyFooterMetrics.fieldInset.vertical : 0)
        // Not the `⤢`'s column — see `ReplyFooterMetrics.removeInset`.
        .padding(.trailing, ReplyFooterMetrics.removeInset)
        .accessibilityLabel(
            String(localized: "reply.annotation.remove", defaultValue: "Remove highlight")
        )
        .opacity(hoveredID == entry.id ? 1 : 0)
    }

    private var previewButton: some View {
        Button(action: onPreview) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        // `(258, 9)`, 8×12, in all seven frames. Height is the row's line box;
        // the width is the glyph's own, so its right edge lands on the 10pt
        // gutter at 266 rather than in the middle of a wider column.
        .frame(height: 12, alignment: .trailing)
        .accessibilityLabel(
            String(localized: "reply.annotation.preview", defaultValue: "Show what will be pasted")
        )
    }
}

/// A pointer-over tint for the Reply panel's own buttons — the label chips and
/// Paste / Paste & Send.
///
/// macOS buttons do not change on hover, and on the chips' light ground that
/// left nothing saying *this is clickable* until the press (Tom, dogfood
/// 2026-09-11). One primary-colour wash reads in both appearances and on any
/// fill: it darkens a light chip or the blue Paste, and lightens in Dark Mode.
/// Off while the button is disabled, so a greyed Paste & Send stays inert.
private struct ReplyHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(hovered && isEnabled ? 0.1 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovered = $0 }
    }
}

extension View {
    func replyHoverHighlight(cornerRadius: CGFloat) -> some View {
        modifier(ReplyHoverHighlight(cornerRadius: cornerRadius))
    }
}

// MARK: - Starting a reply from the terminal (`#cm-89`)

/// What the terminal knows when a mouse button comes up, for `#cm-89`'s
/// `⌘⇧`-drag. Gathered by the release hook, judged by ``TerminalReplyStart``.
struct TerminalReplyStartInput: Equatable {
    /// Device-independent flags as the event reported them. The decision
    /// ignores Caps Lock, the numeric pad and the function key itself.
    let modifiers: NSEvent.ModifierFlags
    /// The pane has a **live** agent session — deliberately narrower than the
    /// Reply panel's own live-or-most-recent rule, because sending into a pane
    /// whose agent has exited types into whatever owns it now.
    let isAgentPane: Bool
    /// Ghostty's selection text, `nil` when there is no selection.
    let selectionText: String?
    /// The pointer moved between press and release. `⇧`-click *extends* a
    /// selection already on screen (`ghostty/src/Surface.zig:5578-5606`), and
    /// the gesture leaves its selection visible, so without this a later
    /// `⌘⇧`-click would read that selection and fire again.
    let didDrag: Bool
    /// The sidebar is visible **and** showing Reply. Hidden, or showing Files,
    /// counts as closed.
    let sidebarShowingReply: Bool
    let sourcePanelID: UUID
}

/// A request the Reply view consumes once. `seq` makes a second request for
/// the same text still arrive.
struct TerminalReplyRequest: Equatable {
    let seq: Int
    /// The selection, trimmed of surrounding whitespace.
    let text: String
    /// The trimmed text contains a line break. Claude Code writes a real
    /// newline where its text wraps (measured 2026-09-13), so this is the
    /// visible "more than one row" there. Multi-row still opens the panel —
    /// with a line saying why nothing was highlighted — so it rides in the
    /// request rather than refusing here.
    let isMultiRow: Bool
    let sourcePanelID: UUID
}

enum TerminalReplyStartDecision: Equatable {
    enum Reason: Equatable {
        case wrongModifiers
        case noDrag
        case notAgentPane
        case noSelection
        case blankSelection
        case panelShowing
    }

    case ignore(Reason)
    case open(TerminalReplyRequest)
}

/// Whether a mouse release in a terminal starts a reply.
///
/// Ordered cheapest and most common first, because the release hook runs this
/// only after its own flags check: an exact-modifier test, then whether the
/// pointer moved, then the pane, then the selection, then the panel. Every
/// other release in every pane leaves as `.wrongModifiers`.
enum TerminalReplyStart {
    static func decide(_ input: TerminalReplyStartInput, seq: Int) -> TerminalReplyStartDecision {
        let relevant = input.modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard relevant == [.command, .shift] else { return .ignore(.wrongModifiers) }
        guard input.didDrag else { return .ignore(.noDrag) }
        guard input.isAgentPane else { return .ignore(.notAgentPane) }
        guard let raw = input.selectionText else { return .ignore(.noSelection) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignore(.blankSelection) }
        guard !input.sidebarShowingReply else { return .ignore(.panelShowing) }
        return .open(TerminalReplyRequest(
            seq: seq,
            text: text,
            isMultiRow: text.contains(where: \.isNewline),
            sourcePanelID: input.sourcePanelID
        ))
    }
}

/// Why a terminal request opened the panel but highlighted nothing. Each one
/// stands in for the header title until the user acts.
enum TerminalReplyNotice: Equatable {
    case notFound
    case multiRow
    case writing
}

enum TerminalReplyConsumeDecision: Equatable {
    /// Open, add nothing, say nothing: the reader is on an older reply, or the
    /// newest already carries highlights. Both are a reply in progress.
    case silent
    case notice(TerminalReplyNotice)
    case find(String)
}

/// What the Reply view does with a request, once the panel is showing.
///
/// **Nothing here moves the reader.** A panel held on an older reply stays
/// there (`#cm-69`: moving the reader off a reply they are working on is what
/// the panel refuses to do), so that check runs first — before highlights,
/// and before the two notices, which would otherwise describe a message the
/// reader is not looking at.
enum TerminalReplyConsume {
    static func decide(
        viewingOlderReply: Bool,
        newestHasHighlights: Bool,
        newestTurnWriting: Bool,
        isMultiRow: Bool,
        text: String
    ) -> TerminalReplyConsumeDecision {
        if viewingOlderReply { return .silent }
        if newestHasHighlights { return .silent }
        if newestTurnWriting { return .notice(.writing) }
        if isMultiRow { return .notice(.multiRow) }
        return .find(text)
    }
}
