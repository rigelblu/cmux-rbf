import XCTest
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the defect two cold reviews caught on 2026-07-31:
/// browser and markdown panels in **unmounted** workspaces never received the
/// app-wide magnification change.
///
/// The observers were originally `.onReceive` modifiers on the SwiftUI views.
/// cmux mounts one workspace at a time (`WorkspaceMountPlan.maxMountedWorkspaces
/// == 1`), and `.onReceive` neither fires while unmounted nor replays on
/// re-mount — so those documents rendered at whatever scale was current when
/// they were created and stayed there indefinitely.
///
/// These tests construct panels and post the notification **without ever
/// creating a view**, which is exactly the unmounted condition. They fail if the
/// observer is moved back onto the view.
@MainActor
final class PanelGlobalMagnificationObserverTests: XCTestCase {
    private var originalPercent: Int = GlobalFontMagnification.defaultPercent

    override func setUp() {
        super.setUp()
        originalPercent = GlobalFontMagnification.storedPercent
        GlobalFontMagnification.setPercent(GlobalFontMagnification.defaultPercent)
    }

    override func tearDown() {
        GlobalFontMagnification.setPercent(originalPercent)
        super.tearDown()
    }

    /// A markdown panel with no view attached must still track the scale.
    func testMarkdownPanelTracksMagnificationWithoutAnyViewAttached() {
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: NSTemporaryDirectory() + "cm14-magnification-\(UUID().uuidString).md"
        )
        let before = panel.effectiveFontSize
        XCTAssertGreaterThan(before, 0)

        // No MarkdownPanelView is ever constructed — this is the unmounted case.
        GlobalFontMagnification.setPercent(150)

        XCTAssertGreaterThan(
            panel.effectiveFontSize,
            before,
            "markdown panel in an unmounted workspace must follow the app-wide scale"
        )
    }

    /// The user's own size is preserved as a ratio, not overwritten — the
    /// typography popover must keep showing what they picked.
    func testMarkdownPanelKeepsTheUserChosenSizeWhileScaling() {
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: NSTemporaryDirectory() + "cm14-magnification-\(UUID().uuidString).md"
        )
        _ = panel.setFontSize(20)
        let chosen = panel.fontSize

        GlobalFontMagnification.setPercent(150)

        XCTAssertEqual(panel.fontSize, chosen, accuracy: 0.0001,
                       "the user's chosen size must not be rewritten by a global scale change")
        XCTAssertGreaterThan(panel.effectiveFontSize, chosen,
                             "the rendered size must still grow")
    }

    /// Elevated at creation, then back to default: the panel must land on the
    /// user's chosen size, having actually moved in between. Asserting only the
    /// endpoint passes even when nothing ever changes, so the midpoint is
    /// checked too.
    func testMarkdownPanelCreatedAtAnElevatedScaleAdoptsItThenReturns() {
        GlobalFontMagnification.setPercent(170)

        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: NSTemporaryDirectory() + "cm14-magnification-\(UUID().uuidString).md"
        )
        _ = panel.setFontSize(18)

        XCTAssertGreaterThan(
            panel.effectiveFontSize, 18,
            "a panel created at 170% must already render larger than the chosen size"
        )

        GlobalFontMagnification.setPercent(GlobalFontMagnification.defaultPercent)

        XCTAssertEqual(panel.effectiveFontSize, 18, accuracy: 0.01)
    }

    // MARK: - Browser (same defect, other panel type)

    /// A browser pane with no view attached must still track the scale.
    /// This is H2: the observer used to live on `BrowserPanelView`, so panes in
    /// unselected workspaces kept rendering at their creation-time scale and
    /// `currentPageZoomFactor()` reported a value inconsistent with the app.
    func testBrowserPanelTracksMagnificationWithoutAnyViewAttached() {
        let panel = BrowserPanel(workspaceId: UUID())
        let before = panel.currentPageZoomFactor()
        XCTAssertGreaterThan(before, 0)

        // No BrowserPanelView is ever constructed — the unmounted case.
        GlobalFontMagnification.setPercent(150)

        XCTAssertGreaterThan(
            panel.currentPageZoomFactor(),
            before,
            "browser pane in an unmounted workspace must follow the app-wide scale"
        )
    }

    /// A pane created while the scale is already elevated must adopt it at
    /// birth. The observer only delivers *changes*, so without a creation-time
    /// apply a new tab rendered at 1.0 beside siblings at 2.0 until the user
    /// next moved the percent.
    func testBrowserPanelCreatedAtAnElevatedScaleAdoptsItImmediately() {
        GlobalFontMagnification.setPercent(200)

        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertEqual(
            panel.currentPageZoomFactor(), 2.0, accuracy: 0.001,
            "a pane opened at 200% must render at 2.0, not 1.0"
        )
    }

    /// Round trip: elevated at creation, then back to default, must land at 1.0
    /// rather than retaining the creation-time scale.
    func testBrowserPanelCreatedAtAnElevatedScaleReturnsToOneAtDefault() {
        GlobalFontMagnification.setPercent(200)
        let panel = BrowserPanel(workspaceId: UUID())

        GlobalFontMagnification.setPercent(GlobalFontMagnification.defaultPercent)

        XCTAssertEqual(panel.currentPageZoomFactor(), 1.0, accuracy: 0.001)
    }

    /// M5: the per-pane base used to be clamped against the *rendered* bounds,
    /// so at a high global scale further `Cmd+=` presses changed nothing,
    /// returned `false`, and let the chord fall through to the web page.
    /// Stepping in must keep increasing the rendered zoom until the real ceiling.
    /// The observable symptom is the ratchet on the way *back down*, not the way
    /// up: a single step in still moved the page under the old clamp. The old
    /// clamp let the BASE keep climbing to 5.0 while the rendered value sat
    /// pinned at the ceiling, so zooming back out needed roughly 25 presses
    /// before anything changed. One press must be enough.
    func testBrowserZoomOutRespondsImmediatelyAfterSaturatingAtAHighGlobalScale() {
        let panel = BrowserPanel(workspaceId: UUID())
        GlobalFontMagnification.setPercent(200)

        // Drive well past the rendered ceiling.
        for _ in 0..<40 {
            _ = panel.zoomIn()
        }
        let saturated = panel.currentPageZoomFactor()

        _ = panel.zoomOut()

        XCTAssertLessThan(
            panel.currentPageZoomFactor(), saturated,
            "one zoom-out must move the page; the base must not have ratcheted above the reachable range"
        )
    }

    /// Cmd+0 on a browser pane resets that pane's OWN zoom and must keep the
    /// app-wide scale applied — the same composition every sibling has.
    ///
    /// Rendering a literal 1.0 instead pins `base = 1/scale`, which showed up as
    /// the pane sitting at half its neighbours and then being driven to 0.5 by a
    /// following ⇧⌘0 — permanently opted out of the app-wide scale.
    func testBrowserResetKeepsTheAppWideScaleApplied() {
        let panel = BrowserPanel(workspaceId: UUID())
        GlobalFontMagnification.setPercent(200)

        _ = panel.resetZoomResult()

        XCTAssertEqual(
            panel.currentPageZoomFactor(), 2.0, accuracy: 0.001,
            "reset must render 1.0 x scale, not a literal 1.0"
        )
    }

    /// The follow-on that made the regression permanent: after a reset, a later
    /// return to 100% must land the pane back at 1.0 — not at 1/scale.
    func testBrowserResetThenReturningToDefaultScaleLandsAtOne() {
        let panel = BrowserPanel(workspaceId: UUID())
        GlobalFontMagnification.setPercent(200)
        _ = panel.resetZoomResult()

        GlobalFontMagnification.setPercent(GlobalFontMagnification.defaultPercent)

        XCTAssertEqual(
            panel.currentPageZoomFactor(), 1.0, accuracy: 0.001,
            "a reset pane must return to 1.0 at 100%, not 0.5"
        )
    }

    /// Successive changes must keep moving rather than settling — the shape the
    /// earlier fixed-point defect violated, asserted here through the panel.
    func testMarkdownPanelSizeAdvancesAcrossSuccessiveChanges() {
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: NSTemporaryDirectory() + "cm14-magnification-\(UUID().uuidString).md"
        )
        var seen: [Double] = [panel.effectiveFontSize]
        for percent in [110, 120, 130] {
            GlobalFontMagnification.setPercent(percent)
            seen.append(panel.effectiveFontSize)
        }

        XCTAssertEqual(Set(seen).count, seen.count, "font pinned — saw repeats in \(seen)")
        for (earlier, later) in zip(seen, seen.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
    }
}
