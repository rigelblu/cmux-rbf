import Testing
@testable import CmuxSettings

@Suite("Figma page shortcut")
struct FigmaPageShortcutTests {
    @Test func configurableShortcutUsesTheAgreedDefault() throws {
        let action = try #require(ShortcutAction(rawValue: "switchFigmaPreviewAndEditor"))
        #expect(action.defaultStroke == ShortcutStroke(key: "c", command: true, shift: true, option: true))
        #expect(action.group == .panes)
        #expect(action.displayName == "Figma: Switch Preview and Editor")
    }

    // cmux-rbf #cm-73.32
    @Test func motionShortcutExistsWithNoDefault() throws {
        let action = try #require(ShortcutAction(rawValue: "toggleFigmaMotion"))
        #expect(action.defaultStroke == nil)
        #expect(action.defaultShortcut == nil)
        #expect(action.group == .panes)
        #expect(action.displayName == "Figma: Play / Pause Motion")
    }
    // cmux-rbf (#cm-73.37)
    @Test func showStillShortcutExistsWithNoDefault() throws {
        let action = try #require(ShortcutAction(rawValue: "showFigmaStill"))
        #expect(action.defaultShortcut == nil)
        #expect(action.group == .panes)
        #expect(action.displayName == "Figma: Show Still")
    }
}

