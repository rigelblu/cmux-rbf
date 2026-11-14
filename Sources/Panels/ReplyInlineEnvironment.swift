import AppKit
import Combine
import CmuxAgentChat
import Foundation

/// Everything the Reply toolbar reads from, or does to, the world outside its
/// own pane. Production wires the real app; a test passes fakes, which is how
/// the wiring is proven rather than read.
struct ReplyInlineEnvironment {
    /// The cached setting. `cm-136.1` has no off switch, so this is `true`.
    var settingEnabled: () -> Bool
    /// `registry.liveSession(surfaceID:) != nil` — `#cm-89`'s live-only rule.
    var isAgentPane: (UUID) -> Bool
    var hasSelection: (ghostty_surface_t) -> Bool
    var readSelection: (GhosttyNSView, ghostty_surface_t) -> ReplyInlineSelectionGeometry?
    var grid: (ghostty_surface_t) -> ReplyInlineGridGeometry
    /// Whether the window's sidebar is visible **and** showing Reply, as
    /// `#cm-89` reads it.
    var sidebarShowingReply: (NSWindow) -> Bool
    /// Calls `onChange` after any change to the window's sidebar; the caller
    /// re-reads ``sidebarShowingReply``. Cancel to stop observing.
    var observeSidebar: (NSWindow, @escaping () -> Void) -> AnyCancellable?
    /// A window-scoped local monitor for mouse-down and key-down.
    var installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    var removeMonitor: (Any) -> Void
    var pasteTarget: ReplyInlinePasteTarget
    /// DEBUG log lines under `reply.inline`; a no-op in Release.
    var log: (String) -> Void
    /// Seconds between selection compares while a toolbar shows.
    var selectionPollInterval: TimeInterval

    /// Built once. Its closures read the live app when they run, so nothing in
    /// it is captured per release.
    @MainActor
    static let production: ReplyInlineEnvironment = {
        ReplyInlineEnvironment(
            settingEnabled: { true },
            isAgentPane: { panelID in
                TerminalController.shared.agentChatTranscriptService?
                    .registry.liveSession(surfaceID: panelID.uuidString) != nil
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
            sidebarShowingReply: { window in
                // `context.window === window`, as `#cm-89` has it: a pane whose
                // window isn't registered must not read another window's sidebar.
                // On purpose, a window with no registered context sees no sidebar
                // (`false` here, no observer below) rather than another window's.
                guard let context = AppDelegate.shared?
                    .preferredRegisteredMainWindowContext(preferredWindow: window),
                    context.window === window,
                    let sidebar = context.fileExplorerState
                else { return false }
                return sidebar.isVisible && sidebar.mode == .reply
            },
            observeSidebar: { window, onChange in
                guard let context = AppDelegate.shared?
                    .preferredRegisteredMainWindowContext(preferredWindow: window),
                    context.window === window,
                    let sidebar = context.fileExplorerState
                else { return nil }
                // `objectWillChange` fires before the change; hop a run-loop
                // turn so the handler reads the new value.
                return sidebar.objectWillChange.sink { _ in
                    DispatchQueue.main.async { onChange() }
                }
            },
            installMonitor: { handler in
                NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown],
                    handler: handler
                )
            },
            removeMonitor: { NSEvent.removeMonitor($0) },
            pasteTarget: ReplyInlineWorkspacePasteTarget(),
            log: { message in
                #if DEBUG
                cmuxDebugLog("reply.inline \(message)")
                #endif
            },
            selectionPollInterval: 0.1
        )
    }()
}
