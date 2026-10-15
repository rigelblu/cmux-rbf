import Combine
import Foundation
import SwiftUI

/// The loading line on a Figma pane's top edge (`cm-73.11`).
///
/// **What the person sees.** A 2 pt line in cmux's accent blue. While the page
/// loads it fills with the load's progress, and it stops at ``progressCap`` so a
/// load that is not over never looks over. When the page has loaded but Figma's
/// editor has not started, a short segment slides along the edge. Then the line
/// fades.
///
/// **Why the web view's own end is too early.** On an editor page the load ends
/// well before Figma's *Minimize UI* control exists, and the control is what
/// ``FigmaEditorChrome/minimizeUIScript(selector:timeoutMilliseconds:pollMilliseconds:)``
/// waits for. So the line follows that wait too.
///
/// **One pure rule, one state that feeds it.** ``phase(isFigmaPane:isLoading:progress:editorWait:now:deadline:)``
/// decides what the line shows from values it is handed. ``FigmaLoadBarState``
/// holds the one value no web view property gives: whether the pane is waiting
/// for the editor.
enum FigmaLoadBar {

    /// Whether the pane is waiting for Figma's editor after its page loaded.
    enum EditorWait: Equatable {
        case notWaiting
        case waiting(since: Date, waitID: Int)
        /// The load failed. Stays until the next real load starts, so cmux's own
        /// error page, a load of its own, does not draw the line again.
        case failed
    }


    enum Phase: Equatable {
        case hidden
        case filling(Double)
        case sliding
    }

    /// How a ``Phase`` is drawn.
    enum Style: Equatable {
        case hidden
        /// A line from the leading edge to this fraction of the width.
        case fill(Double)
        /// A short segment sliding along the edge.
        case segment
        /// A full-width line that does not move, at this opacity.
        case still(opacity: Double)
    }

    /// The fill never goes past this fraction of the width.
    static let progressCap = 0.9

    /// The Swift-side backstop: the page script's timeout plus 2 s.
    static let defaultDeadline: TimeInterval = 22

    /// What the line shows. The first branch that holds wins.
    static func phase(
        isFigmaPane: Bool,
        isLoading: Bool,
        progress: Double,
        editorWait: EditorWait,
        now: Date,
        deadline: TimeInterval = defaultDeadline
    ) -> Phase {
        guard isFigmaPane else { return .hidden }
        if editorWait == .failed { return .hidden }
        if isLoading { return .filling(progress) }
        if case let .waiting(since, _) = editorWait, now.timeIntervalSince(since) < deadline {
            return .sliding
        }
        return .hidden
    }

    /// Whether this pane is a Figma pane, for the line.
    ///
    /// The pane's address alone is not enough: `currentURL` only follows a load
    /// once it commits, so the first load into a new pane (the Figma button,
    /// `cmux figma open`) would show no line. The load's own target counts too.
    /// After a failed load `address` holds the failed Figma address, so the pane
    /// stays one and the `failed` state is what keeps the line off.
    static func isFigmaPane(address: URL?, loadTarget: URL?, showsAddressBar: Bool) -> Bool {
        FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar)
            || FigmaTabMark.applies(address: loadTarget, showsAddressBar: showsAddressBar)
    }

    /// Whether a page that finished loading will get Figma's *Minimize UI*
    /// control, so the line should wait for it.
    static func waitsForEditor(afterLoadOf url: URL?, isOmnibarVisible: Bool) -> Bool {
        FigmaEditorChrome.shouldMinimizeUI(paneURL: url, isOmnibarVisible: isOmnibarVisible)
            && hasMinimizeControl(url)
    }

    /// Only a `/design/` or `/file/` link gets the control. A FigJam board
    /// (`/board/`) has none (measured 2026-10-15) and a Slides deck (`/slides/`)
    /// is treated the same until measured.
    static func hasMinimizeControl(_ url: URL?) -> Bool {
        guard let first = url?.path.split(separator: "/").first else { return false }
        return first == "design" || first == "file"
    }

    static func style(for phase: Phase, reduceMotion: Bool) -> Style {
        switch phase {
        case .hidden:
            return .hidden
        case let .filling(progress):
            return .fill(min(max(progress, 0), progressCap))
        case .sliding:
            return reduceMotion ? .still(opacity: 0.5) : .segment
        }
    }

    /// Solves `3p^2 - 2p^3 = y` for `p` in `[0, 1]` using Newton-Raphson iteration.
    static func invertSmoothstep(_ y: Double) -> Double {
        guard y > 0 else { return 0 }
        guard y < 1 else { return 1 }
        var p = y
        for _ in 0..<8 {
            let f = p * p * (3 - 2 * p) - y
            let fPrime = 6 * p * (1 - p)
            if abs(fPrime) < 1e-12 { break }
            p -= f / fPrime
            p = min(max(p, 0), 1)
        }
        return p
    }

    /// Pure segment position math for the sliding segment.
    /// Returns the segment width and x-offset for a pane of `width` at elapsed `time`.
    static func segmentPosition(
        elapsed: TimeInterval,
        width: CGFloat,
        slideSeconds: Double = 1.2,
        segmentFraction: CGFloat = 1.0 / 3.0,
        progressCap: Double = progressCap
    ) -> (segmentWidth: CGFloat, offset: CGFloat) {
        let segment = width * segmentFraction
        let travel = width + segment
        let targetFraction = (progressCap * Double(width)) / Double(travel)
        let initialPhase = invertSmoothstep(targetFraction)
        let phase = (elapsed / slideSeconds + initialPhase).truncatingRemainder(dividingBy: 1)
        let normalizedPhase = phase < 0 ? phase + 1 : phase
        let eased = normalizedPhase * normalizedPhase * (3 - 2 * normalizedPhase)
        let offset = -segment + CGFloat(eased) * travel
        return (segmentWidth: segment, offset: offset)
    }
}

/// A panel's wait for Figma's editor. Its methods are the seam: the navigation
/// closures call them, and a test calls them directly with no navigation delegate.
@MainActor
final class FigmaLoadBarState {
    private(set) var editorWait: FigmaLoadBar.EditorWait = .notWaiting {
        didSet { changed() }
    }
    /// Bumped by every real load, so the view can start its fill again from the left.
    private(set) var generation = 0 {
        didSet { changed() }
    }
    /// The address the current load is going to, as the navigation delegate knows
    /// it when the load starts. `nil` when no load has started or it was cancelled.
    private(set) var loadTarget: URL?
    /// Seconds the Swift timer waits for the page script. Read each time a wait starts.
    var deadlineSeconds: TimeInterval = FigmaLoadBar.defaultDeadline

    private var waitCounter = 0
    private var timer: Task<Void, Never>?
    private let changed: () -> Void

    init(changed: @escaping () -> Void = {}) {
        self.changed = changed
    }

    deinit { timer?.cancel() }

    var currentWaitID: Int? {
        if case let .waiting(_, id) = editorWait {
            return id
        }
        return nil
    }

    /// A page started loading. Cmux's error page is not a new load: a `failed`
    /// stays `failed`.
    func begin(target: URL? = nil, isErrorPage: Bool) {
        guard !isErrorPage else { return }
        loadTarget = target
        generation += 1
        stopTimer()
        editorWait = .notWaiting
    }

    /// A page finished loading. When it waits for Figma's editor, start the wait and timer.
    func finished(url: URL?, isOmnibarVisible: Bool, isErrorPage: Bool) {
        guard !isErrorPage else { return }
        loadTarget = nil
        if FigmaLoadBar.waitsForEditor(afterLoadOf: url, isOmnibarVisible: isOmnibarVisible) {
            waitCounter += 1
            let waitID = waitCounter
            editorWait = .waiting(since: Date(), waitID: waitID)
            startTimer(for: waitID)
        } else {
            stopTimer()
            editorWait = .notWaiting
        }
    }

    /// An in-place open from Recents with no page load.
    func inPlaceEditorOpened() {
        waitCounter += 1
        let waitID = waitCounter
        editorWait = .waiting(since: Date(), waitID: waitID)
        startTimer(for: waitID)
    }

    /// An in-place move to a page with no editor (Recents, FigJam, etc.) ends any running wait.
    func inPlaceNonEditorOpened() {
        guard case .waiting = editorWait else { return }
        stopTimer()
        editorWait = .notWaiting
    }

    /// The page script answered for a wait.
    func scriptAnswered(waitID: Int) {
        guard case let .waiting(_, currentID) = editorWait, currentID == waitID else { return }
        stopTimer()
        editorWait = .notWaiting
    }

    func failed() {
        loadTarget = nil
        stopTimer()
        editorWait = .failed
    }

    func cancelled() {
        loadTarget = nil
        stopTimer()
        editorWait = .notWaiting
    }

    private func startTimer(for waitID: Int) {
        stopTimer()
        let deadline = deadlineSeconds
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timerFired(waitID: waitID)
        }
    }

    private func timerFired(waitID: Int) {
        guard case let .waiting(_, currentID) = editorWait, currentID == waitID else { return }
        editorWait = .notWaiting
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// What the portal hands the line: the panel it belongs to and what to draw.
struct FigmaLoadBarConfiguration: Equatable {
    let panelId: UUID
    let phase: FigmaLoadBar.Phase
    let generation: Int
}

extension BrowserPanel {
    /// The line's configuration, or `nil` when this is not a Figma pane.
    @MainActor
    var figmaLoadBarConfiguration: FigmaLoadBarConfiguration? {
        guard FigmaLoadBar.isFigmaPane(
            address: currentURL,
            loadTarget: figmaLoadBar.loadTarget,
            showsAddressBar: isOmnibarVisible
        ) else { return nil }
        return FigmaLoadBarConfiguration(
            panelId: id,
            phase: FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: isLoading,
                progress: estimatedProgress,
                editorWait: figmaLoadBar.editorWait,
                now: Date(),
                deadline: figmaLoadBar.deadlineSeconds
            ),
            generation: figmaLoadBar.generation
        )
    }
}

/// The line itself. Hosted in the browser portal's slot, above the web view, and
/// it takes no hits, so clicks reach Figma.
struct FigmaLoadBarView: View {
    let configuration: FigmaLoadBarConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last picture that was not hidden, kept so the 0.2 s fade has something to fade.
    @State private var lastShown: FigmaLoadBar.Style = .hidden
    @State private var slidingStarted: Date?
    @State private var fadeTask: Task<Void, Never>?

    static let height: CGFloat = 2
    private static let segmentFraction: CGFloat = 1.0 / 3.0
    private static let slideSeconds = 1.2

    private var style: FigmaLoadBar.Style {
        FigmaLoadBar.style(for: configuration.phase, reduceMotion: reduceMotion)
    }

    private var drawn: FigmaLoadBar.Style {
        style == .hidden ? lastShown : style
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                line(drawn, width: proxy.size.width)
            }
            .frame(width: proxy.size.width, height: Self.height, alignment: .topLeading)
            .clipped()
        }
        .frame(height: Self.height)
        .opacity(style == .hidden ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: style == .hidden)
        .onAppear {
            if style == .segment { slidingStarted = Date() }
            remember(style)
        }
        .onChange(of: style) { _, new in
            fadeTask?.cancel()
            if new == .segment {
                if slidingStarted == nil { slidingStarted = Date() }
            } else if new != .hidden {
                slidingStarted = nil
            }
            if new != .hidden {
                lastShown = new
            } else {
                fadeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    lastShown = .hidden
                    slidingStarted = nil
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func remember(_ style: FigmaLoadBar.Style) {
        if style != .hidden { lastShown = style }
    }

    @ViewBuilder
    private func line(_ drawnStyle: FigmaLoadBar.Style, width: CGFloat) -> some View {
        switch drawnStyle {
        case .hidden:
            EmptyView()
        case let .fill(fraction):
            // A new generation is a new view, so a new load's line starts from the
            // left and does not run backwards from the last load's width.
            FillLine(fraction: fraction, width: width)
                .id(configuration.generation)
        case .segment:
            TimelineView(.animation(minimumInterval: nil, paused: self.style != .segment)) { timeline in
                let startTime = slidingStarted ?? timeline.date
                let t = max(0, timeline.date.timeIntervalSince(startTime))
                let (segment, offset) = FigmaLoadBar.segmentPosition(
                    elapsed: t,
                    width: width,
                    slideSeconds: Self.slideSeconds,
                    segmentFraction: Self.segmentFraction
                )
                Rectangle()
                    .fill(cmuxAccentColor())
                    .frame(width: segment, height: Self.height)
                    .offset(x: offset)
            }
        case let .still(opacity):
            Rectangle()
                .fill(cmuxAccentColor())
                .opacity(opacity)
                .frame(width: width, height: Self.height)
        }
    }

    private struct FillLine: View {
        let fraction: Double
        let width: CGFloat

        var body: some View {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(width: width * CGFloat(fraction), height: FigmaLoadBarView.height)
                .animation(.linear(duration: 0.15), value: fraction)
        }
    }
}

/// The hosting view for ``FigmaLoadBarView``: no hits, so clicks reach Figma.
final class FigmaLoadBarHostingView: NSHostingView<FigmaLoadBarView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
