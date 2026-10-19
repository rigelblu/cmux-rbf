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
        #expect(model.rows.map(\.title) == ["New Design File", "New FigJam Board", "New Slide Deck", "Recents…", "", "Put Design into Figma", "New Design in Figma", "", "Enter Design Focus"])
        #expect(Array(model.rows.prefix(4)).map(\.action) == [.newFile(.design), .newFile(.board), .newFile(.slides), .recents])
        #expect(model.rows.last?.enabled == true)
        #expect(model.rows.last?.shortcut == shortcut)
    }
    @Test(arguments: [nil, "bad"] as [String?])
    func noFolderAndDisabledFocus(folder: String?) {
        var files = FigmaFileList()
        files.show(URL(string: "https://www.figma.com/design/A/First")!)
        let model = FigmaButtonMenuModel(files: files, folder: folder, canEnterDesignFocus: false, shortcut: nil)
        #expect(model.rows.map(\.title) == ["First", "", "Choose Figma Folder…", "Recents…", "", "Put Design into Figma", "New Design in Figma", "", "Enter Design Focus"])
        #expect(model.rows.first?.action == .file("A"))
        #expect(model.rows.last?.enabled == false)
        #expect(model.rows.last?.shortcut == nil)
    }
    // Scenario 148: stable tail for every file/folder state, both availability states.
    @Test(arguments: [false, true])
    func handOffGroup(available: Bool) {
        for folder: String? in [nil, "bad", "https://www.figma.com/files/team/1/folder/2"] {
            var files = FigmaFileList()
            for name in ["A", "B", "C"] { files.show(URL(string: "https://www.figma.com/design/\(name)/\(name)")!) }
            for list in [FigmaFileList(), files] {
                let model = FigmaButtonMenuModel(files: list, folder: folder, canEnterDesignFocus: true, shortcut: nil, canHandOff: available)
                #expect(Array(model.rows.suffix(6)).map(\.title) == ["Recents…", "", "Put Design into Figma", "New Design in Figma", "", "Enter Design Focus"])
                let jobs = model.rows.filter { $0.action == .putDesignIntoFigma || $0.action == .newDesignInFigma }
                #expect(jobs.map(\.action) == [.putDesignIntoFigma, .newDesignInFigma])
                #expect(jobs.allSatisfy { $0.enabled == available })
                #expect(jobs.allSatisfy { $0.toolTip == (available ? nil : "Available when your agent is waiting for you") })
            }
        }
    }

}
