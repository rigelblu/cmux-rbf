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
    ///     <clipPath id="p0">
    ///     <path d="M7.5 5.5 H14.4 A0.8 0.8 0 0 1 15.2 6.3 V14.4 A0.8 0.8 0 0 1 14.4 15.2 H5.8 A0.8 0.8 0 0 1 5 14.4 V8 A2.5 2.5 0 0 1 7.5 5.5 Z"/>
    ///     </clipPath>
    ///     <clipPath id="p1">
    ///     <path d="M17.6 5.5 H24.5 A2.5 2.5 0 0 1 27 8 V14.4 A0.8 0.8 0 0 1 26.2 15.2 H17.6 A0.8 0.8 0 0 1 16.8 14.4 V6.3 A0.8 0.8 0 0 1 17.6 5.5 Z"/>
    ///     </clipPath>
    ///     <clipPath id="p2">
    ///     <path d="M5.8 16.8 H14.4 A0.8 0.8 0 0 1 15.2 17.6 V25.7 A0.8 0.8 0 0 1 14.4 26.5 H7.5 A2.5 2.5 0 0 1 5 24 V17.6 A0.8 0.8 0 0 1 5.8 16.8 Z"/>
    ///     </clipPath>
    ///     <clipPath id="p3">
    ///     <path d="M17.6 16.8 H26.2 A0.8 0.8 0 0 1 27 17.6 V24 A2.5 2.5 0 0 1 24.5 26.5 H17.6 A0.8 0.8 0 0 1 16.8 25.7 V17.6 A0.8 0.8 0 0 1 17.6 16.8 Z"/>
    ///     </clipPath>
    ///     </defs>
    ///     <rect x="3" y="3.5" width="26" height="25" rx="4.5" fill="#ffffff"/>
    ///     <g clip-path="url(#p0)">
    ///     <rect x="5.000" y="5.500" width="3.420" height="3.253" fill="#6fcf7f"/>
    ///     <rect x="8.400" y="5.500" width="3.420" height="3.253" fill="#97dca3"/>
    ///     <rect x="11.800" y="5.500" width="3.420" height="3.253" fill="#80d58e"/>
    ///     <rect x="5.000" y="8.733" width="3.420" height="3.253" fill="#a6e1b0"/>
    ///     <rect x="8.400" y="8.733" width="3.420" height="3.253" fill="#78d287"/>
    ///     <rect x="11.800" y="8.733" width="3.420" height="3.253" fill="#8fda9b"/>
    ///     <rect x="5.000" y="11.967" width="3.420" height="3.253" fill="#9ddea8"/>
    ///     <rect x="8.400" y="11.967" width="3.420" height="3.253" fill="#6fcf7f"/>
    ///     <rect x="11.800" y="11.967" width="3.420" height="3.253" fill="#89d896"/>
    ///     </g>
    ///     <g clip-path="url(#p1)">
    ///     <rect x="16.800" y="5.500" width="3.420" height="3.253" fill="#99c2f6"/>
    ///     <rect x="20.200" y="5.500" width="3.420" height="3.253" fill="#64a2f1"/>
    ///     <rect x="23.600" y="5.500" width="3.420" height="3.253" fill="#7eb2f3"/>
    ///     <rect x="16.800" y="8.733" width="3.420" height="3.253" fill="#8fbcf5"/>
    ///     <rect x="20.200" y="8.733" width="3.420" height="3.253" fill="#5a9cf0"/>
    ///     <rect x="23.600" y="8.733" width="3.420" height="3.253" fill="#78aef3"/>
    ///     <rect x="16.800" y="11.967" width="3.420" height="3.253" fill="#6aa6f2"/>
    ///     <rect x="20.200" y="11.967" width="3.420" height="3.253" fill="#95c0f5"/>
    ///     <rect x="23.600" y="11.967" width="3.420" height="3.253" fill="#61a0f1"/>
    ///     </g>
    ///     <g clip-path="url(#p2)">
    ///     <rect x="5.000" y="16.800" width="3.420" height="3.253" fill="#fad883"/>
    ///     <rect x="8.400" y="16.800" width="3.420" height="3.253" fill="#f7c548"/>
    ///     <rect x="11.800" y="16.800" width="3.420" height="3.253" fill="#f8cf69"/>
    ///     <rect x="5.000" y="20.033" width="3.420" height="3.253" fill="#f8cb5a"/>
    ///     <rect x="8.400" y="20.033" width="3.420" height="3.253" fill="#fada8a"/>
    ///     <rect x="11.800" y="20.033" width="3.420" height="3.253" fill="#f7c74f"/>
    ///     <rect x="5.000" y="23.267" width="3.420" height="3.253" fill="#f9d478"/>
    ///     <rect x="8.400" y="23.267" width="3.420" height="3.253" fill="#f8cd62"/>
    ///     <rect x="11.800" y="23.267" width="3.420" height="3.253" fill="#f7c64c"/>
    ///     </g>
    ///     <g clip-path="url(#p3)">
    ///     <rect x="16.800" y="16.800" width="3.420" height="3.253" fill="#cd8ae3"/>
    ///     <rect x="20.200" y="16.800" width="3.420" height="3.253" fill="#dbaceb"/>
    ///     <rect x="23.600" y="16.800" width="3.420" height="3.253" fill="#c982e1"/>
    ///     <rect x="16.800" y="20.033" width="3.420" height="3.253" fill="#d69fe8"/>
    ///     <rect x="20.200" y="20.033" width="3.420" height="3.253" fill="#cf8fe4"/>
    ///     <rect x="23.600" y="20.033" width="3.420" height="3.253" fill="#c880e1"/>
    ///     <rect x="16.800" y="23.267" width="3.420" height="3.253" fill="#d8a4e9"/>
    ///     <rect x="20.200" y="23.267" width="3.420" height="3.253" fill="#c77de0"/>
    ///     <rect x="23.600" y="23.267" width="3.420" height="3.253" fill="#d7a1e9"/>
    ///     </g>
    ///     </svg>
    static let shippedPicture: Data = {
        let text = [
            "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"
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
