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
    /// Opens Settings on the Reply section.
    var onEditLabels: () -> Void = {}
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
    /// As many chips as fit the row, in order; the rest, and the way into
    /// editing them, sit behind `⌄`, which is always present because it holds
    /// that way in. The count follows the panel's width (Tom, 2026-09-11:
    /// *"we should just fit as many that fit horizontally"*) — it was a fixed
    /// three, which wasted a wide panel and forced Settings to explain which
    /// labels were chips. One row that never wraps: the list is the user's,
    /// so wrapping would grow the footer with every label they add.
    ///
    /// `ViewThatFits` tries the row with every label as a chip, then one
    /// fewer, down to none, and shows the first that fits — no measuring, and
    /// the menu always holds exactly the labels the chips left out.
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
            Menu {
                ForEach(Array(labels.dropFirst(chips).enumerated()), id: \.offset) { _, label in
                    Button(label) { onApplyLabel(entry, label) }
                }
                if labels.count > chips { Divider() }
                Button(String(localized: "reply.labels.editLabels", defaultValue: "Edit labels…")) {
                    onEditLabels()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .focusable(false)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(chipFill))
            .replyHoverHighlight(cornerRadius: 4)
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
