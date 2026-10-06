import CmuxFoundation
import SwiftUI

/// A Settings card row whose leading title position is an editable control.
@MainActor
struct SettingsEditableTitleCardRow<Leading: View, Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let subtitle: String?
    let stacksWhenNeeded: Bool
    let verticalAlignment: VerticalAlignment
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @Environment(\.settingsSearchIndex) private var searchIndex

    init(
        configurationReview: SettingsConfigurationReview,
        subtitle: String?,
        stacksWhenNeeded: Bool = false,
        verticalAlignment: VerticalAlignment = .top,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.configurationReview = configurationReview
        self.subtitle = subtitle
        self.stacksWhenNeeded = stacksWhenNeeded
        self.verticalAlignment = verticalAlignment
        self.leading = leading()
        self.trailing = trailing()
    }

    private var searchAnchorIDs: [String] {
        guard let searchIndex else { return [] }
        return configurationReview.paths.compactMap(searchIndex.anchorID(forSettingsPath:))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
            leading
            if let subtitle {
                Text(subtitle)
                    .cmuxFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var horizontalRow: some View {
        HStack(alignment: verticalAlignment, spacing: 12) {
            title
                .fixedSize(horizontal: stacksWhenNeeded, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing.layoutPriority(1)
        }
    }

    var body: some View {
        Group {
            if stacksWhenNeeded {
                ViewThatFits(in: .horizontal) {
                    horizontalRow
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        trailing
                    }
                }
            } else {
                horizontalRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(searchAnchorIDs)
    }
}
