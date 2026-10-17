// cmux-rbf #cm-73.2a
import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SplitDividerOverlayTests {
    private final class CustomDividerSplitView: NSSplitView {
        var customColor: NSColor

        init(customColor: NSColor) {
            self.customColor = customColor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var dividerColor: NSColor {
            customColor
        }
    }

    @Test("overlayDividerColor skips a divider whose colour is clear")
    func testOverlayDividerColorSkipsClearDivider() {
        let clearSplitView = CustomDividerSplitView(customColor: .clear)
        let resolvedColor = SplitDividerOverlayView.overlayDividerColor(for: clearSplitView)
        #expect(resolvedColor == nil)
    }

    @Test("overlayDividerColor preserves non-clear divider color")
    func testOverlayDividerColorPreservesOpaqueDivider() {
        let opaqueSplitView = CustomDividerSplitView(customColor: .separatorColor)
        let resolvedColor = SplitDividerOverlayView.overlayDividerColor(for: opaqueSplitView)
        #expect(resolvedColor != nil)
    }
}
