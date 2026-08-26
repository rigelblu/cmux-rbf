import Combine
import CmuxRestartCommands
import Foundation

/// Main-actor projection over the separate, bounded restart-summary repository.
///
/// This is deliberately not part of `TerminalNotificationStore`: summary
/// mutations must never enter desktop delivery, mobile sync, Dock/workspace
/// badges, hooks, pane effects, or terminal-notification history.
@MainActor
final class RestartCommandRestoreSummaryStore: ObservableObject {
    static let shared = RestartCommandRestoreSummaryStore()

    @Published private(set) var summaries: [RestartCommandRestoreSummary] = []
    @Published private(set) var requestedFocusSummaryID: UUID?

    let repository: RestartCommandRestoreSummaryRepository
    private var nextRequestID: UInt64 = 0
    private var appliedRequestID: UInt64 = 0
    private var operationTail: Task<Void, Never>?

    init(
        repository: RestartCommandRestoreSummaryRepository? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) {
        if let repository {
            self.repository = repository
        } else {
            let fileURL = RestartCommandRestoreSummaryRepository.defaultFileURL(
                bundleIdentifier: bundleIdentifier,
                fileManager: fileManager
            ) ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
                .appendingPathComponent(
                    "restart-command-summaries-com.cmuxterm.app.json",
                    isDirectory: false
                )
            self.repository = RestartCommandRestoreSummaryRepository(
                fileURL: fileURL,
                fileManager: fileManager
            )
        }
        perform { repository in await repository.load() }
    }

    var unreadCount: Int {
        summaries.reduce(into: 0) { count, summary in
            if !summary.isRead { count += 1 }
        }
    }

    func feedItems(
        terminalNotifications: [TerminalNotification]
    ) -> [MacNotificationFeedItem<TerminalNotification>] {
        MacNotificationFeedMerge.merge(
            terminal: terminalNotifications.map {
                (item: $0, createdAt: $0.createdAt, isRead: $0.isRead)
            },
            summaries: summaries
        )
    }

    func menuProjection(
        terminal: NotificationMenuSnapshot
    ) -> MacNotificationMenuProjection {
        MacNotificationMenuProjection(
            unreadCount: terminal.unreadCount + unreadCount,
            hasNotifications: terminal.hasNotifications || !summaries.isEmpty,
            recentNotifications: terminal.recentNotifications
        )
    }

    func requestFocus(id: UUID) {
        requestedFocusSummaryID = id
    }

    func clearFocusRequest(id: UUID) {
        guard requestedFocusSummaryID == id else { return }
        requestedFocusSummaryID = nil
    }

    func insert(_ summary: RestartCommandRestoreSummary) {
        perform { repository in await repository.insert(summary) }
    }

    func setRead(_ isRead: Bool, id: UUID) {
        perform { repository in await repository.setRead(isRead, id: id) }
    }

    func markAllRead() {
        perform { repository in await repository.markAllRead() }
    }

    func remove(id: UUID) {
        perform { repository in await repository.remove(id: id) }
    }

    func clearAll() {
        perform { repository in await repository.clearAll() }
    }

    private func perform(
        _ operation: @escaping @Sendable (
            RestartCommandRestoreSummaryRepository
        ) async -> [RestartCommandRestoreSummary]
    ) {
        nextRequestID &+= 1
        let requestID = nextRequestID
        let repository = repository
        let previousOperation = operationTail
        operationTail = Task { [weak self] in
            await previousOperation?.value
            let snapshot = await operation(repository)
            guard let self, requestID >= appliedRequestID else { return }
            appliedRequestID = requestID
            summaries = snapshot
        }
    }
}

/// Mac menu/popover state that counts both item kinds while preserving the
/// existing terminal-only recent clickable list.
struct MacNotificationMenuProjection: Equatable {
    let unreadCount: Int
    let hasNotifications: Bool
    let recentNotifications: [TerminalNotification]

    var hasUnreadNotifications: Bool { unreadCount > 0 }

    var stateHintTitle: String {
        NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: unreadCount)
    }
}
