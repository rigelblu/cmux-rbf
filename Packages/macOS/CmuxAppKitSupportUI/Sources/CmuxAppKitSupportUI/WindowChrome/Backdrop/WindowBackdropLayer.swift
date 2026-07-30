public import SwiftUI
import AppKit

/// SwiftUI layer that renders the resolved backdrop for one chrome role.
public struct WindowBackdropLayer: View {
    private let role: WindowBackdropRole
    private let snapshot: WindowAppearanceSnapshot

    /// Creates a backdrop layer for a chrome role.
    public init(role: WindowBackdropRole, snapshot: WindowAppearanceSnapshot) {
        self.role = role
        self.snapshot = snapshot
    }

    /// Rendered backdrop body.
    public var body: some View {
        backdrop(for: snapshot.policy(for: role))
    }

    @ViewBuilder
    private func backdrop(for policy: WindowBackdropPolicy) -> some View {
        switch policy {
        case let .ghosttyTerminalBackdrop(color, opacity, _, backgroundImage):
            let backdropColor = color.withAlphaComponent(opacity)
            switch role {
            case .windowRoot:
                // The image goes only at the window root. Every other role is
                // a slice of this same backdrop, so drawing it again there
                // would tile a second copy at the wrong geometry.
                if let backgroundImage {
                    ZStack {
                        Color(nsColor: backdropColor)
                        // An NSViewRepresentable has no intrinsic size, so it
                        // must be told to fill. Without this it collapses to
                        // its ideal height and paints only a band across the
                        // top of the window, leaving every pane below it on
                        // the flat backdrop color.
                        TerminalBackdropImageView(image: backgroundImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Color(nsColor: backdropColor)
                }
            case .terminalCanvas, .bonsplitChrome, .titlebar, .leftSidebar, .rightSidebar, .browserSurface:
                LayerBackedBackdropColor(color: backdropColor)
            }
        case let .sidebarMaterial(materialPolicy):
            ZStack {
                let usingNativeLiquidGlass = materialPolicy.preferLiquidGlass &&
                    SidebarVisualEffectBackground.liquidGlassAvailable
                if let material = materialPolicy.material,
                   !materialPolicy.usesWindowLevelGlass {
                    SidebarVisualEffectBackground(
                        material: material,
                        blendingMode: materialPolicy.blendingMode,
                        state: materialPolicy.state,
                        opacity: materialPolicy.opacity,
                        tintColor: materialPolicy.tintColor,
                        cornerRadius: materialPolicy.cornerRadius,
                        preferLiquidGlass: materialPolicy.preferLiquidGlass
                    )
                }
                if !materialPolicy.usesWindowLevelGlass && !usingNativeLiquidGlass {
                    Color(nsColor: materialPolicy.tintColor)
                }
            }
        case .clear:
            Color.clear
        }
    }
}
