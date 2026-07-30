import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Testing

@testable import CmuxAppKitSupportUI

/// Pins the host-drawn backdrop image to Ghostty's `bg_image_vertex` geometry.
///
/// These cases are transcribed from the shader, not from this implementation:
/// `dest_size` per fit, then a per-axis offset of `0`, `(screen - dest) / 2`,
/// or `screen - dest`. If Ghostty's shader changes, these fail and the window
/// root stops matching the renderer.
@Suite struct TerminalBackdropImageTests {
    private func image(
        fit: TerminalBackdropImage.Fit = .cover,
        position: TerminalBackdropImage.Position = .centerCenter,
        opacity: CGFloat = 1.0,
        repeats: Bool = false
    ) -> TerminalBackdropImage {
        TerminalBackdropImage(
            url: URL(fileURLWithPath: "/tmp/pink_city_bg.jpg"),
            fit: fit,
            position: position,
            opacity: opacity,
            repeats: repeats
        )
    }

    @Test func coverScalesByTheLargerAxisAndCropsSymmetrically() {
        // 200x100 image into a 400x400 window: cover picks max(2, 4) = 4,
        // so the image becomes 800x400 and overhangs 400pt horizontally.
        let rect = image(fit: .cover).destinationRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )

        #expect(rect.width == 800)
        #expect(rect.height == 400)
        #expect(rect.minX == -200)
        #expect(rect.minY == 0)
    }

    @Test func containScalesByTheSmallerAxisAndLeavesLetterboxing() {
        // Same inputs, contain picks min(2, 4) = 2 -> 400x200, centered.
        let rect = image(fit: .contain).destinationRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )

        #expect(rect.width == 400)
        #expect(rect.height == 200)
        #expect(rect.minX == 0)
        #expect(rect.minY == 100)
    }

    @Test func stretchFillsTheContainerAndNoneKeepsPixelSize() {
        let stretched = image(fit: .stretch).destinationRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )
        #expect(stretched == CGRect(x: 0, y: 0, width: 400, height: 400))

        let unscaled = image(fit: .none).destinationRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )
        #expect(unscaled.size == CGSize(width: 200, height: 100))
        #expect(unscaled.origin == CGPoint(x: 100, y: 150))
    }

    @Test func positionSelectsFlushStartCenteredOrFlushEndPerAxis() {
        let imageSize = CGSize(width: 200, height: 100)
        let container = CGSize(width: 400, height: 400)

        let topLeft = image(fit: .none, position: .topLeft)
            .destinationRect(imageSize: imageSize, in: container)
        #expect(topLeft.origin == CGPoint(x: 0, y: 0))

        let bottomRight = image(fit: .none, position: .bottomRight)
            .destinationRect(imageSize: imageSize, in: container)
        #expect(bottomRight.origin == CGPoint(x: 200, y: 300))

        let topCenter = image(fit: .none, position: .topCenter)
            .destinationRect(imageSize: imageSize, in: container)
        #expect(topCenter.origin == CGPoint(x: 100, y: 0))

        let centerLeft = image(fit: .none, position: .centerLeft)
            .destinationRect(imageSize: imageSize, in: container)
        #expect(centerLeft.origin == CGPoint(x: 0, y: 150))
    }

    @Test func bareCenterIsAcceptedAsGhosttySpellsIt() {
        // Ghostty's BackgroundImagePosition carries both `center` and
        // `center-center`; a config using the short form must not fall back.
        #expect(TerminalBackdropImage.Position(configValue: "center") == .centerCenter)
        #expect(TerminalBackdropImage.Position(configValue: "center-center") == .centerCenter)
        #expect(TerminalBackdropImage.Position(configValue: "bottom-right") == .bottomRight)
        #expect(TerminalBackdropImage.Position(configValue: "nonsense") == nil)
    }

    @Test func opacityIsClampedIntoTheVisibleRange() {
        #expect(image(opacity: 1.4).opacity == 1.0)
        #expect(image(opacity: -0.2).opacity == 0.0)
    }

    @Test func degenerateSizesProduceNoDrawingRatherThanNaN() {
        let empty = image().destinationRect(
            imageSize: .zero,
            in: CGSize(width: 400, height: 400)
        )
        #expect(empty == .zero)

        let collapsed = image().destinationRect(
            imageSize: CGSize(width: 200, height: 100),
            in: .zero
        )
        #expect(collapsed == .zero)
    }
}

/// The window root must be the only place the image is drawn, and only while
/// the host actually owns the backdrop.
@Suite struct WindowRootBackdropImageTests {
    private let backdropImage = TerminalBackdropImage(
        url: URL(fileURLWithPath: "/tmp/pink_city_bg.jpg"),
        fit: .cover,
        position: .centerCenter,
        opacity: 0.4,
        repeats: false
    )

    private func snapshot(
        usesHostLayerBackground: Bool,
        backgroundImage: TerminalBackdropImage?
    ) -> WindowAppearanceSnapshot {
        WindowAppearanceSnapshot(
            terminalBackgroundColor: NSColor(hex: "#272822") ?? .black,
            terminalBackgroundOpacity: 1.0,
            terminalBackgroundBlur: .disabled,
            terminalRenderingMode: WindowAppearanceSnapshot.terminalRenderingMode(
                usesHostLayerBackground: usesHostLayerBackground
            ),
            terminalBackgroundImage: backgroundImage,
            unifySurfaceBackdrops: false,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: "sidebar",
                blendModeRawValue: "withinWindow",
                stateRawValue: "followWindow",
                tintHex: "#000000",
                tintHexLight: nil,
                tintHexDark: nil,
                tintOpacity: 0.0,
                cornerRadius: 0.0,
                blurOpacity: 1.0,
                colorScheme: .dark
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: "withinWindow",
                isEnabled: false,
                tintHex: "#000000",
                tintOpacity: 0.0,
                terminalBackgroundBlur: .disabled,
                terminalGlassTintColor: .black
            )
        )
    }

    private func backgroundImage(of policy: WindowBackdropPolicy) -> TerminalBackdropImage? {
        guard case let .ghosttyTerminalBackdrop(_, _, _, image) = policy else { return nil }
        return image
    }

    @Test func windowRootCarriesTheImageWhenTheHostOwnsTheBackdrop() {
        let snapshot = snapshot(usesHostLayerBackground: true, backgroundImage: backdropImage)

        #expect(backgroundImage(of: snapshot.policy(for: .windowRoot)) == backdropImage)
    }

    @Test func rendererOwnedBackdropKeepsTheImageOutOfTheWindowRoot() {
        // Ghostty is still drawing the image per-surface here. A window-root
        // copy would show through translucent surfaces as a second layer at
        // different geometry.
        let snapshot = snapshot(usesHostLayerBackground: false, backgroundImage: backdropImage)

        #expect(snapshot.hostDrawnTerminalBackgroundImage == nil)
        #expect(backgroundImage(of: snapshot.policy(for: .windowRoot)) == nil)
    }

    @Test func noRoleBesidesTheWindowRootCarriesTheImage() {
        let snapshot = snapshot(usesHostLayerBackground: true, backgroundImage: backdropImage)

        for role in [
            WindowBackdropRole.terminalCanvas,
            .bonsplitChrome,
            .titlebar,
            .leftSidebar,
            .rightSidebar,
            .browserSurface,
        ] {
            #expect(backgroundImage(of: snapshot.policy(for: role)) == nil)
        }
    }

    @Test func changingTheImageChangesTheAppKitMutationIdentity() {
        // Without this the window keeps the previous backdrop when only the
        // image changes, because every color in the identity is unchanged.
        let withImage = snapshot(usesHostLayerBackground: true, backgroundImage: backdropImage)
        let withoutImage = snapshot(usesHostLayerBackground: true, backgroundImage: nil)
        let withOtherImage = snapshot(
            usesHostLayerBackground: true,
            backgroundImage: TerminalBackdropImage(
                url: URL(fileURLWithPath: "/tmp/other.jpg"),
                fit: .cover,
                position: .centerCenter,
                opacity: 0.4,
                repeats: false
            )
        )

        let identity = { (snapshot: WindowAppearanceSnapshot) in
            snapshot.policy(for: .windowRoot).identityComponent
        }

        #expect(identity(withImage) != identity(withoutImage))
        #expect(identity(withImage) != identity(withOtherImage))
    }
}
