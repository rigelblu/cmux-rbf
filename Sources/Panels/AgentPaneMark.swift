import Foundation

// cmux-rbf #cm-126.3: the Agent Pane, a browser pane one agent's terminal owns.

/// The answered state of an Agent Pane (cmux-rbf #cm-126.14).
///
/// An Agent Pane begins in `.post` when opened or steered with a new post.
/// When Tom writes back (pressing Return in the owning terminal or submitting
/// via cmux's text box), it moves to `.wroteSince(Date)`.
/// When cleared, it moves to `.cleared`.
enum AgentPaneAnswerState: Equatable, Sendable {
    case post
    case wroteSince(Date)
    case cleared

    enum Event: Equatable, Sendable {
        case show
        case clear
        case tomWrote(at: Date)
    }

    /// Pure transition function for AgentPaneAnswerState.
    ///
    /// Table:
    /// - any + show -> .post
    /// - any + clear -> .cleared
    /// - .post + tomWrote(t) -> .wroteSince(t)
    /// - .wroteSince + tomWrote -> unchanged (first time kept)
    /// - .cleared + tomWrote -> .cleared
    static func next(state: AgentPaneAnswerState, event: Event) -> AgentPaneAnswerState {
        switch event {
        case .show:
            return .post
        case .clear:
            return .cleared
        case .tomWrote(let date):
            switch state {
            case .post:
                return .wroteSince(date)
            case .wroteSince:
                return state
            case .cleared:
                return .cleared
            }
        }
    }

    var wroteAt: Date? {
        if case .wroteSince(let date) = self {
            return date
        }
        return nil
    }

    var isPost: Bool {
        self == .post
    }

    var isCleared: Bool {
        self == .cleared
    }
}

/// The Agent Pane's rules, all over plain values so each tests without the app.
///
/// An Agent Pane is a browser pane with an owner (the terminal's
/// `stableSurfaceId`, `cm-73.45`'s field) and the kind ``BrowserOwnedKind/agentPane``.
/// It is recognized by those two stored values, never by its address: the mark,
/// keep-loaded, the lookup and the placement rule all read them, so no page the
/// agent or a click loads turns an Agent Pane into a plain pane, or the other way.
enum AgentPaneMark {

    /// One browser pane, as the rules read it.
    struct Candidate: Equatable {
        let panelID: UUID
        let owner: UUID?
        let kind: BrowserOwnedKind?
    }

    /// What `show` does for a caller: open an Agent Pane beside its terminal, or
    /// steer the first one it already owns.
    enum Placement: Equatable {
        case open
        /// `others`: how many more panes that terminal owns in the workspace.
        case navigate(UUID, others: Int)
    }

    /// An Agent Pane has an owner and the Agent Pane kind. A Figma pane `cm-73.45` gave
    /// an owner has no kind, so it is never one.
    static func isAgentPaneKind(owner: UUID?, kind: BrowserOwnedKind?) -> Bool {
        owner != nil && kind == .agentPane
    }

    /// The panes `owner` owns among `candidates`, in the order given.
    static func panes(ownedBy owner: UUID, among candidates: [Candidate]) -> [UUID] {
        candidates
            .filter { isAgentPaneKind(owner: $0.owner, kind: $0.kind) && $0.owner == owner }
            .map(\.panelID)
    }

    /// None → open one; otherwise steer the first and count the rest.
    /// Additional owned panes are reported, never closed.
    static func placement(panes: [UUID]) -> Placement {
        guard let first = panes.first else { return .open }
        return .navigate(first, others: panes.count - 1)
    }

    /// Whether a pane holding these tabs holds an Agent Pane, so a tab that would
    /// land there splits instead.
    static func paneHoldsAgentPane(_ tabs: [Candidate]) -> Bool {
        tabs.contains { isAgentPaneKind(owner: $0.owner, kind: $0.kind) }
    }

    /// The picture a tab is handed: the mark for an Agent Pane, whatever the page's
    /// own icon, so a page can't make an Agent Pane look like Tom's own tab; else
    /// `own`.
    static func picture(isAgentPaneKind: Bool, own: Data?) -> Data? {
        isAgentPaneKind ? shippedPicture : own
    }

    /// A page cannot replace the Agent Pane's caption with its own title.
    ///
    /// When `wroteAt` is set, the caption reads "You wrote <time>" in place of "Agent Pane"
    /// (cmux-rbf #cm-126.14). A plain browser pane keeps `own` unchanged.
    static func title(
        isAgentPaneKind: Bool,
        own: String,
        wroteAt: Date? = nil,
        locale: Locale? = nil,
        timeZone: TimeZone? = nil
    ) -> String {
        guard isAgentPaneKind else { return own }
        if let wroteAt {
            let timeString: String
            if locale == nil && timeZone == nil {
                timeString = wroteAt.formatted(date: .omitted, time: .shortened)
            } else {
                let style = Date.FormatStyle(
                    date: .omitted,
                    time: .shortened,
                    locale: locale ?? .autoupdatingCurrent,
                    timeZone: timeZone ?? .current
                )
                timeString = wroteAt.formatted(style)
            }
            return String(localized: "agentPane.tab.title.wrote", defaultValue: "You wrote \(timeString)")
        }
        return String(localized: "agentPane.tab.title", defaultValue: "Agent Pane")
    }

    /// Caps Lock and Num Lock modifier masks matching `ghostty.h:136-137` (`GHOSTTY_MODS_CAPS`, `GHOSTTY_MODS_NUM`).
    static let capsLockModMask: UInt32 = 1 << 4
    static let numLockModMask: UInt32 = 1 << 5

    /// Whether an input event represents Tom's pressed Return or keypad Enter in the terminal,
    /// counting only real physical key presses (not release, not committed text, not IME composition commit,
    /// no modifiers except Caps/Num lock).
    ///
    /// (cmux-rbf #cm-126.14)
    static func isCountedReturn(
        isPress: Bool,
        keycode: UInt32,
        modsRaw: UInt32,
        isCommittedText: Bool,
        isComposing: Bool,
        hasAccumulatedText: Bool = false
    ) -> Bool {
        guard isPress else { return false }
        guard !isCommittedText else { return false }
        guard !isComposing else { return false }
        guard !hasAccumulatedText else { return false }
        guard keycode == 0x24 || keycode == 0x4C else { return false }
        let allowedMods = capsLockModMask | numLockModMask
        guard (modsRaw & ~allowedMods) == 0 else { return false }
        return true
    }

    /// Subfolder under Application Support for cleared Agent Pane placeholder pages.
    static let clearedPagesSubfolder = "cleared"

    /// Derives an Agent Pane's state upon workspace/session restore (cmux-rbf #cm-126.14).
    ///
    /// A restored Agent Pane's URL inside cmux's cleared-pages folder -> `.cleared`, else `.post`.
    static func restoredState(url: URL?, clearedFolderURL: URL) -> AgentPaneAnswerState {
        guard let url, isClearedPageURL(url, in: clearedFolderURL) else {
            return .post
        }
        return .cleared
    }

    /// The cleared page of one Agent Pane: one file named by the pane's id, so a page shared
    /// between panes can never change another pane's link (cmux-rbf #cm-126.14).
    static func clearedPageURL(panelID: UUID, in clearedFolderURL: URL) -> URL {
        clearedFolderURL.appendingPathComponent("\(panelID.uuidString).html", isDirectory: false)
    }

    /// Whether closing a panel removes its cleared page: only when Tom closes the pane (a tab or
    /// pane close that really closes it), never in a workspace teardown or an app quit's, because
    /// a restored cleared pane reloads its file, and not when the pane only moves
    /// (`closePanel` false). cmux-rbf #cm-126.14.
    static func removesClearedPage(origin: String, closePanel: Bool, appIsTerminating: Bool) -> Bool {
        closePanel && !appIsTerminating && (origin == "tab_close" || origin == "pane_close")
    }

    /// The cleared page's markup: its text, in light or dark by `prefers-color-scheme`, and a link
    /// to the page the pane showed before, left out when it showed none (cmux-rbf #cm-126.14).
    /// `title` and `linkText` arrive already localized; both and the address are escaped here.
    static func clearedPageHTML(title: String, linkText: String, previousURL: URL?) -> String {
        let link = previousURL.map {
            "<p><a href=\"\(escapedForHTML($0.absoluteString))\">\(escapedForHTML(linkText))</a></p>"
        } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(escapedForHTML(title))</title>
        <style>
          html, body { height: 100%; margin: 0; }
          body { display: flex; flex-direction: column; align-items: center; justify-content: center;
                 font: 13px -apple-system, system-ui, sans-serif; color: -apple-system-secondary-label; background: Canvas; }
          p { margin: 0; }
          p + p { margin-top: 1.4em; }
          a { color: inherit; text-decoration: underline; text-underline-offset: 2px; }
        </style></head>
        <body><p>\(escapedForHTML(title))</p>\(link)</body></html>

        """
    }

    /// The page a clear links to (cmux-rbf #cm-126.14): the page the pane shows; when that isn't a file, https or http page,
    /// the last page a `show` put there; when it is a cleared page (Tom went back to it), that last page, else the link the
    /// cleared page already has. Never a cleared page: `nil` instead. `pageLink` reads the page's file, so it runs only when
    /// nothing else gives a page.
    static func linkTarget(shown: URL?, recordedPost: URL?, pageLink: () -> URL?, clearedFolderURL: URL) -> URL? {
        guard let shown else { return nil }
        // A post's link that WebKit refuses (a file in another folder) leaves the pane on about:blank, "Can't open this
        // page". Link the post instead; nil only when no `show` is recorded (a restored pane has none, it's in memory).
        guard refusal(for: shown) != .badScheme else {
            guard let recordedPost, !isClearedPageURL(recordedPost, in: clearedFolderURL) else { return nil }
            return recordedPost
        }
        guard isClearedPageURL(shown, in: clearedFolderURL) else { return shown }
        if let recordedPost, !isClearedPageURL(recordedPost, in: clearedFolderURL) { return recordedPost }
        if let link = pageLink(), !isClearedPageURL(link, in: clearedFolderURL) { return link }
        return nil
    }

    /// The address on a cleared page's link, or `nil` for a page with none (cmux-rbf #cm-126.14).
    static func clearedPageLink(inHTML html: String) -> URL? {
        guard let open = html.range(of: "<a href=\""),
              let close = html[open.upperBound...].range(of: "\"") else { return nil }
        return URL(string: unescapedFromHTML(String(html[open.upperBound..<close.lowerBound])))
    }

    /// The link on the cleared page file at `page`, or `nil` when it isn't a readable file or has none.
    static func clearedPageLink(at page: URL?) -> URL? {
        guard let page, page.isFileURL, let html = try? String(contentsOf: page, encoding: .utf8) else { return nil }
        return clearedPageLink(inHTML: html)
    }

    /// Whether a navigation is handed to the app's own `navigate(to:)`, which grants the post's folder (cmux-rbf #cm-126.14).
    /// The whole decision, so the browser's delegate only calls it and acts. Only the click on a cleared page's own link
    /// qualifies: a link activation in the main frame of an Agent Pane, from a cleared page (in the cleared folder), to the
    /// file URL that page links to. Any other navigation goes through the browser's usual checks. `pageLink` reads the page's
    /// file, so it runs only once every other guard has passed.
    static func handsLinkToApp(
        isLinkActivation: Bool,
        isMainFrame: Bool,
        isAgentPane: Bool,
        source: URL?,
        target: URL,
        clearedFolderURL: URL?,
        pageLink: () -> URL?
    ) -> Bool {
        guard isLinkActivation, isMainFrame, isAgentPane,
              let source, let clearedFolderURL,
              target.isFileURL, isClearedPageURL(source, in: clearedFolderURL),
              !isClearedPageURL(target, in: clearedFolderURL),
              let link = pageLink() else { return false }
        return target.absoluteString == link.absoluteString
    }

    static func unescapedFromHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escapedForHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Whether `url` points to a file within `clearedFolderURL`.
    static func isClearedPageURL(_ url: URL, in clearedFolderURL: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolvedTarget = url.resolvingSymlinksInPath().path
        let resolvedFolder = clearedFolderURL.resolvingSymlinksInPath().path
        let prefix = resolvedFolder.hasSuffix("/") ? resolvedFolder : resolvedFolder + "/"
        return resolvedTarget.hasPrefix(prefix)
    }

    /// Tom's window (`cm-126.13`): a white frame, four panes and one sunset sky behind
    /// them in his blue, purple, red and orange, as a 64 by 64 pixel PNG. The tab draws
    /// it as it is, untinted, whenever it shows it; a loading tab shows its spinner instead.
    ///
    /// Keep it at 64 pixels, not the 32 a fetched favicon is redrawn to
    /// (`BrowserPanel.makeFaviconPNGData`, which ``FigmaTabMark/shippedPicture`` matches):
    /// the tab's 14 pt slot grows with the tab font and Everything Zoom, and on a Retina
    /// screen 32 pixels blur past about 1.14 times. Held as text, like Figma's, so that no
    /// resource can be missing from a build.
    ///
    /// To redraw it, render this SVG with `rsvg-convert -w 64 -h 64` (2.63.4; another
    /// version can draw different pixels) and base64 the PNG:
    ///
    ///     <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">
    ///     <defs>
    ///     <linearGradient id="sky" gradientUnits="userSpaceOnUse" x1="0" y1="5.5" x2="0" y2="26.5">
    ///     <stop offset="0" stop-color="#1976d2"/>
    ///     <stop offset="0.36" stop-color="#ba68c8"/>
    ///     <stop offset="0.66" stop-color="#e53935"/>
    ///     <stop offset="1" stop-color="#e65100"/>
    ///     </linearGradient>
    ///     </defs>
    ///     <rect x="3" y="3.5" width="26" height="25" rx="4.5" fill="#ffffff" stroke="#7a7a87" stroke-width="1.4"/>
    ///     <path d="M7.5 5.5 H14.4 A0.8 0.8 0 0 1 15.2 6.3 V14.4 A0.8 0.8 0 0 1 14.4 15.2 H5.8 A0.8 0.8 0 0 1 5 14.4 V8 A2.5 2.5 0 0 1 7.5 5.5 Z" fill="url(#sky)"/>
    ///     <path d="M17.6 5.5 H24.5 A2.5 2.5 0 0 1 27 8 V14.4 A0.8 0.8 0 0 1 26.2 15.2 H17.6 A0.8 0.8 0 0 1 16.8 14.4 V6.3 A0.8 0.8 0 0 1 17.6 5.5 Z" fill="url(#sky)"/>
    ///     <path d="M5.8 16.8 H14.4 A0.8 0.8 0 0 1 15.2 17.6 V25.7 A0.8 0.8 0 0 1 14.4 26.5 H7.5 A2.5 2.5 0 0 1 5 24 V17.6 A0.8 0.8 0 0 1 5.8 16.8 Z" fill="url(#sky)"/>
    ///     <path d="M17.6 16.8 H26.2 A0.8 0.8 0 0 1 27 17.6 V24 A2.5 2.5 0 0 1 24.5 26.5 H17.6 A0.8 0.8 0 0 1 16.8 25.7 V17.6 A0.8 0.8 0 0 1 17.6 16.8 Z" fill="url(#sky)"/>
    ///     </svg>
    static let shippedPicture: Data = {
        let text = [
            "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",
            "QmCC"
        ].joined()
        return Data(base64Encoded: text) ?? Data()
    }()

    /// Why the app refuses a page before anything changes, or `nil`: a scheme
    /// other than `file`, `https` or `http`, or a page ``FigmaTabMark`` would
    /// count as a Figma pane's (Figma's editor, or cmux's read view). The CLI
    /// refuses the same first (`AgentPaneCLIRules`); this is the app's own check.
    static func refusal(for address: URL) -> AddressRefusal? {
        guard let scheme = address.scheme?.lowercased(), ["file", "https", "http"].contains(scheme) else {
            return .badScheme
        }
        if FigmaPaneURL.isWrapperPage(address) || FigmaFileLink.isEditorPage(address) {
            return .figmaAddress
        }
        return nil
    }

    enum AddressRefusal: Equatable {
        case badScheme
        case figmaAddress
    }
}
