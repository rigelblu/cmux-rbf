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

    /// How tall the list may grow before it scrolls.
    let ceiling: CGFloat

    /// How tall the rows actually are. Written back so the list can size to
    /// its content *and* stop at the ceiling, and so the count line knows
    /// whether rows are hidden.
    @Binding var measuredHeight: CGFloat

    let onBeginEditing: (NumberedAnnotation) -> Void
    let onRemove: (UUID) -> Void
    let onPreview: () -> Void
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
    /// drew the footer over the reply. A plain `VStack` is not greedy, so
    /// under the ceiling `maxHeight` does exactly the right thing and the
    /// measurement only has to decide *which* container.
    ///
    /// It also makes the list renderable: `ImageRenderer` lays out no
    /// `ScrollView` content at all, so the first render of this view came back
    /// as a blank 276×301 with only the count line and the `⤢` on it.
    private var list: some View {
        Group {
            if atCeiling {
                ScrollView { rows }
            } else {
                rows
            }
        }
        // A proportion, not a row count: the panel is as tall as the window,
        // so "nine rows" would be right at exactly one height.
        .frame(maxHeight: ceiling, alignment: .top)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: ReplyFooterMetrics.rowGap) {
            ForEach(entries) { row($0) }
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
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(text(for: entry))
                        .font(.system(size: ReplyFooterMetrics.rowFontSize))
                        .foregroundStyle(entry.note.isEmpty ? .tertiary : .primary)
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
                .fill(hoveredID == entry.id ? hoverFill : .clear)
                .padding(.vertical, -ReplyFooterMetrics.hoverPadding)
                .padding(.horizontal, -ReplyFooterMetrics.hoverInset)
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
    private func text(for entry: NumberedAnnotation) -> AttributedString {
        var marker = AttributedString("\(entry.number).  ")
        marker.foregroundColor = .secondary
        return marker + AttributedString(entry.note.isEmpty ? placeholder : entry.note)
    }

    private func removeButton(_ entry: NumberedAnnotation, isEditing: Bool) -> some View {
        Button {
            // Takes its note and its mark and nothing else — no cascade, no
            // clearing of the whole-message block. That is the condition that
            // makes no-undo defensible.
            onRemove(entry.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
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
