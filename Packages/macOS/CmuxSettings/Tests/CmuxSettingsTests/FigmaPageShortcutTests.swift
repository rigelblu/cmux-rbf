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
}
