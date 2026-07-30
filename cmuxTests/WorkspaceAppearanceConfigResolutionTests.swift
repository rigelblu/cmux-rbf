import AppKit
import Bonsplit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct WorkspaceAppearanceConfigResolutionTests {
    @Test
    func resolvedAppearanceConfigPrefersGhosttyRuntimeAppearanceOverLoadedConfig() throws {
        let loadedBackground = try #require(NSColor(hex: "#112233"))
        let runtimeBackground = try #require(NSColor(hex: "#FDF6E3"))
        let loadedForeground = try #require(NSColor(hex: "#EEEEEE"))
        let runtimeForeground = try #require(NSColor(hex: "#4A4543"))
        let loadedCursor = try #require(NSColor(hex: "#DDDDDD"))
        let runtimeCursor = try #require(NSColor(hex: "#3A3432"))
        let loadedCursorText = try #require(NSColor(hex: "#111111"))
        let runtimeCursorText = try #require(NSColor(hex: "#F7F7F7"))
        let loadedSelectionBackground = try #require(NSColor(hex: "#222222"))
        let runtimeSelectionBackground = try #require(NSColor(hex: "#A5A2A2"))
        let loadedSelectionForeground = try #require(NSColor(hex: "#EEEEEE"))
        let runtimeSelectionForeground = try #require(NSColor(hex: "#4A4543"))

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground
        loaded.foregroundColor = loadedForeground
        loaded.cursorColor = loadedCursor
        loaded.cursorTextColor = loadedCursorText
        loaded.selectionBackground = loadedSelectionBackground
        loaded.selectionForeground = loadedSelectionForeground
        loaded.unfocusedSplitOpacity = 0.42

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground },
            defaultForeground: { runtimeForeground },
            defaultCursor: { runtimeCursor },
            defaultCursorText: { runtimeCursorText },
            defaultSelectionBackground: { runtimeSelectionBackground },
            defaultSelectionForeground: { runtimeSelectionForeground }
        )

        #expect(resolved.backgroundColor.hexString() == "#FDF6E3")
        #expect(resolved.foregroundColor.hexString() == "#4A4543")
        #expect(resolved.cursorColor.hexString() == "#3A3432")
        #expect(resolved.cursorTextColor.hexString() == "#F7F7F7")
        #expect(resolved.selectionBackground.hexString() == "#A5A2A2")
        #expect(resolved.selectionForeground.hexString() == "#4A4543")
        #expect(abs(resolved.unfocusedSplitOpacity - 0.42) < 0.0001)
    }

    @Test
    func resolvedAppearanceConfigPrefersExplicitBackgroundOverride() throws {
        let loadedBackground = try #require(NSColor(hex: "#112233"))
        let runtimeBackground = try #require(NSColor(hex: "#FDF6E3"))
        let explicitOverride = try #require(NSColor(hex: "#272822"))

        var loaded = GhosttyConfig()
        loaded.backgroundColor = loadedBackground

        let resolved = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            backgroundOverride: explicitOverride,
            loadConfig: { loaded },
            defaultBackground: { runtimeBackground }
        )

        #expect(resolved.backgroundColor.hexString() == "#272822")
    }

    @Test
    func oneSurfaceTerminalCaptionUsesTransparentBackground() {
        let appearance = Workspace.bonsplitAppearance(
            from: .black,
            backgroundOpacity: 1
        )

        #expect(appearance.surfaceCaptionBackgroundStyle == .transparentOverChrome)
        #expect(appearance.surfaceCaptionBackgroundStyleOverrides["terminal"] == nil)
    }
}
