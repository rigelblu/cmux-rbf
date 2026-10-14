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

    // MARK: - `cm-73.9`: the header button's outline icon

    /// Figma's outline icon as pasted in `14_design-technical-system.md`
    /// (`cm-73-feat-steer-figma-designs-in-a-cmux-pane`), whose file is 1,608
    /// bytes with sha256 c759da483f0f430a7a4afe29de55a6804d4598601e54234c805c87f396d81376.
    /// This is its one path's data, character for character; the test carries it
    /// because it cannot read a file outside the repo.
    private static let figmasOutlinePathData =
        "M354.969 546.036C324.285 526.042 304 491.426 304 452.071C304 390.176 354.176 340 416.071 340H608.085C669.98 340 720.156 390.176 720.156 452.071C720.156 491.426 699.872 526.042 669.187 546.036C699.872 566.03 720.156 600.647 720.156 640.001C720.156 701.896 669.98 752.072 608.085 752.072H606.042C576.784 752.072 550.144 740.86 530.185 722.498V826.907C530.185 889.494 478.911 940 416.579 940C354.811 940 304 889.951 304 827.929C304 788.575 324.284 753.959 354.967 733.965C324.284 713.971 304 679.355 304 640.001C304 600.647 324.285 566.03 354.969 546.036ZM530.185 640.001C530.185 681.896 564.148 715.858 606.042 715.858H608.085C649.98 715.858 683.942 681.896 683.942 640.001C683.942 598.106 649.98 564.144 608.085 564.144H606.042C564.148 564.144 530.185 598.106 530.185 640.001ZM493.971 564.144H416.071C374.176 564.144 340.214 598.106 340.214 640.001C340.214 681.811 374.039 715.72 415.816 715.858L415.935 715.858L493.971 715.858V564.144ZM416.071 752.072C415.986 752.072 415.901 752.072 415.816 752.072C374.039 752.209 340.214 786.119 340.214 827.929C340.214 869.697 374.557 903.786 416.579 903.786C459.165 903.786 493.971 869.24 493.971 826.907V752.072H416.071ZM493.971 527.928H416.071C374.176 527.928 340.214 493.966 340.214 452.071C340.214 410.176 374.176 376.214 416.071 376.214H493.971V527.928ZM608.085 527.928H530.185V376.214H608.085C649.98 376.214 683.942 410.176 683.942 452.071C683.942 493.966 649.98 527.928 608.085 527.928Z"

    /// The bytes the header button is given, through the same route the header's
    /// own list takes: the default icon of the built-in, as a Bonsplit icon. For a
    /// button listed by a project's own `cmux.json` the route must give the same bytes.
    private func handedBytes(configSourcePath: String? = nil) throws -> Data {
        let icon = CmuxSurfaceTabBarButtonAction.builtIn(.newFigma).defaultButtonIcon
        let handed = icon.bonsplitIcon(
            configSourcePath: configSourcePath,
            globalConfigPath: "/tmp/cmux-test-global/cmux.json"
        )
        guard case .imageData(let data) = handed else {
            Issue.record("the button's icon is not image data: \(handed)")
            throw ShippedIconMissing()
        }
        return data
    }

    private struct ShippedIconMissing: Error {}

    @Test("outlineIconDrawsSomething: the bytes the header button is given decode, and drawn they leave pixels")
    func outlineIconDrawsSomething() throws {
        let data = try handedBytes()
        let image = try #require(NSImage(data: data))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 28, height: 28))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try #require(rep.bitmapData)
        var drawn = 0
        for y in 0..<28 {
            for x in 0..<28 where bytes[y * rep.bytesPerRow + x * 4 + 3] != 0 { drawn += 1 }
        }
        // An image that decodes and has nothing in it would pass the decode alone.
        #expect(drawn > 20, "the outline covers some of 784 pixels, found \(drawn)")
    }

    @Test("outlineIconIsATemplate: <svg and currentcolor within the first 4,096 bytes, which is the header's whole test for tinting")
    func outlineIconIsATemplate() throws {
        for source in [nil, "/tmp/some-project/.cmux/cmux.json"] as [String?] {
            let data = try handedBytes(configSourcePath: source)
            let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            #expect(text.contains("<svg") && text.contains("currentcolor"), "config source \(source ?? "none")")
        }
    }

    @Test("outlineIconKeepsFigmasPath: the shipped file's path data is Figma's, character for character, on the viewBox 304 340 416.156 600")
    func outlineIconKeepsFigmasPath() throws {
        let text = String(decoding: try handedBytes(), as: UTF8.self)
        #expect(text.contains("d=\"\(Self.figmasOutlinePathData)\""))
        #expect(text.contains("viewBox=\"304 340 416.156 600\""))
        #expect(text.components(separatedBy: "<path").count == 2, "one path")
    }

    @Test("aProjectCannotReachAnotherPath: a project's cmux.json still gets no other absolute path, a file beside the shipped one included")
    func aProjectCannotReachAnotherPath() throws {
        let project = "/tmp/some-project/.cmux/cmux.json"
        let shipped = try #require(FigmaButtonIcon.shippedPath)
        let beside = ((shipped as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Info.plist")
        for path in ["/etc/hosts", beside, shipped + "x", (shipped as NSString).deletingLastPathComponent] {
            let handed = CmuxButtonIcon.imagePath(path).bonsplitIcon(
                configSourcePath: project,
                globalConfigPath: "/tmp/cmux-test-global/cmux.json"
            )
            guard case .systemImage = handed else {
                Issue.record("\(path) was handed to a project's button as \(handed)")
                continue
            }
        }
        // And the shipped path itself is not refused for it.
        let own = CmuxButtonIcon.imagePath(shipped).bonsplitIcon(
            configSourcePath: project,
            globalConfigPath: "/tmp/cmux-test-global/cmux.json"
        )
        guard case .imageData = own else {
            Issue.record("the shipped path was refused for a project's button: \(own)")
            return
        }
        // A project's button is not trusted with its own images, and the app's image is not the project's.
        let untrusted = CmuxButtonIcon.imagePath(shipped).bonsplitIcon(
            configSourcePath: project,
            globalConfigPath: "/tmp/cmux-test-global/cmux.json",
            allowProjectLocalImage: false
        )
        guard case .imageData = untrusted else {
            Issue.record("the shipped path was locked for an untrusted project's button: \(untrusted)")
            return
        }
    }

    @Test("menuRowTakesTheMenusColour: the plus-menu row draws the shipped icon as a template, and a picture file is not one")
    func menuRowTakesTheMenusColour() throws {
        let shipped = try #require(FigmaButtonIcon.shippedPath)
        let icon = CmuxButtonIcon.imagePath(shipped)
        let row = try #require(icon.contextMenuImage(configSourcePath: nil, globalConfigPath: "/tmp/cmux-test-global/cmux.json"))
        #expect(row.isTemplate, "currentColor would draw black on a dark menu")

        // An image that is not SVG text stays as it is.
        let png = FigmaTabMark.shippedPicture
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-menu-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mark.png")
        try png.write(to: file)
        let plain = try #require(CmuxButtonIcon.imagePath(file.path).contextMenuImage(
            configSourcePath: nil, globalConfigPath: "/tmp/cmux-test-global/cmux.json"
        ))
        #expect(!plain.isTemplate)
    }
}
