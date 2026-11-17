import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Reply inline toolbar look", .serialized)
struct ReplyInlineToolbarLookTests {
    @Test("Style table returns exact fill, edge and label colors across appearance, state and contrast")
    func styleTableExactValues() {
        // Light
        #expect(ReplyInlineToolbarStyle.fill(for: .light, state: .rest).hex == "#E3E3E8")
        #expect(ReplyInlineToolbarStyle.fill(for: .light, state: .hover).hex == "#D3D3D8")
        #expect(ReplyInlineToolbarStyle.fill(for: .light, state: .pressed).hex == "#C4C4C9")
        #expect(ReplyInlineToolbarStyle.edge(for: .light, increaseContrast: false).hex == "#8C8C94")
        #expect(ReplyInlineToolbarStyle.edge(for: .light, increaseContrast: true).hex == "#202024")
        #expect(ReplyInlineToolbarStyle.label(for: .light).hex == "#202024")

        // Dark
        #expect(ReplyInlineToolbarStyle.fill(for: .dark, state: .rest).hex == "#4A524C")
        #expect(ReplyInlineToolbarStyle.fill(for: .dark, state: .hover).hex == "#585F58")
        #expect(ReplyInlineToolbarStyle.fill(for: .dark, state: .pressed).hex == "#656B65")
        #expect(ReplyInlineToolbarStyle.edge(for: .dark, increaseContrast: false).hex == "#7E8781")
        #expect(ReplyInlineToolbarStyle.edge(for: .dark, increaseContrast: true).hex == "#F4F1E8")
        #expect(ReplyInlineToolbarStyle.label(for: .dark).hex == "#F4F1E8")
    }

    @Test("WCAG contrast of label on each of the 6 fills meets AA (>= 4.5)")
    func wcagContrastMeetsAA() {
        let lightLabel = ReplyInlineToolbarStyle.label(for: .light)
        #expect(lightLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .light, state: .rest)) >= 4.5)
        #expect(lightLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .light, state: .hover)) >= 4.5)
        #expect(lightLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .light, state: .pressed)) >= 4.5)

        let darkLabel = ReplyInlineToolbarStyle.label(for: .dark)
        #expect(darkLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .dark, state: .rest)) >= 4.5)
        #expect(darkLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .dark, state: .hover)) >= 4.5)
        #expect(darkLabel.contrastRatio(with: ReplyInlineToolbarStyle.fill(for: .dark, state: .pressed)) >= 4.5)
    }

    @Test("View draws from style table with radius 8, shadow, and 12 pt bold font")
    func viewDrawingAndLook() throws {
        let view = ReplyInlineToolbarView(title: "Reply", accessibilityLabel: "Reply")
        view.frame = NSRect(origin: .zero, size: ReplyInlineToolbarView.size(for: "Reply"))
        view.layout()

        #expect(view.bounds.size == CGSize(width: 62, height: 28))
        #expect(ReplyInlineToolbarView.font == NSFont.systemFont(ofSize: 12, weight: .bold))

        let shadowOpacity = view.layer?.shadowOpacity ?? 0
        #expect(abs(shadowOpacity - 0.28) < 0.01)
        #expect(view.layer?.shadowRadius == 3)
        #expect(view.layer?.shadowOffset == CGSize(width: 0, height: -2))

        let appearances: [(NSAppearance.Name, ReplyInlineToolbarStyle.Appearance)] = [
            (.aqua, .light),
            (.darkAqua, .dark)
        ]

        for (appKitName, styleAppearance) in appearances {
            view.appearance = NSAppearance(named: appKitName)

            for state in [ReplyInlineToolbarStyle.State.rest, .hover, .pressed] {
                view.state = state
                let rep = try #require(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: 124,
                        pixelsHigh: 56,
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0,
                        bitsPerPixel: 0
                    )
                )
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)

                // Fill pixel left of the label, inside the edge (8 pt, 14 pt -> 2x pixel 16, 28)
                let pixelColor = try #require(rep.colorAt(x: 16, y: 28)?.usingColorSpace(.sRGB))
                let expectedRGB = ReplyInlineToolbarStyle.fill(for: styleAppearance, state: state)

                let r = Int(round(pixelColor.redComponent * 255))
                let g = Int(round(pixelColor.greenComponent * 255))
                let b = Int(round(pixelColor.blueComponent * 255))

                #expect(abs(r - Int(expectedRGB.r)) <= 2, "Red channel at \(state) \(styleAppearance): got \(r), want \(expectedRGB.r)")
                #expect(abs(g - Int(expectedRGB.g)) <= 2, "Green channel at \(state) \(styleAppearance): got \(g), want \(expectedRGB.g)")
                #expect(abs(b - Int(expectedRGB.b)) <= 2, "Blue channel at \(state) \(styleAppearance): got \(b), want \(expectedRGB.b)")

                // Corner radius 8 at 2x: pixel (4, 4) (2.25 pt) is outside, (5, 5) (2.75 pt) is on the edge, (6, 6) (3 pt) is drawn
                let outsideCorner = try #require(rep.colorAt(x: 4, y: 4))
                #expect(outsideCorner.alphaComponent < 0.2, "Pixel (4, 4) must be outside radius-8 corner")
                let edgeCorner = try #require(rep.colorAt(x: 5, y: 5))
                #expect(edgeCorner.alphaComponent > 0.5, "Pixel (5, 5) must be on radius-8 corner")
                let cornerColor = try #require(rep.colorAt(x: 6, y: 6))
                #expect(cornerColor.alphaComponent > 0.5, "Pixel (3 pt, 3 pt) must be drawn (radius 8), not transparent (capsule)")
            }
        }
    }

    @Test("Size for Reply is 62x28, 20 locales follow max(62, ceil(w)+28), long label widens")
    func sizeForLocalesAndLongLabel() {
        #expect(ReplyInlineToolbarView.size(for: "Reply") == CGSize(width: 62, height: 28))

        let localeLabels = [
            "رد", "Odgovori", "Svar", "Antworten", "Reply", "Responder",
            "Répondre", "Rispondi", "返信", "ឆ្លើយតប", "답장", "Svar",
            "Odpowiedz", "Responder", "Ответить", "ตอบกลับ", "Yanıtla",
            "Відповісти", "回复", "回覆"
        ]

        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        for label in localeLabels {
            let textW = ceil((label as NSString).size(withAttributes: [.font: font]).width)
            let expectedW = max(62, textW + 28)
            let size = ReplyInlineToolbarView.size(for: label)
            #expect(size == CGSize(width: expectedW, height: 28), "Size for \(label)")
        }

        let longLabel = "Antworten auf diese Auswahl"
        let longSize = ReplyInlineToolbarView.size(for: longLabel)
        #expect(longSize.width > 62)
        let expectedLongW = max(62, ceil((longLabel as NSString).size(withAttributes: [.font: font]).width) + 28)
        #expect(longSize == CGSize(width: expectedLongW, height: 28))
    }
}
