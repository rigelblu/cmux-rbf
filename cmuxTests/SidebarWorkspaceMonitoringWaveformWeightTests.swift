import AppKit
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.6 (Scenario 93, review row 248): the SwiftUI waveform is bold, like the AppKit one. `.resizable()` with `.font` made
/// the symbol fill its box at one weight, so the two renderers drew different waveforms.
@MainActor
@Suite("Monitoring waveform weight")
struct SidebarWorkspaceMonitoringWaveformWeightTests {
    private func coverage(of bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 { count += 1 }
        }
        return count
    }

    /// The production SwiftUI view at 12 pt, into a 2x bitmap.
    private func swiftUICoverage() throws -> Int {
        let renderer = ImageRenderer(content: SidebarWorkspaceMonitoringWaveform(side: 12, color: .white).frame(width: 20, height: 20))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return coverage(of: bitmap)
    }

    /// The AppKit mark's image, configured as `updateAgentMark` configures it and scaled proportionally down into 12 pt, at 2x.
    private func appKitCoverage(weight: NSFont.Weight) throws -> Int {
        let symbol = try #require(NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil))
        let image = try #require(symbol.withSymbolConfiguration(.init(pointSize: 12, weight: weight)))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = saved }
        let box: CGFloat = 24 // 12 pt at 2x
        let scale = min(1, box / max(image.size.width * 2, image.size.height * 2))
        let size = NSSize(width: image.size.width * 2 * scale, height: image.size.height * 2 * scale)
        image.draw(in: NSRect(x: (40 - size.width) / 2, y: (40 - size.height) / 2, width: size.width, height: size.height))
        return coverage(of: rep)
    }

    @Test func boldCoversMoreThanRegularInTheAppKitImage() throws {
        #expect(try appKitCoverage(weight: .bold) > appKitCoverage(weight: .regular), "control: the instrument tells the weights apart")
    }

    @Test func theSwiftUIWaveformIsBold() throws {
        let swiftUI = try swiftUICoverage()
        let regular = try appKitCoverage(weight: .regular)
        let bold = try appKitCoverage(weight: .bold)
        #expect(swiftUI > regular, "SwiftUI covers \(swiftUI) pixels, a regular-weight symbol \(regular)")
        #expect(abs(Double(swiftUI - bold)) / Double(bold) <= 0.05, "SwiftUI \(swiftUI) against AppKit bold \(bold)")
    }
}
