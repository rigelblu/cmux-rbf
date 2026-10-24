import SwiftUI

/// Shared section heading: immutable text, fold state and the parent-owned action.
struct SidebarSectionSwiftUIHeader: View, Equatable {
    let title: String
    let label: String
    let identifier: String
    let isCollapsed: Bool
    var unreadCount: Int = 0
    var onToggle: @MainActor () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.label == rhs.label && lhs.identifier == rhs.identifier
            && lhs.isCollapsed == rhs.isCollapsed && lhs.unreadCount == rhs.unreadCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
                .padding(.bottom, 4)
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if unreadCount > 0 {
                    SidebarStatusUnreadBadge(count: unreadCount, fontScale: 1, globalFontMagnificationPercent: 100)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }
}
