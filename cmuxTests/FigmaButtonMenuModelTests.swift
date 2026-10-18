import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FigmaButtonMenuModelTests {
    @Test func emptyListWithFolder() {
        let shortcut = StoredShortcut(key: "d", command: true, shift: false, option: false, control: true)
        let model = FigmaButtonMenuModel(files: FigmaFileList(), folder: "https://www.figma.com/files/team/1/folder/2", canEnterDesignFocus: true, shortcut: shortcut)
        #expect(model.rows.map(\.title) == ["New Design File", "New FigJam Board", "New Slide Deck", "Recents…", "", "Enter Design Focus"])
        #expect(model.rows.map(\.action) == [.newFile(.design), .newFile(.board), .newFile(.slides), .recents, nil, .enterDesignFocus])
        #expect(model.rows.last?.enabled == true)
        #expect(model.rows.last?.shortcut == shortcut)
    }
    @Test(arguments: [nil, "bad"] as [String?])
    func noFolderAndDisabledFocus(folder: String?) {
        var files = FigmaFileList()
        files.show(URL(string: "https://www.figma.com/design/A/First")!)
        let model = FigmaButtonMenuModel(files: files, folder: folder, canEnterDesignFocus: false, shortcut: nil)
        #expect(model.rows.map(\.title) == ["First", "", "Choose Figma Folder…", "Recents…", "", "Enter Design Focus"])
        #expect(model.rows.first?.action == .file("A"))
        #expect(model.rows.last?.enabled == false)
        #expect(model.rows.last?.shortcut == nil)
    }
}
