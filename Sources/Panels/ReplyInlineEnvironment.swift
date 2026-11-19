import AppKit
import Combine
import CmuxAgentChat
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Everything the Reply toolbar reads from, or does to, the world outside its
/// own pane. Production wires the real app; a test passes fakes, which is how
/// the wiring is proven rather than read.
struct ReplyInlineEnvironment {
    /// `reply.inline.enabled`, read at each release. Not cached: a `UserDefaults`
    /// read is in-process and cheap.
    var settingEnabled: () -> Bool
    /// `#cm-89`'s live-only rule (`registry.liveSession(surfaceID:) != nil`) plus the
    /// pane's shell state: a shell idle at its prompt is no agent (`cm-136.9`).
    var isAgentPane: (UUID) -> Bool
    var hasSelection: (ghostty_surface_t) -> Bool
    var readSelection: (GhosttyNSView, ghostty_surface_t) -> ReplyInlineSelectionGeometry?
    var grid: (ghostty_surface_t) -> ReplyInlineGridGeometry
    /// Where the passage goes when the button is clicked, for this window and
    /// the passage's pane (`cm-136.7`). `.replyPanel` labels the button
    /// `Add to reply`; every other state is `.prompt`, today's `Reply`.
    var destination: (NSWindow, UUID) -> ReplyInlineDestination
    /// Calls `onChange` after any change to what ``destination`` reads; the
    /// caller re-reads ``destination``. Cancel to stop observing.
    var observeDestination: (NSWindow, UUID, @escaping () -> Void) -> AnyCancellable?
    /// Calls `onChange` after any defaults write in the app; the caller re-reads
    /// ``settingEnabled``. Fires for every write, so it is held only while a
    /// toolbar shows. Cancel to stop observing.
    var observeSetting: (@escaping () -> Void) -> AnyCancellable?
    /// A window-scoped local monitor for mouse-down and key-down.
    var installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    var removeMonitor: (Any) -> Void
    var pasteTarget: ReplyInlinePasteTarget
    /// Adds the passage to the Reply panel's reply (`cm-136.7`). The view is the
    /// pane's scroll view: the keyboard is taken off it, or off the terminal inside it.
    var openReply: (TerminalReplyRequest, NSWindow, NSView?) -> Void
    /// The next request number, from the sequence every entrance shares.
    var nextReplySeq: () -> Int
    /// DEBUG log lines under `reply.inline`; a no-op in Release.
    var log: (String) -> Void
    /// Seconds between selection compares while a toolbar shows.
    var selectionPollInterval: TimeInterval

    /// Built once. Its closures read the live app when they run, so nothing in
    /// it is captured per release.
    @MainActor
    static let production: ReplyInlineEnvironment = {
        ReplyInlineEnvironment(
            settingEnabled: { SettingCatalog().reply.inlineEnabled.value(in: .standard) },
            isAgentPane: { panelID in
                let hasLive = TerminalController.shared.agentChatTranscriptService?
                    .registry.liveSession(surfaceID: panelID.uuidString) != nil
                // The pane's shell state is read only for a live session: it walks every window.
                guard hasLive else { return false }
                return ReplyInlineAgentPaneRule.counts(
                    hasLiveSession: true,
                    shellState: shellState(of: panelID)
                )
            },
            hasSelection: { ghostty_surface_has_selection($0) },
            readSelection: { view, surface in
                guard let snapshot = view.readSelectionSnapshot(surface: surface) else { return nil }
                return ReplyInlineSelectionGeometry(
                    text: snapshot.string,
                    topLeftX: Double(snapshot.topLeft.x),
                    baselineY: Double(snapshot.topLeft.y),
                    offsetStart: snapshot.range.location,
                    distanceToBottomRight: snapshot.range.length
                )
            },
            grid: { surface in
                var metrics = ghostty_surface_grid_metrics_s()
                guard ghostty_surface_grid_metrics(surface, &metrics),
                      metrics.cell_height.isFinite, metrics.padding_top.isFinite else {
                    // Zero columns reads as "can't place": the trigger ignores it.
                    return ReplyInlineGridGeometry(columns: 0, cellHeight: 0, paddingTop: 0)
                }
                return ReplyInlineGridGeometry(
                    columns: Int(metrics.columns),
                    cellHeight: metrics.cell_height,
                    paddingTop: metrics.padding_top
                )
            },
            destination: { window, sourcePanelID in
                guard let store = replyStore(holding: sourcePanelID) else { return .prompt }
                return ReplyInlineDestination.resolve(
                    sidebarShowingReply: sidebarShowingReply(in: window),
                    boundPanelID: store.boundPanelID,
                    sourcePanelID: sourcePanelID,
                    viewingOlderReply: store.model.viewedGroupID != nil
                )
            },
            observeDestination: { window, sourcePanelID, onChange in
                let sidebar = sidebarObservation(in: window, onChange: onChange)
                let store = replyStore(holding: sourcePanelID).map {
                    ReplyStoreWatch(store: $0, onChange: onChange)
                }
                return AnyCancellable {
                    sidebar?.cancel()
                    store?.cancel()
                }
            },
            observeSetting: { onChange in
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                    .receive(on: DispatchQueue.main)
                    .sink { _ in onChange() }
            },
            installMonitor: { handler in
                NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown],
                    handler: handler
                )
            },
            removeMonitor: { NSEvent.removeMonitor($0) },
            pasteTarget: ReplyInlineWorkspacePasteTarget(),
            openReply: { request, window, pane in
                guard let sidebar = registeredSidebar(in: window) else { return }
                TerminalReplyOpener.open(request, sidebar: sidebar, window: window, from: pane)
            },
            nextReplySeq: { TerminalReplyOpener.nextSeq() },
            log: { message in
                #if DEBUG
                cmuxDebugLog("reply.inline \(message)")
                #endif
            },
            selectionPollInterval: 0.1
        )
    }()

    /// This window's own sidebar, as `#cm-89` finds it.
    ///
    /// `context.window === window`: a pane whose window isn't registered must
    /// not read, watch or open another window's sidebar. On purpose, a window
    /// with no registered context has no sidebar here rather than another
    /// window's: nothing shows as Reply, nothing is watched, nothing opens.
    @MainActor
    private static func registeredSidebar(in window: NSWindow) -> FileExplorerState? {
        guard let context = AppDelegate.shared?
            .preferredRegisteredMainWindowContext(preferredWindow: window),
            context.window === window
        else { return nil }
        return context.fileExplorerState
    }

    /// Whether the window's sidebar is visible **and** showing Reply, as
    /// `#cm-89` reads it.
    @MainActor
    private static func sidebarShowingReply(in window: NSWindow) -> Bool {
        guard let sidebar = registeredSidebar(in: window) else { return false }
        return sidebar.isVisible && sidebar.mode == .reply
    }

    /// Calls `onChange` after any change to the window's sidebar. `objectWillChange`
    /// fires before the change, so the sink hops a run-loop turn first.
    @MainActor
    private static func sidebarObservation(
        in window: NSWindow,
        onChange: @escaping () -> Void
    ) -> AnyCancellable? {
        guard let sidebar = registeredSidebar(in: window) else { return nil }
        return sidebar.objectWillChange.sink { _ in
            DispatchQueue.main.async { onChange() }
        }
    }

    /// The shell state of the pane showing `surfaceID` (a terminal panel's id is its
    /// surface's id), `.unknown` when no workspace holds it. A window Dock's pane, and
    /// any pane `locateSurface` doesn't find (a remote tmux pane), reads `.unknown`, so
    /// the gate keeps the live-only answer there.
    @MainActor
    private static func shellState(of surfaceID: UUID) -> PanelShellActivityState {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
        else { return .unknown }
        return workspace.panelShellActivityStates[surfaceID] ?? .unknown
    }

    /// The Reply store of the workspace that holds the pane, if it has one
    /// (`cm-136.7`). Set when Reply binds in that workspace.
    @MainActor
    private static func replyStore(holding surfaceID: UUID) -> ReplyPanelStore? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
        else { return nil }
        return workspace.replyPanelAgentChoiceStore
    }
}

/// Calls `onChange` after a change to a Reply store's binding or to the reply
/// it is on (`cm-136.7`). `withObservationTracking` reports one change per
/// arming, so the watch re-arms after each.
@MainActor
private final class ReplyStoreWatch {
    private let store: ReplyPanelStore
    private let onChange: () -> Void
    private var isCancelled = false

    init(store: ReplyPanelStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        arm()
    }

    func cancel() {
        isCancelled = true
    }

    private func arm() {
        guard !isCancelled else { return }
        withObservationTracking {
            _ = store.boundPanelID
            _ = store.model.viewedGroupID
        } onChange: { [weak self] in
            // A run-loop turn later, so the callback reads the new value.
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.onChange()
                self.arm()
            }
        }
    }
}
