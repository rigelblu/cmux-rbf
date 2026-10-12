import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The images the Figma slices ship. A missing or blank image draws nothing, and
/// no other test would notice.
@Suite("FigmaMarkAsset")
struct FigmaMarkAssetTests {

    @Test("colourMarkIsA32PixelPicture: the data the tab is handed decodes to a bitmap 32 pixels wide and 32 high, and draws")
    func colourMarkIsA32PixelPicture() throws {
        let rep = try #require(NSBitmapImageRep(data: FigmaTabMark.shippedPicture))
        // Read from the bitmap: the size in points says nothing about sharpness.
        #expect(rep.pixelsWide == 32)
        #expect(rep.pixelsHigh == 32)

        // An image that decodes and has nothing in it would pass the size alone.
        // The raw 8-bit RGBA bytes, not `colorAt`: that converts between colour
        // spaces and moves the very values this test pins.
        let bytes = try #require(rep.bitmapData)
        try #require(rep.samplesPerPixel == 4 && rep.bitsPerSample == 8)
        var opaque = 0
        var colours = Set<[Int]>()
        for y in 0..<32 {
            for x in 0..<32 {
                let pixel = bytes + y * rep.bytesPerRow + x * 4
                guard pixel[3] == 255 else { continue }
                opaque += 1
                colours.insert([Int(pixel[0]), Int(pixel[1]), Int(pixel[2])])
            }
        }
        #expect(opaque > 300, "the mark covers about 400 of 1024 pixels, found \(opaque)")
        // Figma's rule: "Never adjust the colors in the icon."
        let figmasFive: Set<[Int]> = [
            [0xF2, 0x4E, 0x1E], [0xFF, 0x72, 0x62], [0xA2, 0x59, 0xFF], [0x1A, 0xBC, 0xFE], [0x0A, 0xCF, 0x83],
        ]
        #expect(
            figmasFive.isSubset(of: colours),
            "Figma's five colours, found \(colours.sorted { $0.lexicographicallyPrecedes($1) }.map { $0.map { String($0, radix: 16) } })"
        )
    }
}
