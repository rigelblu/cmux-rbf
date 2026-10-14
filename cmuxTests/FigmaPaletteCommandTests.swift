import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The palette's row "New Tab (Figma)" for `cm-73.9`: its words, the condition
/// that hides it while cmux's browser is off, and a handler to run. Each test
/// calls a function in the fork's own `ContentView+FigmaCommandPalette.swift`,
/// not `ContentView`'s private lists. Not held here: the one case that ties the
/// row to the built-in action, and that choosing the row adds a tab.
@MainActor
@Suite("FigmaPaletteCommand")
struct FigmaPaletteCommandTests {

    @Test("rowHasTomsWords: the id, the title \"New Tab (Figma)\" and the subtitle \"Tab\"")
    func rowHasTomsWords() {
        let row = CommandPaletteCommandContribution.newFigmaTab
        let context = CommandPaletteContextSnapshot()
        #expect(row.commandId == "palette.newFigmaTab")
        #expect(row.title(context) == String(localized: "command.newFigmaTab.title", defaultValue: "New Tab (Figma)"))
        #expect(row.title(context) == "New Tab (Figma)")
        #expect(row.subtitle(context) == String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab"))
        #expect(row.subtitle(context) == "Tab")
        #expect(row.keywords.contains("figma"))
    }

    @Test("rowIsNotOfferedWhenTheBrowserIsOff: the row's condition answers no with the browser off and yes with it on")
    func rowIsNotOfferedWhenTheBrowserIsOff() {
        let row = CommandPaletteCommandContribution.newFigmaTab
        var off = CommandPaletteContextSnapshot()
        off.setBool(CommandPaletteContextKeys.browserDisabled, true)
        var on = CommandPaletteContextSnapshot()
        on.setBool(CommandPaletteContextKeys.browserDisabled, false)
        #expect(!row.when(off))
        #expect(row.when(on))
    }

    @Test("handlerIsRegistered: the registering function leaves a handler for the row's id on an empty registry")
    func handlerIsRegistered() {
        var registry = CommandPaletteHandlerRegistry()
        let id = CommandPaletteCommandContribution.newFigmaTab.commandId
        #expect(registry.handler(for: id) == nil, "a new registry holds none")
        registry.registerNewFigmaTab(tabManager: TabManager(), windowId: UUID())
        #expect(registry.handler(for: id) != nil)
    }
}
