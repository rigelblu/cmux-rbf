import CmuxProductAnalytics

extension RightSidebarMode {
    /// The feature this right-sidebar tab counts as in product analytics.
    var productFeature: ProductFeature {
        switch self {
        case .files: .filesExplorer
        case .find: .find
        case .sessions: .vault
        case .feed: .feed
        case .dock: .dock
        case .machines: .cloudSidebar
        // cmux-rbf (#cm-142.1): Reply (#cm-69) has no ProductFeature of its own; counted with Feed
        case .reply: .feed
        case .customSidebar: .customSidebar
        }
    }
}
