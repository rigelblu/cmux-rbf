/// Controls how a one-surface caption relates to the pane's surrounding backdrop.
public enum SurfaceCaptionBackgroundStyle: Sendable, Equatable {
    /// Preserve the pane's standard tab-bar surface.
    case tabBar

    /// Paint the host-provided chrome background as an opaque caption surface.
    case chrome

    /// Leave the caption surface clear over the host-provided chrome background.
    case transparentOverChrome
}
