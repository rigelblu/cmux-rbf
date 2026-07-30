public import AppKit

/// A terminal `background-image` the AppKit window host draws on Ghostty's behalf.
///
/// Ghostty normally paints this inside each Metal surface, fitting it to that
/// surface's own viewport. cmux composites one backdrop beneath every surface,
/// so a per-surface fit is visibly wrong: a split renders two independently
/// cropped copies, and host chrome drawn between surfaces (pane headers, the
/// one-surface caption) has no image under it at all. With
/// `macos-background-image-from-layer` the renderer hands the image over and
/// this type reproduces its geometry against the window instead.
///
/// The layout math below mirrors Ghostty's `bg_image_vertex` shader exactly.
/// It is the one place cmux re-implements renderer geometry, so it stays a
/// pure function over sizes and is covered by tests that pin it to the
/// shader's cases.
public struct TerminalBackdropImage: Equatable, Sendable {
    /// How the image is scaled into the destination.
    public enum Fit: String, Equatable, Sendable {
        case contain
        case cover
        case stretch
        case none
    }

    /// Where the scaled image sits when it does not fill the destination.
    public enum Position: String, Equatable, Sendable {
        case topLeft = "top-left"
        case topCenter = "top-center"
        case topRight = "top-right"
        case centerLeft = "center-left"
        case centerCenter = "center-center"
        case centerRight = "center-right"
        case bottomLeft = "bottom-left"
        case bottomCenter = "bottom-center"
        case bottomRight = "bottom-right"

        /// Ghostty accepts a bare `center` alias for `center-center`.
        public init?(configValue: String) {
            if configValue == "center" {
                self = .centerCenter
                return
            }
            self.init(rawValue: configValue)
        }
    }

    /// Filesystem location of the image.
    public let url: URL

    /// Scaling behavior.
    public let fit: Fit

    /// Placement within the destination.
    public let position: Position

    /// Image opacity, `0...1`.
    public let opacity: CGFloat

    /// Whether the image tiles to fill the destination.
    public let repeats: Bool

    /// Creates a host-drawn terminal background image.
    public init(
        url: URL,
        fit: Fit,
        position: Position,
        opacity: CGFloat,
        repeats: Bool
    ) {
        self.url = url
        self.fit = fit
        self.position = position
        self.opacity = max(0.0, min(1.0, opacity))
        self.repeats = repeats
    }

    /// Returns the rect the image occupies inside `containerSize`.
    ///
    /// Mirrors `bg_image_vertex`: the fit picks a destination size, then the
    /// position picks one of three offsets per axis — flush start, centered,
    /// or flush end. A destination larger than the container yields a negative
    /// offset, which is how `cover` crops.
    public func destinationRect(
        imageSize: CGSize,
        in containerSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let destinationSize: CGSize
        switch fit {
        case .contain:
            let scale = min(
                containerSize.width / imageSize.width,
                containerSize.height / imageSize.height
            )
            destinationSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        case .cover:
            let scale = max(
                containerSize.width / imageSize.width,
                containerSize.height / imageSize.height
            )
            destinationSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        case .stretch:
            destinationSize = containerSize
        case .none:
            destinationSize = imageSize
        }

        let endX = containerSize.width - destinationSize.width
        let endY = containerSize.height - destinationSize.height

        let originX: CGFloat
        switch position {
        case .topLeft, .centerLeft, .bottomLeft:
            originX = 0
        case .topCenter, .centerCenter, .bottomCenter:
            originX = endX / 2
        case .topRight, .centerRight, .bottomRight:
            originX = endX
        }

        // The shader works in top-down coordinates, so its "top" row is the
        // flush-start offset. AppKit rects here are handed to a top-down
        // flipped drawing context, so the same mapping holds.
        let originY: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight:
            originY = 0
        case .centerLeft, .centerCenter, .centerRight:
            originY = endY / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            originY = endY
        }

        return CGRect(
            x: originX,
            y: originY,
            width: destinationSize.width,
            height: destinationSize.height
        )
    }

    /// Stable identity component for AppKit mutation coalescing.
    public var identityComponent: String {
        [
            url.path,
            fit.rawValue,
            position.rawValue,
            String(format: "%.4f", Double(opacity)),
            String(repeats),
        ].joined(separator: ":")
    }
}
