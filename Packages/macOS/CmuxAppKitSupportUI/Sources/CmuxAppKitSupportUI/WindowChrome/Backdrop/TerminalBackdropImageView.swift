public import SwiftUI
import AppKit

/// Draws the terminal `background-image` across the window root backdrop.
///
/// Ghostty's renderer normally owns this drawing. Under
/// `macos-background-image-from-layer` it hands the image to the host so one
/// backdrop can sit beneath every surface, and this view reproduces the
/// renderer's geometry against the window. See `TerminalBackdropImage` for
/// the layout contract.
public struct TerminalBackdropImageView: NSViewRepresentable {
    private let image: TerminalBackdropImage

    /// Creates a backdrop image view.
    public init(image: TerminalBackdropImage) {
        self.image = image
    }

    /// Creates the backing AppKit view.
    public func makeNSView(context: Context) -> TerminalBackdropImageLayerView {
        let view = TerminalBackdropImageLayerView()
        view.backdropImage = image
        return view
    }

    /// Applies a new backdrop image to the backing view.
    public func updateNSView(_ nsView: TerminalBackdropImageLayerView, context: Context) {
        nsView.backdropImage = image
    }
}

extension NSImage {
    /// Draws into the current context, upright even when that context is
    /// flipped.
    ///
    /// `draw(in:from:operation:fraction:)` positions correctly in a flipped
    /// view but renders the image content vertically mirrored. The backdrop
    /// view is flipped so the renderer's top-down offset math carries over
    /// unchanged, which put every backdrop image upside down. The longer
    /// overload with `respectFlipped: true` is AppKit's answer.
    func drawRespectingFlip(in rect: CGRect, opacity: CGFloat) {
        draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: opacity,
            respectFlipped: true,
            hints: nil
        )
    }
}

/// AppKit view that renders one terminal backdrop image.
public final class TerminalBackdropImageLayerView: NSView {
    /// Decoded images keyed by path, so a resize or appearance change does not
    /// re-read the file. The backdrop is one image per window at most, and a
    /// terminal background image is typically a large photo.
    private static let imageCache = NSCache<NSString, NSImage>()

    private var loadedImage: NSImage?

    /// The image to draw, or `nil` to draw nothing.
    public var backdropImage: TerminalBackdropImage? {
        didSet {
            guard backdropImage != oldValue else { return }
            reloadImage()
            needsDisplay = true
        }
    }

    /// Draws top-down so the renderer's offset math applies unchanged.
    public override var isFlipped: Bool { true }

    /// Never intercepts events; this is backdrop decoration.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the view can draw concurrently with other views.
    public override var canDrawConcurrently: Bool {
        get { true }
        set { super.canDrawConcurrently = newValue }
    }

    private func reloadImage() {
        guard let backdropImage else {
            loadedImage = nil
            return
        }
        let key = backdropImage.url.path as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            loadedImage = cached
            return
        }
        guard let image = NSImage(contentsOf: backdropImage.url) else {
            // A missing or unreadable path is the user's own config pointing
            // at a file that is gone. Ghostty logs and renders no image; match
            // that rather than substituting a placeholder.
            loadedImage = nil
            return
        }
        Self.imageCache.setObject(image, forKey: key)
        loadedImage = image
    }

    /// Renders the backdrop image.
    public override func draw(_ dirtyRect: NSRect) {
        guard let backdropImage, let loadedImage else { return }
        let containerSize = bounds.size
        let imageSize = loadedImage.size
        let destination = backdropImage.destinationRect(
            imageSize: imageSize,
            in: containerSize
        )
        guard destination.width > 0, destination.height > 0 else { return }

        NSGraphicsContext.current?.imageInterpolation = .high

        if backdropImage.repeats {
            drawTiled(loadedImage, tile: destination, opacity: backdropImage.opacity)
        } else {
            loadedImage.drawRespectingFlip(
                in: destination,
                opacity: backdropImage.opacity
            )
        }
    }

    private func drawTiled(_ image: NSImage, tile: CGRect, opacity: CGFloat) {
        guard tile.width > 0, tile.height > 0 else { return }
        // Walk outward from the anchored tile so the untiled and tiled
        // renderings agree on where the first copy lands.
        var originY = tile.minY
        while originY > bounds.minY { originY -= tile.height }
        let firstY = originY

        var originX = tile.minX
        while originX > bounds.minX { originX -= tile.width }
        let firstX = originX

        var y = firstY
        while y < bounds.maxY {
            var x = firstX
            while x < bounds.maxX {
                image.drawRespectingFlip(
                    in: CGRect(x: x, y: y, width: tile.width, height: tile.height),
                    opacity: opacity
                )
                x += tile.width
            }
            y += tile.height
        }
    }
}
