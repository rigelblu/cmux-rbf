/// A hover-time snapshot of the host's board-layout controls.
public struct PairBoardControlState: Equatable, Sendable {
    /// Why a segment cannot act.
    public enum UnavailableReason: Equatable, Sendable {
        /// The original conversation and file cannot currently be matched.
        case unmatchedTarget
        /// The matching agent is busy or asking for input.
        case busyAgent
    }

    /// The last layout successfully reported to the opening conversation.
    public let litOrientation: BoardLayoutOrientation?
    /// Whether explicit pane flips keep the current board layout.
    public let pin: Bool
    /// Whether the two board-layout segments may act.
    public let boardEnabled: Bool
    /// Whether the local pin may act.
    public let pinEnabled: Bool
    /// The reason used for disabled-segment help.
    public let unavailableReason: UnavailableReason?

    /// Creates a snapshot; a missing target has no displayed selections.
    /// - Parameters:
    ///   - litOrientation: The last successfully delivered orientation.
    ///   - pin: The tab's local keep-layout setting.
    ///   - boardEnabled: Whether board commands may be sent.
    ///   - pinEnabled: Whether the local setting may change.
    ///   - unavailableReason: Why commands are unavailable.
    public init(litOrientation: BoardLayoutOrientation? = nil, pin: Bool = false,
                boardEnabled: Bool = false, pinEnabled: Bool = false,
                unavailableReason: UnavailableReason? = .unmatchedTarget) {
        self.litOrientation = litOrientation
        self.pin = pin
        self.boardEnabled = boardEnabled
        self.pinEnabled = pinEnabled
        self.unavailableReason = unavailableReason
    }
}
