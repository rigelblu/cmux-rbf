import CoreGraphics
import Testing

@testable import Bonsplit

@Suite
struct TabBarEmptyChromeHitRegionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 28)
    private let slop: CGFloat = 4

    /// A centered caption, as caption mode lays one out: empty chrome on both
    /// sides rather than only the trailing side.
    private let centeredCaption = [CGRect(x: 160, y: 0, width: 80, height: 28)]

    /// Leading-packed tabs, as tab mode lays them out.
    private let leadingTabs = [
        CGRect(x: 0, y: 0, width: 120, height: 28),
        CGRect(x: 120, y: 0, width: 120, height: 28),
    ]

    private func captures(
        x: CGFloat,
        frames: [CGRect],
        includesLeadingSpace: Bool,
        reservedTrailingWidth: CGFloat = 0
    ) -> Bool {
        TabBarEmptyChromeHitRegion.captures(
            point: CGPoint(x: x, y: 14),
            bounds: bounds,
            itemFrames: frames,
            reservedTrailingWidth: reservedTrailingWidth,
            includesLeadingSpace: includesLeadingSpace,
            horizontalSlop: slop
        )
    }

    /// Finding 36. Centering the caption created a leading empty region for the
    /// first time, and the hit test only ever accepted points to the trailing
    /// side of the items. Clicking left of an unfocused pane's caption did
    /// nothing while the same click to its right focused the pane.
    @Test
    func captionCapturesEmptyChromeOnBothSidesOfTheCaption() {
        #expect(captures(x: 20, frames: centeredCaption, includesLeadingSpace: true))
        #expect(captures(x: 380, frames: centeredCaption, includesLeadingSpace: true))
    }

    @Test
    func captionStillYieldsTheCaptionItselfToTheCaptionView() {
        #expect(!captures(x: 200, frames: centeredCaption, includesLeadingSpace: true))
        // Inside the slop padding, so still the caption's.
        #expect(!captures(x: 157, frames: centeredCaption, includesLeadingSpace: true))
    }

    /// The standing decision is that multi-surface tab behavior is unchanged,
    /// so leading-packed tabs must keep the trailing-only region exactly.
    @Test
    func tabModeKeepsTrailingOnlyCapture() {
        #expect(!captures(x: 60, frames: leadingTabs, includesLeadingSpace: false))
        #expect(captures(x: 300, frames: leadingTabs, includesLeadingSpace: false))
    }

    @Test
    func reservedTrailingWidthIsExcludedInBothModes() {
        #expect(!captures(x: 380, frames: centeredCaption, includesLeadingSpace: true, reservedTrailingWidth: 60))
        #expect(!captures(x: 380, frames: leadingTabs, includesLeadingSpace: false, reservedTrailingWidth: 60))
        // Still captured left of the reserved lane.
        #expect(captures(x: 20, frames: centeredCaption, includesLeadingSpace: true, reservedTrailingWidth: 60))
    }

    /// An empty header has no items, so the whole bar is empty chrome.
    @Test
    func emptyHeaderCapturesEverywhere() {
        #expect(captures(x: 5, frames: [], includesLeadingSpace: false))
        #expect(captures(x: 395, frames: [], includesLeadingSpace: false))
    }

    /// Finding 36's consistency guard. A region that captures clicks but has no
    /// cursor rect focuses the pane while showing no drag affordance.
    @Test
    func cursorRectsCoverExactlyWhatTheHitTestCaptures() {
        for includesLeadingSpace in [true, false] {
            let frames = includesLeadingSpace ? centeredCaption : leadingTabs
            let rects = TabBarEmptyChromeHitRegion.cursorRects(
                bounds: bounds,
                itemFrames: frames,
                reservedTrailingWidth: 0,
                includesLeadingSpace: includesLeadingSpace,
                horizontalSlop: slop
            )

            for x in stride(from: CGFloat(1), to: bounds.maxX, by: 1) {
                let captured = captures(
                    x: x,
                    frames: frames,
                    includesLeadingSpace: includesLeadingSpace
                )
                let covered = rects.contains { x >= $0.minX && x < $0.maxX }
                #expect(
                    captured == covered,
                    "x=\(x) leading=\(includesLeadingSpace): captured=\(captured) covered=\(covered)"
                )
            }
        }
    }
}
