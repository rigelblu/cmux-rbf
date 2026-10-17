import AppKit
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The status icons and the places that draw them (#cm-109.3): the one drawing function's geometry and pixels, the
/// glyph's color, the rows the pickers hand each place, and the Status menu's image. Every test passes its own list;
/// none reads `~/.config/cmux/cmux.json` or `UserDefaults.standard`. Where the glyph looks right to a person is
/// the agent scenarios' (50 to 54, 60 and 61), not these.
@MainActor
@Suite("Workspace status icon drawing", .serialized)
struct WorkspaceStatusIconDrawingTests {
    private typealias Drawing = WorkspaceStatusIconDrawing

    // MARK: - Geometry

    private func box(side: CGFloat, at origin: CGPoint = .zero) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.0001) -> Bool { abs(a - b) <= tolerance }

    /// The ring is 8 pt across at the middle of a 1 pt stroke, centered in the box, at the place's scale; the stroke
    /// does not scale.
    @Test func theRingIsEightPointsAcrossAtScaleOneAndScalesWithTheBox() {
        let places: [(CGFloat, String)] = [(9, "row"), (12, "popover and menu"), (13, "todo pane header")]
        for (side, place) in places {
            let geometry = Drawing.geometry(for: .ring, in: box(side: side, at: CGPoint(x: 3, y: 5)))
            #expect(near(geometry.scale, side / 9), "\(place)")
            #expect(near(geometry.ringRadius, 4 * side / 9), "\(place)")
            #expect(geometry.center == CGPoint(x: 3 + side / 2, y: 5 + side / 2), "\(place)")
            #expect(geometry.ringStroke == 1, "\(place)")
            #expect(geometry.dashCount == nil && geometry.pieRadius == nil && geometry.checkDisc == nil, "\(place)")
        }
    }

    /// Twelve dashes of 0.42 pt that do not scale; the gap is the circumference over twelve less the dash, so twelve
    /// fit exactly at every scale: 1.67 pt at 9 pt.
    @Test func theDottedRingIsTwelveDashesThatFitExactlyAtEveryScale() throws {
        for side in [CGFloat(9), 12, 13, 18] {
            let geometry = Drawing.geometry(for: .dottedRing, in: box(side: side))
            let on = try #require(geometry.dashOn)
            let off = try #require(geometry.dashOff)
            #expect(geometry.dashCount == 12, "side \(side)")
            #expect(on == 0.42, "side \(side): the dash does not scale")
            #expect(near(CGFloat(12) * (on + off), 2 * .pi * geometry.ringRadius, 0.0001), "side \(side)")
            #expect(geometry.dashPhase == on / 2, "side \(side): a dash is centered on 12 o'clock")
            #expect(geometry.ringStroke == 1, "side \(side)")
        }
        let atNine = Drawing.geometry(for: .dottedRing, in: box(side: 9))
        #expect(near(try #require(atNine.dashOff), 1.674, 0.001), "1.67 pt at 9 pt, where the board drew 1.68")
    }

    @Test func eachFillIsADiscOfTwoAndAHalfPointsFilledFromTwelveOClock() throws {
        let fills: [(WorkspaceStatusIcon, Double)] = [(.quarter, 0.25), (.half, 0.5), (.threeQuarters, 0.75), (.full, 1)]
        for (icon, fraction) in fills {
            for side in [CGFloat(9), 12, 13] {
                let geometry = Drawing.geometry(for: icon, in: box(side: side))
                #expect(near(try #require(geometry.pieRadius), 2.5 * side / 9), "\(icon) at \(side)")
                #expect(geometry.pieFraction == fraction, "\(icon) at \(side)")
                #expect(geometry.ringStroke == 1, "\(icon) at \(side)")
            }
        }
    }

    @Test func theCheckIsADiscFillingTheBoxWithTodaysTickPoints() throws {
        let one = Drawing.geometry(for: .check, in: box(side: 9, at: CGPoint(x: 2, y: 3)))
        #expect(one.checkDisc == CGRect(x: 2, y: 3, width: 9, height: 9))
        let expected: [(CGFloat, CGFloat)] = [(2.52, 4.68), (4.05, 6.12), (6.66, 3.06)]
        let tick = try #require(one.tick)
        #expect(tick.count == 3)
        for (point, want) in zip(tick, expected) {
            #expect(near(point.x, 2 + want.0) && near(point.y, 3 + want.1), "\(point) is not (\(want.0), \(want.1)) from the top left")
        }
        #expect(one.tickStroke == 1.2)

        let scaled = Drawing.geometry(for: .check, in: box(side: 12))
        let scaledTick = try #require(scaled.tick)
        for (point, want) in zip(scaledTick, expected) {
            #expect(near(point.x, want.0 * 12 / 9) && near(point.y, want.1 * 12 / 9))
        }
        #expect(scaled.tickStroke == 1.2, "the tick's stroke does not scale")
        #expect(scaled.checkDisc == CGRect(x: 0, y: 0, width: 12, height: 12))
    }

    // MARK: - Pixels

    private struct Bitmap {
        let side: Int
        let bytes: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * side + x) * 4 + 3]) }
        func green(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * side + x) * 4 + 1]) }
        /// The alpha summed over the 3 x 3 pixels round a point, for a mark that is a fraction of a pixel wide.
        func mass(_ x: Int, _ y: Int) -> Int {
            var total = 0
            for dy in -1...1 { for dx in -1...1 { total += alpha(x + dx, y + dy) } }
            return total
        }
    }

    /// Draws an icon red (tick white) into a `side` x `side` bitmap with y running down, as every caller's context does.
    private func render(_ icon: WorkspaceStatusIcon, side: Int) throws -> Bitmap {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        Drawing.draw(
            icon, in: context, box: box(side: CGFloat(side)),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), tickColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        )
        let data = try #require(context.data)
        return Bitmap(side: side, bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4)))
    }

    /// At 36 pt the box is scale 4: ring radius 16, pie radius 10, center (18, 18).
    @Test func eachFillIsDrawnClockwiseFromTwelveOClockInsideTheRing() throws {
        // (top-right, bottom-right, bottom-left, top-left) quadrant samples, 5 pt from the center on each axis.
        let samples: [(Int, Int)] = [(23, 13), (23, 23), (13, 23), (13, 13)]
        let fills: [(WorkspaceStatusIcon, [Bool])] = [
            (.ring, [false, false, false, false]),
            (.quarter, [true, false, false, false]),
            (.half, [true, true, false, false]),
            (.threeQuarters, [true, true, true, false]),
            (.full, [true, true, true, true]),
        ]
        for (icon, filled) in fills {
            let bitmap = try render(icon, side: 36)
            for (index, point) in samples.enumerated() {
                let alpha = bitmap.alpha(point.0, point.1)
                #expect((alpha > 200) == filled[index] && (filled[index] || alpha == 0), "\(icon) quadrant \(index) alpha \(alpha)")
            }
            // The stroke is centered on y = 2, so it covers half of rows 1 and 2.
            #expect(max(bitmap.alpha(18, 1), bitmap.alpha(18, 2)) > 100, "\(icon): the ring is stroked at the top")
            #expect(bitmap.alpha(18, 6) == 0, "\(icon): nothing between the fill and the ring")
        }
    }

    @Test func theCheckIsADiscWithAWhiteTick() throws {
        let bitmap = try render(.check, side: 36)
        #expect(bitmap.alpha(18, 6) > 200, "the disc fills the box, ring included")
        #expect(bitmap.alpha(2, 2) == 0, "outside the circle")
        // The middle of the tick's first leg, from (10.08, 18.72) to (16.2, 24.48): white over the red disc.
        #expect(bitmap.green(13, 21) > 150, "the tick is white: green \(bitmap.green(13, 21))")
        #expect(bitmap.green(18, 6) == 0, "the disc is the icon's color")
    }

    @Test func theDottedRingHasADashOnEachHourAndGapsBetween() throws {
        let bitmap = try render(.dottedRing, side: 36)
        for hour in 0..<12 {
            let angle = Double(hour) * .pi / 6
            let dash = (18 + Int((16 * sin(angle)).rounded()), 18 - Int((16 * cos(angle)).rounded()))
            #expect(bitmap.mass(dash.0, dash.1) > 30, "no dash at hour \(hour): \(bitmap.mass(dash.0, dash.1))")
            let gapAngle = angle + .pi / 12
            let gap = (18 + Int((16 * sin(gapAngle)).rounded()), 18 - Int((16 * cos(gapAngle)).rounded()))
            #expect(bitmap.mass(gap.0, gap.1) == 0, "a mark between hours \(hour) and \(hour + 1): \(bitmap.mass(gap.0, gap.1))")
        }
        #expect(bitmap.alpha(18, 18) == 0)
    }

    // MARK: - Color

    private func components(_ color: NSColor) -> [CGFloat] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        zip(components(a), components(b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    private func model(
        _ status: WorkspaceTaskStatus = .review,
        mono: Bool = false,
        scheme: ColorScheme = .light,
        icon: WorkspaceStatusIcon? = nil,
        hex: String? = nil
    ) -> SidebarRowTaskStatusGlyphButton.Model {
        .init(status: status, hasOverride: true, usesMonochrome: mono, fontScale: 1, colorScheme: scheme, icon: icon, colorHex: hex)
    }

    /// The glyph's color in its three cases: the one color, his hex, and the status's own role.
    @Test func theGlyphColorIsTheOneColorThenHisHexThenTheRole() throws {
        let mono = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let neutral = NSColor.gray
        let button = SidebarRowTaskStatusGlyphButton.self

        let monochrome = button.statusColor(model: model(mono: true, hex: "#FF8800"), monochromeColor: mono, neutralColor: neutral)
        #expect(sameColor(monochrome, mono), "the one color wins over his hex")

        let light = button.statusColor(model: model(hex: "#336699"), monochromeColor: mono, neutralColor: neutral)
        let lightExpected = try #require(WorkspaceTabColorSettings.displayNSColor(hex: "#336699", colorScheme: .light, forceBright: false))
        #expect(sameColor(light, lightExpected))
        let dark = button.statusColor(model: model(scheme: .dark, hex: "#336699"), monochromeColor: mono, neutralColor: neutral)
        let darkExpected = try #require(WorkspaceTabColorSettings.displayNSColor(hex: "#336699", colorScheme: .dark, forceBright: false))
        #expect(sameColor(dark, darkExpected))
        #expect(!sameColor(light, dark), "his color is as stored in Light and brightened in Dark")

        #expect(sameColor(button.statusColor(model: model(.review), monochromeColor: mono, neutralColor: neutral), .systemGreen))
        #expect(sameColor(button.statusColor(model: model(.todo), monochromeColor: mono, neutralColor: neutral), neutral))
        #expect(sameColor(
            button.statusColor(model: model(.needsAttention), monochromeColor: mono, neutralColor: neutral),
            NSColor(srgbRed: 1.0, green: 0.42, blue: 0.2, alpha: 1)
        ))
    }

    @Test func theTickIsWhiteAndBlackAtSevenTenthsInTheOneColorMode() {
        #expect(sameColor(SidebarRowTaskStatusGlyphButton.tickColor(model: model(.done)), .white))
        #expect(sameColor(
            SidebarRowTaskStatusGlyphButton.tickColor(model: model(.done, mono: true)),
            NSColor.black.withAlphaComponent(0.7)
        ))
    }

    // MARK: - The rows each place is handed

    private static let entries = [
        WorkspaceStatusEntry(id: "done", name: "Done", color: "1: DONE", icon: .check),
        WorkspaceStatusEntry(id: "review", name: "Review", color: "2: REVIEW", icon: .threeQuarters),
        WorkspaceStatusEntry(id: "paused", name: "Paused", extends: .todo, icon: .ring),
        WorkspaceStatusEntry(id: "tinted", name: "Tinted", extends: .working, color: "3: TINTED"),
        WorkspaceStatusEntry(id: "plain", name: "Plain", extends: .todo),
    ]
    private static let list = WorkspaceStatusList(entries: entries, source: .file)
    private static let hexes = ["done": "#112233", "review": "#336699", "tinted": "#AA5500"]

    private func picker(
        _ resolution: WorkspaceStatusResolution = .detected(.todo),
        inferred: WorkspaceTaskStatus = .todo
    ) -> WorkspaceStatusPickerState {
        WorkspaceStatusPicker().rows(resolution: resolution, inferred: inferred, isHidden: false, list: Self.list)
    }

    /// `lanes(picker:colorHexes:)` gives each entry row its icon, and Auto, None and the greyed row none.
    @Test func eachLaneCarriesItsEntrysIconAndTheGreyedRowHasNone() {
        let held = WorkspaceStatusResolution.resolve(
            override: WorkspaceTaskStatusOverride(status: .working, inferredAtOverride: .todo),
            own: nil, inferred: .todo, list: Self.list
        )
        // `working` is a cmux id the list leaves out: the greyed row.
        let lanes = WorkspaceTodoStatusLane.lanes(picker: picker(held), colorHexes: Self.hexes)
        #expect(lanes.map(\.icon) == [nil, .check, .threeQuarters, .ring, nil, nil, nil, nil])
        #expect(lanes.map(\.colorHex) == [nil, "#112233", "#336699", nil, "#AA5500", nil, nil, nil])
        #expect(lanes[6].action == nil, "the greyed row")
        #expect(lanes.first?.icon == nil && lanes.last?.icon == nil, "Auto and None")
    }

    /// The row's picker checks the entry the pane header shows: one workspace on Review, with his list, gives the same
    /// icon and color to the row's menu model, the popover's model and the pane's state.
    @Test func oneWorkspaceOnReviewGivesTheSameIconAndColorToTheRowThePopoverAndThePane() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.setTaskStatusOverride(.review)
        let inferred = workspace.inferredTaskStatus
        let resolution = workspace.statusResolution(list: Self.list)
        #expect(resolution.inEffect?.id == "review")

        let rowPicker = WorkspaceStatusPicker().rows(
            resolution: resolution, inferred: inferred, isHidden: false, list: Self.list
        )
        let menuModel = SidebarWorkspaceCompactStatusMenuModel.resolve(
            inferred: inferred, override: workspace.todoState.statusOverride, picker: rowPicker, colorHexes: Self.hexes
        )
        let rowEntry = try #require(WorkspaceStatusPresentation.checkedEntry(in: menuModel.picker))
        #expect(rowEntry.icon == .threeQuarters)
        #expect(menuModel.colorHexes[rowEntry.id] == "#336699")

        let popover = SidebarWorkspaceStatusPopoverModel(
            inferred: menuModel.inferred, activeOverride: menuModel.activeOverride,
            picker: try #require(menuModel.picker), colorHexes: menuModel.colorHexes
        )
        let popoverLanes = WorkspaceTodoStatusLane.lanes(picker: popover.picker, colorHexes: popover.colorHexes)
        let lane = try #require(popoverLanes.first { $0.isSelected })
        #expect(lane.icon == .threeQuarters && lane.colorHex == "#336699")

        let pane = WorkspaceStatusPaneState.make(
            resolution: resolution, inferred: inferred, list: Self.list, controlsEnabled: true, colorHexes: Self.hexes
        )
        #expect(pane.icon == .threeQuarters && pane.colorHex == "#336699")
        #expect(pane.colorHexes == Self.hexes)
        #expect(WorkspaceStatusPresentation.checkedName(in: menuModel.picker) == "Review", "the name still reads the same row")
    }

    /// On Auto the pane's header shows his entry for what cmux detects; with no entry for it, today's glyph.
    @Test func aPaneOnAutoShowsHisEntryForWhatCmuxDetectsAndNothingWhenTheListHasNone() {
        let onTodo = WorkspaceStatusPaneState.make(
            resolution: .detected(.todo), inferred: .todo, list: Self.list, controlsEnabled: true, colorHexes: Self.hexes
        )
        #expect(onTodo.icon == nil && onTodo.colorHex == nil, "the list has no entry whose id is todo")
        let onReview = WorkspaceStatusPaneState.make(
            resolution: .detected(.review), inferred: .review, list: Self.list, controlsEnabled: true, colorHexes: Self.hexes
        )
        #expect(onReview.icon == .threeQuarters && onReview.colorHex == "#336699")
        let cmuxFive = WorkspaceStatusPaneState.make(
            resolution: .detected(.review), inferred: .review, list: .cmuxFive, controlsEnabled: true
        )
        #expect(cmuxFive.icon == nil && cmuxFive.colorHex == nil, "with no list, today's glyph")
    }

    /// `checkedEntry(in:)` is the entry on the checked entry row, and nothing for Auto, the greyed row or None.
    @Test func theCheckedEntryIsTheCheckedEntryRowAndNothingForTheOthers() throws {
        #expect(WorkspaceStatusPresentation.checkedEntry(in: nil) == nil)
        #expect(WorkspaceStatusPresentation.checkedEntry(in: picker(.detected(.todo)))?.id == nil, "Auto is checked")
        let inEffect = WorkspaceStatusResolution.resolve(
            override: nil, own: WorkspaceOwnStatus(id: "paused"), inferred: .todo, list: Self.list
        )
        #expect(WorkspaceStatusPresentation.checkedEntry(in: picker(inEffect))?.id == "paused")
        let greyed = WorkspaceStatusResolution.resolve(
            override: WorkspaceTaskStatusOverride(status: .working, inferredAtOverride: .todo),
            own: nil, inferred: .todo, list: Self.list
        )
        #expect(WorkspaceStatusPresentation.checkedEntry(in: picker(greyed)) == nil, "the greyed row has no entry")
        let hidden = WorkspaceStatusPicker().rows(resolution: inEffect, inferred: .todo, isHidden: true, list: Self.list)
        #expect(WorkspaceStatusPresentation.checkedEntry(in: hidden) == nil, "None is checked")
    }

    // MARK: - The Status menu's image

    @Test func theMenuImageIsForARowWithAColorOrAnIconAndNotForOneWithNeither() {
        #expect(WorkspaceStatusMenuImage.shows(icon: .ring, colorHex: nil))
        #expect(WorkspaceStatusMenuImage.shows(icon: nil, colorHex: "#336699"))
        #expect(WorkspaceStatusMenuImage.shows(icon: .check, colorHex: "#336699"))
        #expect(!WorkspaceStatusMenuImage.shows(icon: nil, colorHex: nil))
    }

    /// A 14 pt image, drawn: the ring's stroke on the 12 pt box's edge falls inside it, the top-right quadrant of a
    /// quarter fill is drawn, a no-icon status whose circle sits on the box edge is not clipped, and the neutral color
    /// is the menu's own.
    @Test func theMenuImageIsDrawnWithTheRingInsideItsEdges() throws {
        for isDark in [false, true] {
            let side = WorkspaceStatusMenuImage.side
            let sidePx = Int(side * 4)
            let image = WorkspaceStatusMenuImage.make(status: .review, icon: .ring, colorHex: "#336699", isDark: isDark)
            #expect(image.size == NSSize(width: 14, height: 14))
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: sidePx, pixelsHigh: sidePx, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(sidePx), height: CGFloat(sidePx)))
            NSGraphicsContext.restoreGraphicsState()
            // At 4x the ring's left stroke spans x = 4.7 to 8.7: inside the image, and the middle is empty.
            let left = bitmap.colorAt(x: 6, y: sidePx / 2)?.alphaComponent ?? 0
            let center = bitmap.colorAt(x: sidePx / 2, y: sidePx / 2)?.alphaComponent ?? 1
            #expect(left > 0.5, "dark \(isDark): the ring is drawn at the left edge: \(left)")
            #expect(center == 0, "dark \(isDark): the middle of a ring is empty")

            // .quarter draws clockwise from 12 o'clock to 3 o'clock (the top-right quadrant in flipped context).
            let quarterImage = WorkspaceStatusMenuImage.make(status: .review, icon: .quarter, colorHex: "#336699", isDark: isDark)
            let quarterBitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: sidePx, pixelsHigh: sidePx, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: quarterBitmap)
            quarterImage.draw(in: NSRect(x: 0, y: 0, width: CGFloat(sidePx), height: CGFloat(sidePx)))
            NSGraphicsContext.restoreGraphicsState()
            let topRight = quarterBitmap.colorAt(x: 32, y: 24)?.alphaComponent ?? 0
            #expect(topRight > 0.5, "dark \(isDark): quarter fill is drawn in the top-right quadrant: \(topRight)")

            // A no-icon status whose circle sits on the 12 pt box edge is drawn without clipping.
            let noIconImage = WorkspaceStatusMenuImage.make(status: .needsAttention, icon: nil, colorHex: "#336699", isDark: isDark)
            let noIconBitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: sidePx, pixelsHigh: sidePx, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: noIconBitmap)
            noIconImage.draw(in: NSRect(x: 0, y: 0, width: CGFloat(sidePx), height: CGFloat(sidePx)))
            NSGraphicsContext.restoreGraphicsState()
            // In a 14 pt image at 4x, the 1.4 pt stroke on the 12 pt box extends to x = 1.2 px; pixel 0 is outside (empty), and x = 2 is inside the unclipped stroke.
            let gap = noIconBitmap.colorAt(x: 0, y: sidePx / 2)?.alphaComponent ?? 1
            let outerStroke = noIconBitmap.colorAt(x: 2, y: sidePx / 2)?.alphaComponent ?? 0
            #expect(gap < 0.1, "dark \(isDark): gap outside the unclipped stroke is empty at pixel 0: \(gap)")
            #expect(outerStroke > 0.5, "dark \(isDark): no-icon circle stroke on box edge is not clipped: \(outerStroke)")
        }
    }

    @Test func thePauseIconHasBarPixelsInsideTheRingWhereTheRingHasNoneInLightAndDark() throws { // (#cm-109.3)
        for isDark in [false, true] { // (#cm-109.3)
            let side = WorkspaceStatusMenuImage.side // (#cm-109.3)
            let sidePx = Int(side * 4) // (#cm-109.3)
            let ringImage = WorkspaceStatusMenuImage.make(status: .review, icon: .ring, colorHex: "#336699", isDark: isDark) // (#cm-109.3)
            let pauseImage = WorkspaceStatusMenuImage.make(status: .review, icon: .pause, colorHex: "#336699", isDark: isDark) // (#cm-109.3)
            let ringBitmap = try #require(NSBitmapImageRep( // (#cm-109.3)
                bitmapDataPlanes: nil, pixelsWide: sidePx, pixelsHigh: sidePx, bitsPerSample: 8, samplesPerPixel: 4, // (#cm-109.3)
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0 // (#cm-109.3)
            )) // (#cm-109.3)
            NSGraphicsContext.saveGraphicsState() // (#cm-109.3)
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ringBitmap) // (#cm-109.3)
            ringImage.draw(in: NSRect(x: 0, y: 0, width: CGFloat(sidePx), height: CGFloat(sidePx))) // (#cm-109.3)
            NSGraphicsContext.restoreGraphicsState() // (#cm-109.3)

            let pauseBitmap = try #require(NSBitmapImageRep( // (#cm-109.3)
                bitmapDataPlanes: nil, pixelsWide: sidePx, pixelsHigh: sidePx, bitsPerSample: 8, samplesPerPixel: 4, // (#cm-109.3)
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0 // (#cm-109.3)
            )) // (#cm-109.3)
            NSGraphicsContext.saveGraphicsState() // (#cm-109.3)
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pauseBitmap) // (#cm-109.3)
            pauseImage.draw(in: NSRect(x: 0, y: 0, width: CGFloat(sidePx), height: CGFloat(sidePx))) // (#cm-109.3)
            NSGraphicsContext.restoreGraphicsState() // (#cm-109.3)

            let ringLeftAlpha = ringBitmap.colorAt(x: 21, y: sidePx / 2)?.alphaComponent ?? 1 // (#cm-109.3)
            let ringRightAlpha = ringBitmap.colorAt(x: 35, y: sidePx / 2)?.alphaComponent ?? 1 // (#cm-109.3)
            #expect(ringLeftAlpha == 0, "dark \(isDark): ring has no left bar pixel") // (#cm-109.3)
            #expect(ringRightAlpha == 0, "dark \(isDark): ring has no right bar pixel") // (#cm-109.3)

            let pauseLeftAlpha = pauseBitmap.colorAt(x: 21, y: sidePx / 2)?.alphaComponent ?? 0 // (#cm-109.3)
            let pauseRightAlpha = pauseBitmap.colorAt(x: 35, y: sidePx / 2)?.alphaComponent ?? 0 // (#cm-109.3)
            #expect(pauseLeftAlpha > 0.5, "dark \(isDark): pause has left bar pixel where ring has none: \(pauseLeftAlpha)") // (#cm-109.3)
            #expect(pauseRightAlpha > 0.5, "dark \(isDark): pause has right bar pixel where ring has none: \(pauseRightAlpha)") // (#cm-109.3)

            let pauseGapAlpha = pauseBitmap.colorAt(x: 28, y: 28)?.alphaComponent ?? 1 // (#cm-109.3)
            #expect(pauseGapAlpha == 0, "dark \(isDark): pause gap at center is empty: \(pauseGapAlpha)") // (#cm-109.3)

            let pauseBarTopAlpha = pauseBitmap.colorAt(x: 21, y: 22)?.alphaComponent ?? 0 // (#cm-109.3)
            let pauseBarBottomAlpha = pauseBitmap.colorAt(x: 21, y: 34)?.alphaComponent ?? 0 // (#cm-109.3)
            let pauseAboveBarAlpha = pauseBitmap.colorAt(x: 21, y: 12)?.alphaComponent ?? 1 // (#cm-109.3)
            #expect(pauseBarTopAlpha > 0.5, "dark \(isDark): pause left bar top pixel present: \(pauseBarTopAlpha)") // (#cm-109.3)
            #expect(pauseBarBottomAlpha > 0.5, "dark \(isDark): pause left bar bottom pixel present: \(pauseBarBottomAlpha)") // (#cm-109.3)
            #expect(pauseAboveBarAlpha == 0, "dark \(isDark): space above bar is empty: \(pauseAboveBarAlpha)") // (#cm-109.3)

            let pauseRingAlpha = pauseBitmap.colorAt(x: 6, y: 28)?.alphaComponent ?? 0 // (#cm-109.3)
            #expect(pauseRingAlpha > 0.5, "dark \(isDark): pause still has ring stroke pixel: \(pauseRingAlpha)") // (#cm-109.3)
        } // (#cm-109.3)
    } // (#cm-109.3)
}
