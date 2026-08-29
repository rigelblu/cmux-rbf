import CmuxFoundation
import SwiftUI

/// A Settings card row whose leading title position is an editable control.
@MainActor
struct SettingsEditableTitleCardRow<Leading: View, Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let subtitle: String?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @Environment(\.settingsSearchIndex) private var searchIndex

    init(
        configurationReview: SettingsConfigurationReview,
        subtitle: String?,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.configurationReview = configurationReview
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    private var searchAnchorIDs: [String] {
        guard let searchIndex else { return [] }
        return configurationReview.paths.compactMap(searchIndex.anchorID(forSettingsPath:))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                leading
                if let subtitle {
                    Text(subtitle)
                        .cmuxFont(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(searchAnchorIDs)
    }
}
