import AppKit
import CmuxAgentChat
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Renders the reply footer's manifest and measures it, because every other
/// check on this slice can pass while the screen is wrong.
///
/// **Why this exists.** The `⤢` shipped in the wrong place twice. Both times
/// the position was derived by arithmetic from a companion brief's *sentence*
/// about the geometry (`N11`: *"aligned to the first content row's line"*),
/// and both times the build was green, the package suite was green, the app
/// suite was green, three lints passed, and the glyph was visibly wrong. None
/// of those checks look at pixels.
///
/// So this one does. It writes a PNG next to the Figma frame's own export so
/// the two can be put side by side, and it asserts the one number a render can
/// settle that prose cannot: where the glyph's ink actually lands.
///
/// Set `CMUX_RENDER_DIR` to keep the PNGs somewhere you can open them;
/// otherwise they go to a temporary directory whose path the test prints.
@MainActor
@Suite("Reply footer manifest — rendered")
struct ReplyAnnotationManifestRenderTests {
    /// The sidebar's width, and the width every frame is drawn at.
    static let panelWidth: CGFloat = 276

    /// `N1 154:1404`, `N2 154:1403`, `N3 284:902`, `N9 284:906`,
    /// `N10 284:907`, `N11 274:918`, `L5 284:901` — all seven agree.
    static let glyphBox = (minX: CGFloat(258), maxX: CGFloat(266), height: CGFloat(12))

    /// The manifest's own origin is the footer's content origin, so the first
    /// line sits at y=0 here and at y=9 once the footer adds its top inset.
    static let firstLineHeight: CGFloat = 12

    /// The shipped wash itself, no longer a stand-in.
    ///
    /// This was a hard-coded violet because the real colour was derived from
    /// `NSColor.controlAccentColor` and therefore differed per machine — a
    /// render check that varied with the tester's System Settings would have
    /// been no check at all. Fixing the hue (2026-09-06) removed the reason
    /// for the stand-in, so the render now draws what ships.
    ///
    /// Still light enough at 28% that the ink scans below read the glyph and
    /// not the band, which is what lets the geometry tests run on a hovered
    /// row at all.
    static var hoverWash: NSColor { MarkdownWebTheme.hoveredMarkFill(isDark: false) }

    /// Where the note list starts, below the header.
    ///
    /// The count-plus-`⤢` header is on **every** footer now, not just `N10`,
    /// so the first note row sits one line lower than these bands used to
    /// assume. Every geometry test here failed the moment that landed, which
    /// is the harness doing its job — a layout change that moves rows should
    /// not pass silently.
    static let listTop: CGFloat = 19

    /// Rows are 12pt on a 19pt pitch — `N3`, `N9`, `N10` and `L5` all agree.
    static func rowBand(_ index: Int) -> Range<CGFloat> {
        let top = listTop + CGFloat(index) * 19
        return top..<(top + firstLineHeight)
    }

    @Test("The ⤢ lands in the column all seven frames draw it in")
    func expandGlyphSitsInItsColumn() throws {
        let image = try render(Self.sample(), editing: nil, hovering: nil)
        try write(image, named: "manifest-committed")

        let ink = try expandInk(in: image, band: 0..<Self.firstLineHeight)
        // Right edge on the 10pt gutter, not the centre of a wider column —
        // the invented 14pt shared column put it about three points left.
        #expect(ink.maxX <= Self.glyphBox.maxX)
        #expect(ink.maxX >= Self.glyphBox.maxX - 3)
    }

    /// Tom, dogfood, 2026-09-06: *"the `x` is still misaligned on highlighted
    /// not currently being edited/selected"*.
    ///
    /// Row 1 reserves the `⤢`'s column by padding **the whole row**, which
    /// takes the `✕` with it. So the `✕` sits at one x on row 1 and a
    /// different x on every row below, and the glyph jumps as the pointer
    /// moves down the list. A column that moves is not a column.
    @Test("The ✕ holds one column on every row, row 1 included")
    func removeGlyphDoesNotMoveBetweenRows() throws {
        let set = Self.sample()
        let rows = set.numbered
        let first = try #require(rows.first)
        let second = try #require(rows.dropFirst().first)

        let one = try render(set, editing: nil, hovering: first.id)
        let two = try render(set, editing: nil, hovering: second.id)
        try write(one, named: "manifest-hover-row1")
        try write(two, named: "manifest-hover-row2")

        let inkOne = try removeInk(in: one, band: Self.rowBand(0))
        let inkTwo = try removeInk(in: two, band: Self.rowBand(1))

        #expect(abs(inkOne.maxX - inkTwo.maxX) <= 1)
        // And it clears the glyph's column rather than tucking under it:
        // `N3 102:920` puts the `✕` at 251–260 and the `⤢` at 258–266, and no
        // frame ever draws both at once.
        #expect(inkOne.maxX <= Self.glyphBox.minX)
    }

    /// Tom, dogfood, 2026-09-06: *"the `x` is top vertically aligned instead
    /// of centered vertically"*.
    ///
    /// The row's `HStack` is `.top` so the `✕` stays on line one when a note
    /// wraps to several. But `.top` aligns the glyph's **own** box, which is
    /// shorter than the text's line box, so the glyph sat high against the
    /// note beside it. Both have to be true at once: first line, centred on
    /// it.
    ///
    /// Measured against the row's *text* rather than against a number,
    /// because the number is the thing that was wrong. A constant can be
    /// typed in incorrectly; the text's own ink cannot.
    @Test("The ✕ centres on its row's text rather than sitting at its top")
    func removeGlyphCentresOnItsRow() throws {
        let set = Self.sample()
        let second = try #require(set.numbered.dropFirst().first)
        let image = try render(set, editing: nil, hovering: second.id)
        try write(image, named: "manifest-hover-row2-centring")

        // Row 2 alone: row 1's line box ends well above this, and the
        // fixture has no row 3.
        let row = (Self.listTop + 15)..<(Self.listTop + 45)

        // The **first line** of it, located from the ink rather than from a
        // row origin. Row 2's note wraps to two lines, and a band covering
        // both puts the text's centre a whole line lower — which read as the
        // glyph being 6.5pt out when the real error was 2.5. The render is
        // what showed that; the arithmetic looked fine.
        let block = scan(image, band: row, xs: 0..<150, on: Self.hoverWash)
        #expect(block.hasInk, "no note text found on row 2")
        let firstLine = block.minY..<(block.minY + ReplyFooterMetrics.rowLineHeight)

        let glyph = try removeInk(in: image, band: firstLine)
        let note = scan(image, band: firstLine, xs: 0..<150, on: Self.hoverWash)

        print(
            "row 2 first line \(firstLine) — ✕ centre \(glyph.centreY), "
                + "text centre \(note.centreY)"
        )
        // A point and a half: glyph ink and text ink are different shapes, so
        // exact equality would be asserting a coincidence. What Tom could see
        // was more than two.
        #expect(abs(glyph.centreY - note.centreY) <= 1.5)
    }

    /// Tom, dogfood, 2026-09-06: *"the `x` is still top aligned with the text
    /// box instead of centered vertically"*.
    ///
    /// **The fixture I skipped.** The previous centring test used a plain
    /// text row, where the `✕`'s sibling is one line tall and the fix worked.
    /// On an *open* row the sibling is a box — text plus its own vertical
    /// inset — so top-aligning a one-line frame against it left the glyph
    /// high by exactly that inset. A green suite described the case it
    /// happened to render.
    ///
    /// Run at one line and at three, because the two candidate rules only
    /// disagree there: centring on the box is right at one line and absurd at
    /// eight (the field grows to `lineLimit(1...8)`), while centring on the
    /// box's *first line* is right at both.
    @Test("The ✕ centres on the open field's first line, at any field height", arguments: [1, 3])
    func removeGlyphCentresOnTheOpenField(lines: Int) throws {
        let set = Self.sample()
        let first = try #require(set.numbered.first)
        let image = try render(set, editing: first.id, hovering: first.id, fieldLines: lines)
        try write(image, named: "manifest-editing-\(lines)line")

        // **Anchored on the box, never on the glyph.** Deriving the expected
        // band from where the `✕` landed would move the target with the
        // defect and pass either way. The box's accent border is independent
        // of it and is the thing the glyph is supposed to line up with.
        let boxTop = try #require(
            accentBorderTop(in: image),
            "no accent border found — the open field draws one"
        )
        let firstLine = (boxTop + ReplyFooterMetrics.fieldInset.vertical)
            ..< (boxTop + ReplyFooterMetrics.fieldInset.vertical + ReplyFooterMetrics.rowLineHeight)
        let expected = (firstLine.lowerBound + firstLine.upperBound) / 2

        // Bounded to the hovered row, found from the band's own left strip —
        // not from the glyph, and not from where I expect the glyph to be.
        // Scanning the whole image made every white pixel on the page count
        // as ink the moment "ink" started meaning *differs from the fill*.
        let glyph = try removeInk(in: image, band: try #require(hoveredRowRows(in: image)))

        print("field \(lines)-line — box top \(boxTop), first line \(firstLine), "
            + "✕ centre \(glyph.centreY), expected \(expected)")
        #expect(abs(glyph.centreY - expected) <= 1.5)
    }

    @Test("Editing an entry puts its quote above the field, not beside it")
    func quotePrecedesTheField() throws {
        let set = Self.sample()
        let first = try #require(set.numbered.first)
        let image = try render(set, editing: first.id, hovering: nil)
        try write(image, named: "manifest-editing")

        // The defect this pins: with no quote row the field became the
        // footer's first line, so the `⤢` sat beside the box instead of
        // above it. `N2 126:1001` puts the quote inside the entry, one row
        // above the field.
        // The list's first line, not the footer's — the header owns that one.
        let quote = leadingInk(
            in: image,
            band: Self.listTop..<(Self.listTop + ReplyFooterMetrics.rowLineHeight)
        )
        #expect(quote.hasInk)
        #expect(quote.maxX > Self.panelWidth / 3)
    }

    // MARK: - The hovered wash

    /// Relative luminance, WCAG's definition.
    private static func luminance(_ colour: NSColor) -> CGFloat {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The wash sits *under* a row's own text, in both appearances.
    ///
    /// **Why this is a standing test and not a one-off.** The hue used to be
    /// derived from `NSColor.controlAccentColor`, so it was a different
    /// colour on every machine and no rendered check could speak for anyone
    /// else's. Since 2026-09-06 it is a fixed iris, which makes the question
    /// answerable once — and worth answering, because the next person to
    /// change the hue or the alpha has no other way to find out they made the
    /// note unreadable.
    ///
    /// Measured on the composite (canvas, then wash, then text), never on the
    /// raw hex — the hex is the number that would mislead.
    @Test("The hovered wash keeps a row's text legible on both canvases", arguments: [false, true])
    func hoveredWashKeepsTheRowLegible(dark: Bool) throws {
        // **The mark's own ink against the mark's own fill** — not the page's
        // body colour, which stopped applying the moment the fill went
        // opaque and the mark started carrying its own text colour.
        // Measuring against the page's text was the check that would have
        // passed `#C4A7E7` with white on it at 2.1:1.
        let theme = MarkdownWebTheme.resolve(
            backgroundColor: MarkdownBackgroundStyle.solidCanvas(isDark: dark),
            style: .solid
        )
        let fill = try #require(theme.activeMarkColor.usingColorSpace(.sRGB))
        let ink = try #require(theme.onActiveMarkColor.usingColorSpace(.sRGB))
        // Opaque, so the fill *is* the composite — nothing left to blend
        // against, which is the point: the hex named is the hex on screen.
        #expect(abs(fill.alphaComponent - 1) < 0.001)
        let ratio = Self.contrast(fill, ink)

        print(String(format: "mark ink on fill (%@): %.1f:1", dark ? "dark" : "light", Double(ratio)))
        // WCAG AA for body text. `#6A1B9A` with white gives 9.4:1 — the
        // widest margin of the ten candidates tried, though the hue was
        // chosen on looks and not on this number.
        #expect(ratio >= 4.5)
    }

    /// The pick is the pick: a fixed hue, not the old machine-dependent one.
    @Test("The wash is the chosen colour, and both spellings still agree")
    func theWashIsTheChosenColour() throws {
        let theme = MarkdownWebTheme.resolve(backgroundColor: .white, style: .solid)
        let chosen = try #require(MarkdownWebTheme.hoveredMarkFill(isDark: false).usingColorSpace(.sRGB))
        let shipped = try #require(theme.activeMarkColor.usingColorSpace(.sRGB))

        #expect(abs(shipped.redComponent - chosen.redComponent) < 0.001)
        #expect(abs(shipped.greenComponent - chosen.greenComponent) < 0.001)
        #expect(abs(shipped.blueComponent - chosen.blueComponent) < 0.001)
        #expect(abs(shipped.alphaComponent - 1) < 0.001)
        // And the ink pairs with it in both spellings, same as the fill does.
        #expect(theme.onAccentHover == theme.onActiveMarkColor.markdownCSSColor)
        // And the page gets the same colour it does — see the drift guard in
        // `MarkdownBackgroundStyleTests`.
        #expect(theme.accentHover == theme.activeMarkColor.markdownCSSColor)
    }

    // MARK: - Rendering

    private func render(
        _ set: ReplyAnnotationSet,
        editing: UUID?,
        hovering: UUID?,
        fieldLines: Int = 1
    ) throws -> NSBitmapImageRep {
        var hovered: UUID? = hovering
        // Left unmeasured on purpose: under the ceiling the list is a plain
        // `VStack` that sizes to its rows, so one layout pass is enough. It
        // took two goes to get here — seeded at 0 the old measured-height
        // frame collapsed the list to 1pt, and seeded high it went down the
        // `ScrollView` branch, which `ImageRenderer` renders as blank.
        var height: CGFloat = 0
        let view = ReplyAnnotationManifest(
            entries: set.numbered,
            editingID: editing,
            hoveredID: Binding(get: { hovered }, set: { hovered = $0 }),
            placeholder: "What should change?",
            gutter: 10,
            fieldFill: .white,
            hoverFill: Color(nsColor: Self.hoverWash),
            hoverTextFill: .white,
            ceiling: 281,
            measuredHeight: Binding(get: { height }, set: { height = $0 }),
            onBeginEditing: { _ in },
            onRemove: { _ in },
            onPreview: {},
            // Only the control is stubbed. The box around it is the
            // manifest's own, so the render sees it — which is the point:
            // chrome the harness supplies is chrome the harness cannot check.
            // The real field is a `TextField(axis: .vertical)` with
            // `lineLimit(1...8)`, so the box grows as you type. The stub
            // takes a line count for the same reason: a `✕` centred on the
            // *box* is right at one line and wrong at eight, and only a
            // multi-line render can tell those two rules apart.
            field: { _ in
                Text(verbatim: Array(repeating: "Name the field", count: fieldLines)
                    .joined(separator: "\n"))
                    .font(.system(size: ReplyFooterMetrics.rowFontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .frame(width: Self.panelWidth, alignment: .topLeading)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        // Points, not backing pixels: every number in the frames is a point,
        // so a 2x render would make each assertion silently mean something
        // else.
        renderer.scale = 1
        let image = try #require(renderer.nsImage, "ImageRenderer produced nothing")
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    private func write(_ image: NSBitmapImageRep, named name: String) throws {
        let dir = ProcessInfo.processInfo.environment["CMUX_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-renders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("rendered \(image.pixelsWide)x\(image.pixelsHigh) → \(url.path)")
    }

    // MARK: - Measuring

    private struct Ink {
        var hasInk = false
        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = 0
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = 0

        var centreY: CGFloat { (minY + maxY) / 2 }
    }

    /// Ink in the `⤢`'s column, 256–276. Nothing else reaches it.
    private func expandInk(in image: NSBitmapImageRep, band: Range<CGFloat>) throws -> Ink {
        let ink = scan(image, band: band, xs: 256..<Int(Self.panelWidth))
        #expect(ink.hasInk, "no ⤢ ink on the first line")
        return ink
    }

    /// Ink in the `✕`'s column, 236–256 — deliberately short of the `⤢`'s
    /// 258, so a `✕` that has drifted under the glyph reads as absent here
    /// rather than being counted as the glyph's own ink.
    private func removeInk(in image: NSBitmapImageRep, band: Range<CGFloat>) throws -> Ink {
        // The `✕` only ever shows on a hovered row, so the fill is its
        // ground — never the page.
        let ink = scan(image, band: band, xs: 236..<256, on: Self.hoverWash)
        #expect(ink.hasInk, "no ✕ ink in its column on this row")
        return ink
    }

    /// The vertical extent of the hovered row, from the band's left strip.
    ///
    /// The band reaches `hoverInset` past the row's content, so x=7 sits
    /// inside it and outside everything the row draws — which makes it the
    /// one column that answers "is this row hovered?" and nothing else.
    private func hoveredRowRows(in image: NSBitmapImageRep) -> Range<CGFloat>? {
        var rows: [Int] = []
        for y in 0..<image.pixelsHigh {
            guard let c = image.colorAt(x: 7, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.saturationComponent > 0.25, c.brightnessComponent < 0.95 { rows.append(y) }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return CGFloat(first)..<CGFloat(last + 1)
    }

    /// The top edge of the open field's box.
    ///
    /// **Found by the box's own white fill sitting inside the hovered band,
    /// not by saturation.** Saturation worked while the hover was a 28% tint
    /// that landed near 0.17 — well under the accent stroke's 0.35. The fill
    /// became opaque `#6A1B9A` on 2026-09-07 and the band started clearing
    /// that threshold itself, so the finder locked onto the row instead of
    /// the field and the centring test went 14pt out. The test caught a real
    /// change; the anchor was the thing that had to move.
    ///
    /// Two columns settle it together: one inside the box (white) and one in
    /// the band beside it (the fill). Neither alone is enough — the sheet
    /// above the band is white too, and "not white" is satisfied by any dark
    /// glyph, which put the first attempt at y=3 on the header's own text.
    ///
    /// The band-only column is narrow by construction: it runs from the
    /// gutter less `hoverInset` (x=6) to the gutter itself (x=10), because
    /// the band reaches exactly that far past the row's content. x=7 is
    /// inside it and outside the box.
    private func accentBorderTop(in image: NSBitmapImageRep) -> CGFloat? {
        func white(_ x: Int, _ y: Int) -> Bool {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.brightnessComponent > 0.95 && c.saturationComponent < 0.1
        }
        func band(_ x: Int, _ y: Int) -> Bool {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.saturationComponent > 0.25 && c.brightnessComponent < 0.95
        }
        for y in 0..<image.pixelsHigh where band(7, y) && white(45, y) {
            return CGFloat(y)
        }
        return nil
    }

    /// Ink in the leading two thirds of a band.
    private func leadingInk(in image: NSBitmapImageRep, band: Range<CGFloat>) -> Ink {
        scan(image, band: band, xs: 0..<Int(Self.panelWidth * 2 / 3))
    }

    /// Ink is what differs from the surface it sits on — not what is dark.
    ///
    /// **This measured darkness until 2026-09-07, and the opaque fill broke
    /// it silently.** With a `#6A1B9A` band the `✕` is *white on purple*, so
    /// a "darker than 0.85" test finds the band and misses the glyph. The
    /// centring test failed loudly; `removeGlyphDoesNotMoveBetweenRows` and
    /// `removeGlyphCentresOnItsRow` kept **passing while measuring the band**,
    /// because the scan is capped at x=256 and a full band gives the same
    /// `maxX` on every row. A test that cannot fail is worse than one that
    /// does.
    private func scan(
        _ image: NSBitmapImageRep,
        band: Range<CGFloat>,
        xs: Range<Int>,
        on surface: NSColor = .white
    ) -> Ink {
        var ink = Ink()
        let top = max(0, Int(band.lowerBound))
        let bottom = min(Int(band.upperBound), image.pixelsHigh)
        guard top < bottom, let ground = surface.usingColorSpace(.sRGB) else { return ink }
        for y in top..<bottom {
            for x in xs where x < image.pixelsWide {
                guard let raw = image.colorAt(x: x, y: y),
                      let colour = raw.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.1 else { continue }
                let distance = abs(colour.redComponent - ground.redComponent)
                    + abs(colour.greenComponent - ground.greenComponent)
                    + abs(colour.blueComponent - ground.blueComponent)
                // Comfortably past antialiasing, comfortably under a glyph.
                guard distance > 0.45 else { continue }
                ink.hasInk = true
                ink.minX = min(ink.minX, CGFloat(x))
                ink.maxX = max(ink.maxX, CGFloat(x) + 1)
                ink.minY = min(ink.minY, CGFloat(y))
                ink.maxY = max(ink.maxY, CGFloat(y) + 1)
            }
        }
        return ink
    }

    // MARK: - Fixture

    private static func sample() -> ReplyAnnotationSet {
        ReplyAnnotationSet(annotations: [
            ReplyAnnotation(
                quote: "one answer is one reply",
                note: "Does this hold when the tool call is last?",
                range: 0..<23
            ),
            ReplyAnnotation(
                quote: "the hook is the clock",
                note: "Cite where that is recorded — which file?",
                range: 40..<61
            ),
        ])
    }
}
