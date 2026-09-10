import AppKit
import CmuxFoundation
import CmuxTerminal

@MainActor
final class MainWindowFocusController {
    private enum EffectiveFocusOwner {
        case mainPanel
        case rightSidebar
        case unknown
    }

    private enum RightSidebarFocusTarget: Equatable {
        case host
        case outline
        case searchField
        case firstItem
    }

    private struct RightSidebarFocusRequest: Equatable {
        let id: UInt64
        let mode: RightSidebarMode
        let target: RightSidebarFocusTarget
    }

    private enum RightSidebarFocusState: Equatable {
        case inactive
        case requested(RightSidebarFocusRequest)
        case focused(mode: RightSidebarMode, target: RightSidebarFocusTarget)

        var mode: RightSidebarMode? {
            switch self {
            case .inactive:
                return nil
            case .requested(let request):
                return request.mode
            case .focused(let mode, _):
                return mode
            }
        }

        var request: RightSidebarFocusRequest? {
            if case .requested(let request) = self {
                return request
            }
            return nil
        }
    }

    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?
    private weak var fileExplorerState: FileExplorerState?
    private weak var rightSidebarHost: RightSidebarKeyboardFocusView?
    private weak var fileExplorerHost: FileExplorerContainerView?
    private weak var fileSearchHost: FileExplorerContainerView?
    private weak var feedHost: FeedKeyboardFocusView?
    private weak var dockHost: DockKeyboardFocusView?
    /// Reply's owner is the page's own web view, handed over by
    /// `MarkdownWebRenderer` while it is mounted.
    ///
    /// Unlike the four hosts above it is not a container that *finds* the
    /// focused view — it **is** the view that takes the keyboard, which is what
    /// lets `focusRightSidebarEndpoint` make it first responder rather than
    /// only recognise it.
    private weak var replyHost: MarkdownWebView?

    private(set) var intent: MainWindowKeyboardFocusIntent? {
        didSet {
            syncBonsplitTabShortcutHintEligibility()
            publishRightSidebarOwnsInputFocus()
        }
    }

    /// Mirror the exclusive focus intent into `FileExplorerState` so the view
    /// layer can make main-pane vs right-sidebar (Dock) focus mutually exclusive.
    private func publishRightSidebarOwnsInputFocus() {
        let ownsFocus: Bool
        if case .rightSidebar = intent { ownsFocus = true } else { ownsFocus = false }
        guard let fileExplorerState, fileExplorerState.rightSidebarOwnsInputFocus != ownsFocus else { return }
        fileExplorerState.rightSidebarOwnsInputFocus = ownsFocus
    }
    private var rememberedRightSidebarMode: RightSidebarMode?
    private var nextRightSidebarFocusRequestId: UInt64 = 0
    private var rightSidebarFocusState: RightSidebarFocusState = .inactive
    /// The right sidebar's active mode when it owns focus, else `nil`. Surfaces the
    /// private focus state for the `sidebarMode` keyboard-shortcut context key.
    var activeRightSidebarMode: RightSidebarMode? {
        rightSidebarFocusState.mode
    }
    private var feedSelectedItemId: UUID?
    private var lastPublishedFeedFocusSnapshot = FeedFocusSnapshot()

    init(
        windowId: UUID,
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.windowId = windowId
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        self.rememberedRightSidebarMode = fileExplorerState?.mode
        syncBonsplitTabShortcutHintEligibility()
    }

    func update(
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        if rememberedRightSidebarMode == nil {
            rememberedRightSidebarMode = fileExplorerState?.mode
        }
        syncBonsplitTabShortcutHintEligibility()
        publishFeedFocusSnapshot()
    }

    func registerRightSidebarHost(_ host: RightSidebarKeyboardFocusView) {
        rightSidebarHost = host
        if let mode = rightSidebarFocusState.request?.mode {
            focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
        }
    }

    func registerFileExplorerHost(_ host: FileExplorerContainerView) {
        let mode = host.representedRightSidebarMode()
        switch mode {
        case .files:
            fileExplorerHost = host
        case .find:
            fileSearchHost = host
        case .sessions, .feed, .dock, .reply, .customSidebar:
            break
        }
        focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
    }

    func registerFeedHost(_ host: FeedKeyboardFocusView) {
        feedHost = host
        publishFeedFocusSnapshot(force: true)
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .feed)
    }

    func registerDockHost(_ host: DockKeyboardFocusView) {
        dockHost = host
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .dock)
    }

    func registerReplyHost(_ host: MarkdownWebView?) {
        replyHost = host
        guard host != nil else { return }
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .reply)
    }

    /// Whether `responder` is Reply's web view or something inside it.
    ///
    /// The descendant arm is not defensive: a note field's editor is an
    /// `NSTextView` living under the page, so an identity check alone would
    /// hand the keyboard back to the terminal the moment a note is open.
    private func replyOwns(_ responder: NSResponder) -> Bool {
        // `replyHost` is weak, but detaching a web view does not deallocate it
        // — `MarkdownWebRenderer` caches and re-parents the same instance. So
        // a registration outlives its mount, and the staleness guard lives
        // here rather than in an unregister path that would have to find a
        // window it no longer has. Requiring *this* window also settles the
        // two-window case: each coordinator answers only for its own.
        guard let host = replyHost, let hostWindow = host.window, hostWindow === window else {
            return false
        }
        if responder === host { return true }
        guard let view = responder as? NSView ?? (responder as? NSTextView)?.delegate as? NSView else {
            return false
        }
        return view === host || view.isDescendant(of: host)
    }

    func noteRightSidebarInteraction(mode: RightSidebarMode) {
        rememberedRightSidebarMode = mode
        rightSidebarFocusState = .focused(mode: mode, target: .host)
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
    }

    func rememberRightSidebarMode(_ mode: RightSidebarMode) {
        rememberedRightSidebarMode = mode
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelInteraction(workspaceId: UUID, panelId: UUID) {
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
        publishFeedFocusSnapshot()
    }

    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        if GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId) {
            return true
        }
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel, nil:
            return true
        }
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard ShortcutHintDebugSettings().modifierHoldHintsEnabled else { return false }
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel(let focusedWorkspaceId, _):
            return focusedWorkspaceId == workspaceId
        case nil:
            return true
        }
    }

    func ownsRightSidebarFocus(_ responder: NSResponder) -> Bool {
        if let host = rightSidebarHost, responder === host {
            return true
        }
        if responder is FeedKeyboardFocusResponder {
            return true
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true ||
            fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if feedHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if replyOwns(responder) {
            return true
        }
        return false
    }

    func shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: NSResponder?) -> Bool {
        if case .rightSidebar = intent {
            return true
        }
        guard let currentResponder else { return false }
        return ownsRightSidebarFocus(currentResponder)
    }

    @discardableResult
    func restoreTerminalFocusAfterRightSidebarHiddenIfNeeded() -> Bool {
        guard shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: window?.firstResponder) else {
            return false
        }
        return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
    }

    @discardableResult
    func restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: NSResponder? = nil) -> Bool {
        let responder = currentResponder ?? window?.firstResponder
        let ownsResponder = responder.map(ownsRightSidebarFocus) ?? false
        let ownsIntent: Bool = {
            if case .rightSidebar = intent {
                return true
            }
            return false
        }()
        guard ownsResponder || ownsIntent else {
            return false
        }

        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
        }

        rightSidebarFocusState = .inactive

        if panel is TerminalPanel {
            return focusTerminal()
        }

        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        if let window,
           let responder,
           ownsRightSidebarFocus(responder) {
            _ = window.makeFirstResponder(nil)
        }
        publishFeedFocusSnapshot()
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    @discardableResult
    func restoreTargetAfterWindowBecameKey() -> Bool {
        switch intent {
        case .rightSidebar(let mode):
            return restoreRightSidebarTargetAfterWindowBecameKey(mode: mode)
        case .mainPanel:
            return restoreMainPanelTargetAfterWindowBecameKey()
        case nil:
            return false
        }
    }

    @discardableResult
    private func restoreRightSidebarTargetAfterWindowBecameKey(mode: RightSidebarMode) -> Bool {
        if let responder = window?.firstResponder,
           rightSidebarModeOwning(responder) == mode {
            publishFeedFocusSnapshot()
            return true
        }
        if let request = rightSidebarFocusState.request, request.mode == mode {
            return focusRightSidebar(mode: mode, target: request.target)
        }
        if mode == .find {
            return focusFileSearch()
        }
        return focusRightSidebar(
            mode: mode,
            focusFirstItem: false
        )
    }

    @discardableResult
    private func restoreMainPanelTargetAfterWindowBecameKey() -> Bool {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return false
        }

        if let responder = window.firstResponder {
            if panel.ownedFocusIntent(for: responder, in: window) != nil {
                noteMainPanelInteraction(workspaceId: workspace.id, panelId: panelId)
                return true
            }
            if liveRightSidebarModeOwning(responder, in: window) != nil {
                syncAfterResponderChange(responder: responder)
                return true
            }
            if terminalFocusRequest(for: responder) == nil,
               selectedFocusedPanelRequest(owning: responder) == nil,
               shouldRespectForeignFirstResponder(responder, in: window, isRightSidebarOwner: {
                   liveRightSidebarModeOwning($0, in: window) != nil
               }) {
                return false
            }
        }

        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        publishFeedFocusSnapshot()
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    private func liveRightSidebarModeOwning(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> RightSidebarMode? {
        guard (responder as? NSView)?.window === window else { return nil }
        return rightSidebarModeOwning(responder)
    }

    @discardableResult
    func selectFeedItem(_ id: UUID, focusFeed: Bool) -> Bool {
        feedSelectedItemId = id
        rememberedRightSidebarMode = .feed
        rightSidebarFocusState = .focused(mode: .feed, target: .host)
        intent = .rightSidebar(mode: .feed)
        publishFeedFocusSnapshot()

        guard focusFeed else {
            return true
        }
        return focusRightSidebar(mode: .feed, focusFirstItem: false)
    }

    func feedFocusSnapshot() -> FeedFocusSnapshot {
        guard feedSelectedItemId != nil else {
            return FeedFocusSnapshot()
        }
        return FeedFocusSnapshot(
            selectedItemId: feedSelectedItemId,
            isKeyboardActive: isFeedKeyboardIntentActive()
        )
    }

    func syncAfterResponderChange() {
        syncAfterResponderChange(responder: window?.firstResponder)
    }

#if DEBUG
    var debugPendingRightSidebarFocusMode: RightSidebarMode? {
        rightSidebarFocusState.request?.mode
    }

    func debugSyncAfterResponderChange(responder: NSResponder?) {
        syncAfterResponderChange(responder: responder)
    }
#endif

    private func syncAfterResponderChange(responder: NSResponder?) {
        guard let responder else {
            publishFeedFocusSnapshot()
            return
        }
        if let terminal = terminalFocusRequest(for: responder) {
            if rightSidebarFocusState.request != nil {
                publishFeedFocusSnapshot()
                return
            }
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
            return
        }
        if let mode = rightSidebarModeOwning(responder) {
            let isFallbackSidebarHost = rightSidebarHost.map { responder === $0 } ?? false
            if !canAcceptRightSidebarResponderFocus(
                mode: mode,
                isFallbackSidebarHost: isFallbackSidebarHost
            ) {
                publishFeedFocusSnapshot()
                return
            }
            rememberedRightSidebarMode = mode
            completeRightSidebarFocusFromResponder(mode: mode, isFallbackSidebarHost: isFallbackSidebarHost)
            intent = .rightSidebar(mode: mode)
            if mode != .feed {
                feedSelectedItemId = nil
            }
            publishFeedFocusSnapshot()
            return
        }
        if rightSidebarFocusState.request != nil {
            publishFeedFocusSnapshot()
            return
        }
        if let mainPanel = selectedFocusedPanelRequest(owning: responder) {
            noteMainPanelInteraction(workspaceId: mainPanel.workspaceId, panelId: mainPanel.panelId)
            return
        }
        publishFeedFocusSnapshot()
    }

    private func canAcceptRightSidebarResponderFocus(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) -> Bool {
        guard let request = rightSidebarFocusState.request else {
            return true
        }
        if responderMode != request.mode {
            return false
        }
        if isFallbackSidebarHost, request.target != .host {
            return false
        }
        return true
    }

    private func completeRightSidebarFocusFromResponder(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) {
        guard let request = rightSidebarFocusState.request else {
            rightSidebarFocusState = .focused(mode: responderMode, target: .host)
            return
        }
        guard request.mode == responderMode else { return }
        if isFallbackSidebarHost, request.target != .host {
            return
        }
        rightSidebarFocusState = .focused(mode: request.mode, target: request.target)
    }

    @discardableResult
    func focusRightSidebar(mode requestedMode: RightSidebarMode? = nil, focusFirstItem: Bool = true) -> Bool {
        guard let state = fileExplorerState else { return false }
        let desiredMode = requestedMode ?? rememberedRightSidebarMode ?? state.mode
        guard desiredMode.isAvailable() else {
            guard requestedMode == nil else { return false }
            return focusRightSidebar(mode: .files, focusFirstItem: focusFirstItem)
        }
        let mode = desiredMode
        let target = rightSidebarFocusTarget(mode: mode, focusFirstItem: focusFirstItem)
        return focusRightSidebar(mode: mode, target: target, terminalYieldReason: "rightSidebarFocus")
    }

    @discardableResult
    private func focusRightSidebar(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget,
        terminalYieldReason: String = "rightSidebarFocus"
    ) -> Bool {
        guard let state = fileExplorerState else { return false }
        guard mode.isAvailable() else { return false }
        rememberedRightSidebarMode = mode
        beginRightSidebarFocusRequest(mode: mode, target: target)
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: terminalYieldReason)
        state.setVisible(true)
        if state.mode != mode {
            state.mode = mode
        }

        let modeResult = focusRightSidebarEndpoint(mode: mode, target: target)
        if modeResult {
            rightSidebarFocusState = .focused(mode: mode, target: target)
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        if fallbackResult, target == .host {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
        let result = modeResult || fallbackResult || rightSidebarFocusState.request?.mode == mode
        publishFeedFocusSnapshot()
        return result
    }

    @discardableResult
    func focusFileSearch() -> Bool {
        return focusRightSidebar(
            mode: .find,
            target: .searchField,
            terminalYieldReason: "fileSearchFocus"
        )
    }

    @discardableResult
    func toggleRightSidebarOrTerminalFocus(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true
    ) -> Bool {
        switch focusToggleDestination() {
        case .terminal:
            return restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: window?.firstResponder)
        case .rightSidebar:
            return focusRightSidebar(mode: requestedMode, focusFirstItem: focusFirstItem)
        }
    }

    /// Toggles the keyboard between the terminal and one *specific* sidebar mode.
    ///
    /// `toggleRightSidebarOrTerminalFocus()` is mode-blind: it yields to the
    /// terminal whenever the sidebar owns focus, whichever panel is showing. That
    /// is wrong for a per-mode key — pressing "go to Reply" while Files holds
    /// focus should switch to Reply, not leave the sidebar.
    ///
    /// The showing-mode test reads `fileExplorerState.mode`, the panel actually on
    /// screen, deliberately *not* `activeRightSidebarMode`: that resolves through
    /// `RightSidebarFocusState.mode`, which answers for `.requested` as well as
    /// `.focused`, so it reports a mode whose focus was only ever asked for.
    func toggleRightSidebarModeOrTerminalFocus(
        mode: RightSidebarMode,
        focusFirstItem: Bool = true
    ) -> Bool {
        let isShowingRequestedMode = fileExplorerState?.mode == mode
        if isShowingRequestedMode, focusToggleDestination() == .terminal {
            return restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: window?.firstResponder)
        }
        guard modeHasFocusableHost(mode) else {
            return revealRightSidebarWithoutTakingKeyboard(mode: mode)
        }
        return focusRightSidebar(mode: mode, focusFirstItem: focusFirstItem)
    }

    /// Whether `mode` currently owns a responder that can actually hold the
    /// keyboard.
    ///
    /// Only `.reply` is answered, because it is the only mode whose panel can be
    /// on screen with **no** host registered: `MarkdownWebRenderer` registers
    /// `replyHost` when it mounts a reply, so a workspace whose agent session has
    /// not been opened yet renders no web view at all. Measured 2026-09-09 —
    /// `←` at `fr=RightSidebarKeyboardFocusView` produced no
    /// `consumed by original performKeyEquivalent`, against a control 23s earlier
    /// at `fr=MarkdownWebView` that did. Every other mode keeps its existing
    /// behaviour rather than being guessed at.
    private func modeHasFocusableHost(_ mode: RightSidebarMode) -> Bool {
        guard mode == .reply else { return true }
        guard let window, let host = replyHost, host.window === window else { return false }
        return true
    }

    /// Shows `mode` in the sidebar but leaves the keyboard where it was.
    ///
    /// The alternative is what shipped first: `focusRightSidebar` yields the
    /// terminal's focus *before* asking the endpoint, so when the endpoint has
    /// nothing to focus the keyboard lands on the 1x1 fallback host. Asking to
    /// read a reply that does not exist should not cost the keyboard.
    ///
    /// This type does no logging, so read the case off `AppDelegate`'s wrapper:
    /// `rs.focus.modeToggle.begin fr=GhosttyNSView` followed by
    /// `.end result=1 fr=GhosttyNSView` is a reveal-without-focus. The
    /// toggle-back-to-terminal case ends the same way but *begins* at
    /// `fr=MarkdownWebView`, so the pair disambiguates — the end line alone
    /// does not.
    private func revealRightSidebarWithoutTakingKeyboard(mode: RightSidebarMode) -> Bool {
        guard let state = fileExplorerState, mode.isAvailable() else { return false }
        rememberedRightSidebarMode = mode
        state.setVisible(true)
        if state.mode != mode {
            state.mode = mode
        }
        return true
    }

    func focusToggleDestination(currentResponder: NSResponder? = nil) -> MainWindowFocusToggleDestination {
        switch effectiveFocusOwner(currentResponder: currentResponder) {
        case .rightSidebar:
            return .terminal
        case .mainPanel, .unknown:
            return .rightSidebar
        }
    }

    func findShortcutTarget(currentResponder: NSResponder? = nil) -> MainWindowFindShortcutTarget {
        let responder = currentResponder ?? window?.firstResponder
        if let responder {
            if let mode = rightSidebarModeOwning(responder) {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanelFind
            }
            if selectedFocusedPanelIsBrowser() {
                return .mainPanelFind
            }
            if case .rightSidebar(let mode) = intent {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            return .mainPanelFind
        }

        if case .rightSidebar(let mode) = intent {
            return findShortcutTarget(forRightSidebarMode: mode)
        }
        return .mainPanelFind
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return false
        }
        guard let terminalPanel = workspace.focusedTerminalInputTarget()?.panel else { return false }
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: terminalPanel.id)
        publishFeedFocusSnapshot()
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        return terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func findShortcutTarget(forRightSidebarMode mode: RightSidebarMode) -> MainWindowFindShortcutTarget {
        mode == .files ? .rightSidebarFileSearch : .none
    }

    private func selectedFocusedPanelIsBrowser() -> Bool {
        selectedFocusedBrowserPanelRequest() != nil
    }

    private struct FocusedPanelRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func selectedFocusedPanelRequest(owning responder: NSResponder) -> FocusedPanelRequest? {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        for (panelId, panel) in workspace.panels {
            guard panelId != workspace.focusedPanelId,
                  panel.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        return nil
    }

    private func selectedFocusedBrowserPanelRequest() -> FocusedPanelRequest? {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        guard panel is BrowserPanel else {
            return nil
        }
        return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
    }

    private func focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: Bool) -> Bool {
        let focused = focusTerminal()
        if focused {
            return true
        }

        if let window,
           let responder = window.firstResponder,
           ownsRightSidebarFocus(responder) {
            window.makeFirstResponder(nil)
        }

        rightSidebarFocusState = .inactive
        if clearUnavailableIntent, case .rightSidebar = intent {
            intent = nil
        }
        publishFeedFocusSnapshot()
        return false
    }

    private func effectiveFocusOwner(currentResponder: NSResponder? = nil) -> EffectiveFocusOwner {
        if let responder = currentResponder ?? window?.firstResponder {
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanel
            }
            if rightSidebarModeOwning(responder) != nil {
                return .rightSidebar
            }
            if selectedFocusedPanelRequest(owning: responder) != nil {
                return .mainPanel
            }
        }

        switch intent {
        case .mainPanel:
            return .mainPanel
        case .rightSidebar:
            return .rightSidebar
        case nil:
            return .unknown
        }
    }

    private func focusRegisteredRightSidebarEndpointIfNeeded(mode: RightSidebarMode) {
        guard let request = rightSidebarFocusState.request else {
            return
        }
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              request.mode == mode else {
            return
        }
        let result = focusRightSidebarEndpoint(mode: mode, target: request.target)
        if result {
            rightSidebarFocusState = .focused(mode: mode, target: request.target)
        } else if request.target == .host, focusFallbackRightSidebarHost() {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
        publishFeedFocusSnapshot()
    }

    private func beginRightSidebarFocusRequest(mode: RightSidebarMode, target: RightSidebarFocusTarget) {
        nextRightSidebarFocusRequestId &+= 1
        rightSidebarFocusState = .requested(
            RightSidebarFocusRequest(
                id: nextRightSidebarFocusRequestId,
                mode: mode,
                target: target
            )
        )
    }

    private func rightSidebarFocusTarget(
        mode: RightSidebarMode,
        focusFirstItem: Bool
    ) -> RightSidebarFocusTarget {
        switch mode {
        case .files:
            return .outline
        case .find:
            return .searchField
        case .sessions, .reply, .customSidebar:
            return .host
        case .feed:
            return focusFirstItem ? .firstItem : .host
        case .dock:
            return focusFirstItem ? .firstItem : .host
        }
    }

    private func focusRightSidebarEndpoint(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget
    ) -> Bool {
        switch mode {
        case .files:
            return fileExplorerHost?.focusOutline() == true
        case .find:
            return fileSearchHost?.focusSearchField() == true
        case .sessions, .customSidebar:
            return mode == .customSidebar ? focusFallbackRightSidebarHost() : false
        case .reply:
            // `#cm-77`. This returned `false` from `cm-69.1` until 2026-09-09,
            // because no Reply-owned responder existed to hand the keyboard
            // to. `cm-69.1b` supplied one — `replyHost`, the page's own web
            // view — and the stale `false` was doing active harm: it is what
            // made `focusRightSidebar` fall through to
            // `focusFallbackRightSidebarHost()`, parking the keyboard on the
            // 1x1 `RightSidebarKeyboardFocusView`, whose `keyDown` drops every
            // character-bearing key. Measured: the last six `←` of Scenario 4e
            // read `fr=RightSidebarKeyboardFocusView`.
            //
            // This is the single choke point for **every** route into Reply
            // focus — the mode shortcut and the palette, not just the note
            // field that got measured.
            //
            // Still honest when there is nothing to focus: an unregistered or
            // detached host returns `false` and the old fallback runs, which
            // is the pre-`cm-69.1b` behaviour rather than a new failure.
            guard let window, let host = replyHost, host.window === window else {
                return false
            }
            return window.makeFirstResponder(host)
        case .feed:
            if target == .firstItem {
                feedHost?.focusFirstItemFromCoordinator()
            }
            return feedHost?.focusHostFromCoordinator() == true
        case .dock:
            if target == .firstItem {
                dockHost?.focusFirstItemFromCoordinator()
            }
            return dockHost?.focusHostFromCoordinator() == true
        }
    }

    private func focusFallbackRightSidebarHost() -> Bool {
        guard let window,
              let host = rightSidebarHost else {
            return false
        }
        return window.makeFirstResponder(host)
    }

    private func yieldCurrentTerminalSurfaceFocus(reason: String) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return
        }
        workspace.focusedTerminalInputTarget()?.panel.hostedView
            .yieldTerminalSurfaceFocusForForeignResponder(reason: reason)
    }

    private func isFeedKeyboardIntentActive() -> Bool {
        if rightSidebarFocusState.mode == .feed {
            return true
        }
        if let responder = window?.firstResponder,
           rightSidebarModeOwning(responder) == .feed {
            return true
        }
        return false
    }

    private func publishFeedFocusSnapshot(force: Bool = false) {
        let snapshot = feedFocusSnapshot()
        guard force || snapshot != lastPublishedFeedFocusSnapshot else { return }
        lastPublishedFeedFocusSnapshot = snapshot
        feedHost?.applyFocusSnapshotFromController(snapshot)
    }

    func syncBonsplitTabShortcutHintEligibility() {
        guard let tabManager else { return }
        for workspace in tabManager.tabs {
            let enabled = allowsBonsplitTabShortcutHints(workspaceId: workspace.id)
            if workspace.bonsplitController.tabShortcutHintsEnabled != enabled {
                workspace.bonsplitController.tabShortcutHintsEnabled = enabled
            }
        }
    }

    private func rightSidebarModeOwning(_ responder: NSResponder) -> RightSidebarMode? {
        if let host = rightSidebarHost, responder === host {
            return fileExplorerState?.mode ?? rememberedRightSidebarMode
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return .files
        }
        if fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return .find
        }
        if feedHost?.ownsKeyboardFocus(responder) == true || responder is FeedKeyboardFocusResponder {
            return .feed
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return .dock
        }
        if replyOwns(responder) {
            return .reply
        }
        return nil
    }

    private struct TerminalFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func terminalFocusRequest(for responder: NSResponder?) -> TerminalFocusRequest? {
        guard let ghosttyView = responder.cmuxTerminalFocusOwningGhosttyView(),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        if GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalFocusRequest(workspaceId: workspaceId, panelId: panelId)
    }
}
