import Foundation
import Testing

@testable import CmuxCommandPalette

/// #cm-104 — the palette's name editor takes a fourth kind of target: the
/// window the palette belongs to.
@Suite("Command palette window rename target")
struct CommandPaletteWindowRenameTargetTests {
    @Test("The window kind has its own three editor strings")
    func windowEditorStrings() {
        let target = CommandPaletteRenameTarget(kind: .window, currentName: "")

        // `bundle: .main` has no catalog under `swift test`, so these are the
        // default (English) values.
        #expect(target.placeholder == "Window name")
        #expect(target.title == "Name Window")
        #expect(target.description == "Choose a name for this window.")
    }
}
