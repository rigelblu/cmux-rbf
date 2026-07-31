import Testing

@testable import Bonsplit

@Suite
struct PaneHeaderPresentationTests {
    @Test
    func alwaysKeepsExistingHeaderLifecycle() {
        #expect(TabBarVisibility.always.presentation(tabCount: 0) == .empty)
        #expect(TabBarVisibility.always.presentation(tabCount: 1) == .tabs)
        #expect(TabBarVisibility.always.presentation(tabCount: 2) == .tabs)
    }

    @Test
    func multipleTabsKeepsExistingThreshold() {
        #expect(TabBarVisibility.multipleTabs.presentation(tabCount: 0) == .hidden)
        #expect(TabBarVisibility.multipleTabs.presentation(tabCount: 1) == .hidden)
        #expect(TabBarVisibility.multipleTabs.presentation(tabCount: 2) == .tabs)
        #expect(
            TabBarVisibility.multipleTabs.presentation(
                tabCount: 1,
                isFullWidthTabMode: true
            ) == .hidden
        )
    }

    @Test
    func adaptiveProjectsEmptyCaptionAndTabsFromCount() {
        #expect(TabBarVisibility.adaptive.presentation(tabCount: 0) == .empty)
        #expect(TabBarVisibility.adaptive.presentation(tabCount: 1) == .caption)
        #expect(TabBarVisibility.adaptive.presentation(tabCount: 2) == .tabs)
    }

    @Test
    func explicitFullWidthModeOutranksOnlyAdaptiveCaptionMode() {
        #expect(
            TabBarVisibility.adaptive.presentation(
                tabCount: 1,
                isFullWidthTabMode: true
            ) == .tabs
        )
        #expect(
            TabBarVisibility.adaptive.presentation(
                tabCount: 0,
                isFullWidthTabMode: true
            ) == .empty
        )
    }

    /// Finding 25. The bottom separator and the selected-tab indicator live in
    /// one view on opposite edges, so gating that view on `.tabs` silently took
    /// the separator with it — dropping it from `.caption`, which the brief
    /// requires to match tab mode, and from `.empty`, which never opted in.
    @Test
    func everyRenderedHeaderKeepsItsBottomSeparator() {
        #expect(PaneHeaderPresentation.tabs.showsHeaderSeparator)
        #expect(PaneHeaderPresentation.caption.showsHeaderSeparator)
        #expect(PaneHeaderPresentation.empty.showsHeaderSeparator)
        #expect(!PaneHeaderPresentation.hidden.showsHeaderSeparator)
    }

    /// Finding 25's other half. The indicator marks a selected tab, so it is
    /// the mark that belongs to tab mode alone.
    @Test
    func onlyTabModeShowsTheSelectedTabIndicator() {
        #expect(PaneHeaderPresentation.tabs.showsSelectedTabIndicator)
        #expect(!PaneHeaderPresentation.caption.showsSelectedTabIndicator)
        #expect(!PaneHeaderPresentation.empty.showsSelectedTabIndicator)
        #expect(!PaneHeaderPresentation.hidden.showsSelectedTabIndicator)
    }

    @Test
    func negativeCountsNormalizeToEmptyState() {
        #expect(TabBarVisibility.always.presentation(tabCount: -1) == .empty)
        #expect(TabBarVisibility.multipleTabs.presentation(tabCount: -1) == .hidden)
        #expect(TabBarVisibility.adaptive.presentation(tabCount: -1) == .empty)
    }
}
