public import AppKit
public import CmuxFoundation

/// Current terminal appearance values needed by window chrome policy.
public struct WindowTerminalAppearanceSnapshot {
    /// Current default terminal background color.
    public let backgroundColor: NSColor

    /// Current default terminal background opacity.
    public let backgroundOpacity: Double

    /// Current default terminal background blur.
    public let backgroundBlur: GhosttyBackgroundBlur

    /// Whether terminal host layers own background fills.
    public let usesHostLayerBackground: Bool

    /// Terminal `background-image`, when one is configured.
    ///
    /// Carried here rather than read at the window, because whether the host
    /// draws it depends on `usesHostLayerBackground` and both have to be
    /// resolved from the same config load.
    public let backgroundImage: TerminalBackdropImage?

    /// Creates a terminal appearance snapshot.
    public init(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        usesHostLayerBackground: Bool,
        backgroundImage: TerminalBackdropImage? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.usesHostLayerBackground = usesHostLayerBackground
        self.backgroundImage = backgroundImage
    }
}
