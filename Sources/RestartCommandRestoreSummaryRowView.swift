import CmuxFoundation
import CmuxRestartCommands
import SwiftUI

/// One noninteractive, dynamically-sized app-scoped item shared by the Mac
/// notifications popover and full page.
struct RestartCommandRestoreSummaryRowView: View, Equatable {
    nonisolated static func == (
        lhs: RestartCommandRestoreSummaryRowView,
        rhs: RestartCommandRestoreSummaryRowView
    ) -> Bool {
        lhs.summary == rhs.summary && lhs.isFocused == rhs.isFocused
    }

    let summary: RestartCommandRestoreSummary
    let isFocused: Bool
    let onClear: () -> Void
    let onToggleRead: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            rowContent
                .background(Color.primary.opacity(isHovering || isFocused ? 0.08 : 0))

            clearButton
                .padding(.trailing, 10)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HoverTrackingRepresentable { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RestartCommandRestoreSummaryRow.\(summary.id.uuidString)")
        .accessibilityAction(
            named: Text(
                summary.isRead
                    ? String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")
                    : String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")
            )
        ) {
            onToggleRead()
        }
        .accessibilityAction(
            named: Text(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
        ) {
            onClear()
        }
        .contextMenu {
            Button(
                summary.isRead
                    ? String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")
                    : String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")
            ) {
                onToggleRead()
            }
            Divider()
            Button(
                String(localized: "notifications.dismiss", defaultValue: "Dismiss"),
                role: .destructive
            ) {
                onClear()
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(summary.isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 2.5)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.title)
                        .cmuxFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "RestartCommandRestoreSummaryRow.\(summary.id.uuidString).title"
                        )
                    Spacer(minLength: 0)
                    Text(summary.createdAt.formatted(date: .omitted, time: .shortened))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 34)
                        .layoutPriority(2)
                }

                ForEach(summary.rows) { row in
                    Text(row.displayText)
                        .cmuxFont(size: 11.5)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "RestartCommandRestoreSummaryRow.\(summary.id.uuidString).reason.\(row.id.uuidString)"
                        )
                }

                if let overflowText = summary.overflowText {
                    Text(overflowText)
                        .cmuxFont(size: 11.5, weight: .medium)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var clearButton: some View {
        Button(action: onClear) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.1))
                CmuxSystemSymbolImage(systemName: "xmark", pointSize: 9, weight: .bold, tint: .primary.opacity(0.7))
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}
