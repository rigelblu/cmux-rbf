import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Visual three-up Theme picker row.
///
/// Mirrors the legacy in-app `ThemePickerRow`: a leading "Theme" title
/// and a trailing row of three tappable thumbnails (System / Light /
/// Dark) backed by ``ThemeWindowThumbnail``. The System tile shows a
/// split light/dark composition with a hairline divider. The selected
/// tile gets an accent border and tinted background.
@MainActor
struct ThemePickerRow: View {
    let selectedMode: AppearanceMode
    let onSelect: (AppearanceMode) -> Void
    /// A caveat rendered under the "Theme" title, or `nil` for the normal case.
    ///
    /// The treatment here is *copied* from ``SettingsCardRow``, not inherited:
    /// this row is a bespoke `HStack`, not a `SettingsCardRow`, so it has no
    /// subtitle slot to fill. The Language row directly above it uses that
    /// component's subtitle for its own conditional caveat ("Restart cmux to
    /// apply"), and two caveats in one card that do not look alike read as two
    /// different kinds of message — so keep `spacing: 3`, `.caption`,
    /// `.secondary` and `lineLimit(2)` in step with `SettingsCardRow.body`.
    var subtitle: String?

    private let thumbWidth: CGFloat = 76
    private let thumbHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(String(localized: "settings.app.theme", defaultValue: "Theme"))
                    .cmuxFont(size: 13, weight: .medium)
                if let subtitle {
                    Text(subtitle)
                        .cmuxFont(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    let isSelected = selectedMode == mode
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .system {
                                    ZStack {
                                        ThemeWindowThumbnail(isDark: false)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width / 4, y: geo.size.height / 2)
                                                }
                                            )
                                        ThemeWindowThumbnail(isDark: true)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width * 0.75, y: geo.size.height / 2)
                                                }
                                            )
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.15))
                                                .frame(width: 1, height: geo.size.height)
                                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                        }
                                    }
                                } else {
                                    ThemeWindowThumbnail(isDark: mode == .dark)
                                }
                            }
                            .frame(width: thumbWidth, height: thumbHeight)

                            Text(themeDisplayName(mode))
                                .cmuxFont(size: 10)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themeDisplayName(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: return String(localized: "appearance.system", defaultValue: "System")
        case .light: return String(localized: "appearance.light", defaultValue: "Light")
        case .dark: return String(localized: "appearance.dark", defaultValue: "Dark")
        }
    }
}
