// cmux-rbf (#cm-73.46, #cm-73.44): the one decision behind every re-fit of a Figma preview.
import CoreGraphics
import Foundation

/// Whether Figma's own frame, in a Figma pane's preview, should redraw itself in place.
///
/// **Three entrances, one decision.** A size change (`.size`), `⇧1` (`.key`) and
/// `cmux figma fit` (`.cli`) all ask this. `.key` and `.cli` skip the size test,
/// since Tom or his agent asked for a fit at the same size; every frame test
/// (`loading`, `player`, `unloaded`, `redrawing`, `notboard`, `fullscreen`) applies to all three.
///
/// **Decided from what the panel already holds**, never by asking cmux's page, so
/// `fit` can answer at once from inside the socket's main-actor hop.
enum FigmaPreviewRefit {
    enum Trigger: String {
        case size, key, cli
    }

    /// The closed set a log line prints. `asked` is a move for `.key` or `.cli`,
    /// which has no size to differ by.
    enum Reason: String {
        case differs, asked, same, loading, hidden, editor, player, redrawing, notboard, unloaded, fullscreen
    }

    /// Who asked for the full screen WebKit is in (cm-73.52). A redraw ends full screen on a page Figma put there itself,
    /// so only `.page` stops a re-fit; `.cmux` is cmux's own iframe, which a redraw can't end.
    enum Fullscreen: Equatable {
        case none, cmux, page

        init(isActive: Bool, cmuxOwns: Bool) {
            self = isActive ? (cmuxOwns ? .cmux : .page) : .none
        }
    }

    /// Which size test a `.size` decision applies (cm-73.52): the ordinary one against what Figma fitted, or the one a
    /// re-fit's end makes against the size the redraw started at.
    enum SizeRule: Equatable {
        case settled, recheck
    }

    enum Decision: Equatable {
        case move(Reason)
        case skip(Reason)

        var moves: Bool {
            if case .move = self { return true }
            return false
        }

        var reason: Reason {
            switch self {
            case .move(let reason), .skip(let reason): return reason
            }
        }
    }

    /// What `fit` hears back. Everything but `notboard` and `fullscreen` is `OK` to the agent: a load
    /// or a redraw already running fits it, and the player fits itself.
    enum Answer: Equatable {
        case moved
        case fitsItself(Reason)
        case refused(Reason)
    }

    /// The top Figma frame's last report, as cmux's page last posted it.
    struct Report: Equatable {
        var path: String
        var player: Bool
        var drawn: Bool
        /// The frame document's `performance.timeOrigin`: one value per document, kept by a restore, new at a redraw.
        var doc: Double?

        init(path: String, player: Bool, drawn: Bool, doc: Double? = nil) {
            self.path = path
            self.player = player
            self.drawn = drawn
            self.doc = doc
        }

        /// Exactly the report a snapshot carries: `report: null`, or none at all, is no report.
        init?(snapshot: [String: Any]) {
            guard let report = snapshot["report"] as? [String: Any] else { return nil }
            self.init(
                path: report["path"] as? String ?? "",
                player: report["player"] as? Bool ?? false,
                drawn: report["drawn"] as? Bool ?? false,
                doc: report["doc"] as? Double
            )
        }
    }

    /// How long a size must hold still before it is checked.
    static let settle: Duration = .milliseconds(500)
    /// A size counts as changed at this many points, in width or height.
    static let sizeThreshold: CGFloat = 1
    /// The re-check's threshold (cm-73.52): a size must be more than this far from where the redraw started. Figma's
    /// 1 pt settle on every entry into full screen would otherwise cost a second redraw.
    static let recheckThreshold: CGFloat = 2
    /// A re-fit in flight ends here at the latest, like `cm-73.11`'s line.
    static let inFlightSeconds: TimeInterval = 15

    /// How long a swap waits for WebKit to report full screen off before it goes ahead (cm-73.52).
    /// WebKit's exits measured 0.83–0.94 s, so 3 s leaves room on a loaded machine.
    static let fullscreenExitWait: Duration = .seconds(3)
    /// How long a refused enter call waits before its one retry, when the app is already active (cm-73.52).
    static let fullscreenRetryDelay: Duration = .milliseconds(250)

    /// How long Figma's `/embed/interstitial` may stand after cmux's page finished loading before it is read as
    /// Figma's Log in page. Every load reports the interstitial for a moment first; Log in never leaves it.
    static let interstitialSettle: Duration = .seconds(10)

    /// The first rule that holds wins.
    static func decide(
        trigger: Trigger,
        remembered: CGSize?,
        now: CGSize,
        isPreview: Bool,
        isShowing: Bool,
        motion: FigmaMotionState,
        isLoading: Bool,
        lastReport: Report?,
        refitInFlight: Bool,
        sinceFinish: Duration?,
        fullscreen: Fullscreen,
        sizeRule: SizeRule = .settled
    ) -> Decision {
        guard isPreview else { return .skip(.editor) }
        if isLoading { return .skip(.loading) }
        // cmux-rbf (#cm-73.52): a redraw ends a full screen Figma's own page asked for, so nothing moves, for any trigger.
        if fullscreen == .page { return .skip(.fullscreen) }
        if refitInFlight { return .skip(.redrawing) }
        if trigger == .size, !isShowing { return .skip(.hidden) }
        switch motion {
        case .still: break
        case .loading: return .skip(.loading)
        case .frozen, .playing, .paused: return .skip(.player)
        }
        // The path decides, not `drawn`: a board that has not drawn yet is loading, not "not a board".
        guard let lastReport else { return .skip(.loading) }
        if lastReport.path.hasPrefix("/proto/") { return .skip(.player) }
        // Figma's top frame reports its /embed/interstitial page twice, in the first second of every load, before
        // /design/<file> (probe-base, 2026-10-30). That is a load, not a page that is no board.
        // Log in never leaves the interstitial: after interstitialSettle with cmux's page finished, it is not a board.
        if lastReport.path.hasPrefix("/embed/interstitial") {
            return .skip((sinceFinish ?? .zero) >= interstitialSettle ? .notboard : .loading)
        }
        guard lastReport.path.hasPrefix("/design/") || lastReport.path.hasPrefix("/file/") else {
            return .skip(.notboard)
        }
        if !lastReport.drawn { return .skip(.loading) }
        // A drawn board whose document has no remembered size: a report with no `doc`, or a document never seen drawn.
        // Never a match, so never a move by size; with a `doc` this cannot happen, since its first drawn report writes it.
        guard let remembered else { return .skip(.unloaded) }
        if trigger == .size {
            let differs: Bool
            switch sizeRule {
            case .settled:
                differs = abs(now.width - remembered.width) >= sizeThreshold
                    || abs(now.height - remembered.height) >= sizeThreshold
            case .recheck:
                differs = abs(now.width - remembered.width) > recheckThreshold
                    || abs(now.height - remembered.height) > recheckThreshold
            }
            return differs ? .move(.differs) : .skip(.same)
        }
        return .move(.asked)
    }

    static func answer(for decision: Decision) -> Answer {
        switch decision {
        case .move: return .moved
        case .skip(.notboard): return .refused(.notboard)
        case .skip(.fullscreen): return .refused(.fullscreen) // cmux-rbf (#cm-73.52)
        case .skip(let reason): return .fitsItself(reason)
        }
    }
}
