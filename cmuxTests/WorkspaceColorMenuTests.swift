import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct WorkspaceColorMenuTests {
    @Test
    func namedPaletteColorMarksTheMatchingMenuItem() throws {
        let palette = WorkspaceTabColorSettings.labeledPaletteEntries()
        let selected = try #require(palette.first)
        let menu = SidebarColorSubmenu.make(
            targetHexes: ["  \(selected.hex.lowercased()) "],
            apply: { _ in },
            promptCustomColor: {}
        )
        #expect(menu.items.count >= palette.count + 3)
        for (entry, item) in zip(palette, menu.items.dropFirst(3)) {
            #expect(item.title == entry.displayName)
            #expect(item.state == (entry.hex == selected.hex ? .on : .off))
            #expect(item.image != nil)
        }
    }

    @Test
    func unmatchedCustomColorLeavesNamedPaletteItemsUnmarked() throws {
        let palette = WorkspaceTabColorSettings.labeledPaletteEntries()
        #expect(!palette.isEmpty)
        let usedHexes = Set(palette.map { $0.hex.uppercased() })
        let customHex = try #require((0..<0x1000000).lazy.map {
            String(format: "#%06X", $0)
        }.first { !usedHexes.contains($0) })
        let menu = SidebarColorSubmenu.make(
            targetHexes: [customHex],
            apply: { _ in },
            promptCustomColor: {}
        )
        #expect(menu.items.count >= palette.count + 3)
        for (entry, item) in zip(palette, menu.items.dropFirst(3)) {
            #expect(item.title == entry.displayName)
            #expect(item.state == .off)
        }
    }
}
