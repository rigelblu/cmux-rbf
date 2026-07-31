import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Rasterizes the backdrop view and checks which way up the image lands.
///
/// The rest of the backdrop suite tests `destinationRect`, which is pure
/// geometry and was correct while every backdrop image rendered upside down.
/// Orientation is only observable in pixels, so these tests draw some.
@MainActor
@Suite struct TerminalBackdropImageOrientationTests {
    /// Writes a PNG whose top half is red and bottom half is blue.
    ///
    /// The filename is unique per call because `TerminalBackdropImageLayerView`
    /// caches decoded images by path in a static cache that outlives one test.
    private func makeTwoToneImageURL(
        id: String,
        size: Int = 16
    ) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        // Fill through a graphics context rather than `setColor(atX:y:)`,
        // which silently produced a fully transparent image here.
        //
        // A context made from a bitmap rep is bottom-up, so the image's top
        // half is the upper half in these coordinates.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let half = CGFloat(size) / 2
        NSColor.red.setFill()
        CGRect(x: 0, y: half, width: CGFloat(size), height: half).fill()
        NSColor.blue.setFill()
        CGRect(x: 0, y: 0, width: CGFloat(size), height: half).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backdrop-orientation-\(id).png")
        try data.write(to: url)
        return url
    }

    /// Rasterizes the backdrop view.
    ///
    /// The view must be hosted in a window: `cacheDisplay(in:to:)` on a
    /// detached view yields a fully transparent buffer, which reads as a
    /// colour mismatch rather than as "nothing drew."
    private func render(
        url: URL,
        size: CGFloat,
        fit: TerminalBackdropImage.Fit,
        position: TerminalBackdropImage.Position = .centerCenter,
        repeats: Bool = false
    ) throws -> NSBitmapImageRep {
        let frame = CGRect(x: 0, y: 0, width: size, height: size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = TerminalBackdropImageLayerView(frame: frame)
        view.backdropImage = TerminalBackdropImage(
            url: url,
            fit: fit,
            position: position,
            opacity: 1.0,
            repeats: repeats
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // Guard the harness itself: an empty buffer must not read as a
        // wrong-colour failure.
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        #expect(center.alphaComponent > 0.9, "nothing rendered — the harness is broken, not the view")

        return rep
    }

    /// The colour at a fractional height, 0 being the top of the view.
    private func color(
        in rep: NSBitmapImageRep,
        atVerticalFraction fraction: CGFloat
    ) throws -> NSColor {
        let y = Int(CGFloat(rep.pixelsHigh - 1) * fraction)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y))
        return try #require(color.usingColorSpace(.deviceRGB))
    }

    /// Proves the fixture before it is used as an oracle. If this fails, the
    /// two-tone PNG is wrong and every other assertion here is meaningless.
    @Test func fixtureImageHasARedTopAndABlueBottom() throws {
        let url = try makeTwoToneImageURL(id: "fixture")
        let loaded = try #require(NSImage(contentsOf: url))
        let tiff = try #require(loaded.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))

        let top = try #require(rep.colorAt(x: 8, y: 1)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(rep.colorAt(x: 8, y: 14)?.usingColorSpace(.deviceRGB))

        #expect(top.redComponent > 0.8)
        #expect(bottom.blueComponent > 0.8)
    }

    /// The bug Tom caught by looking at it: a dawn-city backdrop rendered with
    /// its skyline at the top and its sky at the bottom.
    ///
    /// The view is `isFlipped` so the renderer's top-down offset math carries
    /// over unchanged, and `NSImage.draw(in:from:operation:fraction:)` positions
    /// correctly in a flipped context but mirrors the content vertically.
    @Test func imageDrawsUprightInTheFlippedBackdropView() throws {
        let url = try makeTwoToneImageURL(id: "upright")
        let rep = try render(url: url, size: 64, fit: .stretch)

        let top = try color(in: rep, atVerticalFraction: 0.15)
        let bottom = try color(in: rep, atVerticalFraction: 0.85)

        #expect(top.redComponent > 0.8, "top of the view should be the image's red top half")
        #expect(top.blueComponent < 0.2)
        #expect(bottom.blueComponent > 0.8, "bottom of the view should be the image's blue bottom half")
        #expect(bottom.redComponent < 0.2)
    }

    /// The tiled path draws through the same helper and must not diverge.
    @Test func tiledImageAlsoDrawsUpright() throws {
        let url = try makeTwoToneImageURL(id: "tiled")

        let rep = try render(
            url: url,
            size: 32,
            fit: .none,
            position: .topLeft,
            repeats: true
        )

        // Two 16pt tiles stacked in a 32pt view. Sample by fraction, never by
        // pixel row: the rep is allocated at the backing scale, so hardcoded
        // rows land in the wrong band on a Retina display.
        //
        // Each tile is red over blue, so down the view: red, blue, red, blue.
        // Checking both tiles proves the repeat re-anchors upright rather than
        // mirroring on alternate rows.
        let firstTileTop = try color(in: rep, atVerticalFraction: 0.12)
        let firstTileBottom = try color(in: rep, atVerticalFraction: 0.37)
        let secondTileTop = try color(in: rep, atVerticalFraction: 0.62)
        let secondTileBottom = try color(in: rep, atVerticalFraction: 0.87)

        #expect(firstTileTop.redComponent > 0.8, "tile 1 top should be the image's red top")
        #expect(firstTileBottom.blueComponent > 0.8, "tile 1 bottom should be the image's blue bottom")
        #expect(secondTileTop.redComponent > 0.8, "tile 2 top should be the image's red top")
        #expect(secondTileBottom.blueComponent > 0.8, "tile 2 bottom should be the image's blue bottom")
    }
}
