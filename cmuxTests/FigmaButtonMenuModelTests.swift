import CmuxSettings
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
        let model = FigmaButtonMenuModel(files: FigmaFileList(), choice: .defaultOnly("https://www.figma.com/files/team/1/folder/2"), canEnterDesignFocus: true, shortcut: shortcut)
        #expect(model.rows.map(\.title) == ["New Design File", "New FigJam Board", "New Slide Deck", "Figma Default Folder", "Recents…", "", "Put Design into Figma", "Ask Agent to Design in Figma", "", "Enter Design Focus"])
        #expect(Array(model.rows.prefix(4)).map(\.action) == [.newFile(.design), .newFile(.board), .newFile(.slides), .folderRow])
        #expect(model.rows.last?.enabled == true)
        #expect(model.rows.last?.shortcut == shortcut)
    }
    @Test(arguments: [nil, "bad"] as [String?])
    func noFolderAndDisabledFocus(folder: String?) {
        var files = FigmaFileList()
        files.show(URL(string: "https://www.figma.com/design/A/First")!)
        let model = FigmaButtonMenuModel(files: files, choice: .defaultOnly(folder), canEnterDesignFocus: false, shortcut: nil)
        #expect(model.rows.map(\.title) == ["First", "", "Choose Figma Folder…", "Recents…", "", "Put Design into Figma", "Ask Agent to Design in Figma", "", "Enter Design Focus"])
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
                let model = FigmaButtonMenuModel(files: list, choice: .defaultOnly(folder), canEnterDesignFocus: true, shortcut: nil, canHandOff: available)
                #expect(Array(model.rows.suffix(6)).map(\.title) == ["Recents…", "", "Put Design into Figma", "Ask Agent to Design in Figma", "", "Enter Design Focus"])
                let jobs = model.rows.filter { $0.action == .putDesignIntoFigma || $0.action == .newDesignInFigma }
                #expect(jobs.map(\.action) == [.putDesignIntoFigma, .newDesignInFigma])
                #expect(jobs.allSatisfy { $0.enabled == available })
                #expect(jobs.allSatisfy { $0.toolTip == (available ? nil : "Available when your agent is waiting for you") })
            }
        }
    }


    // MARK: - cm-73.42, Scenario 374: the folder row for each answer (15, Interaction #14)

    private static let linkA = "https://www.figma.com/files/team/764866853003674551/folder/643299150"
    private static let linkB = "https://www.figma.com/files/team/1/folder/2"
    private static let noTeam = "https://www.figma.com/files/folder/9"
    private static let home = "/Users/probe"
    private static let news = ["New Design File", "New FigJam Board", "New Slide Deck"]

    private static func choice(
        in directory: String?,
        _ entries: KeyValuePairs<String, FigmaFolderEntries.Entry>,
        defaultFolder: String = linkA
    ) -> FigmaFolderChoice {
        var map: [String: FigmaFolderEntries.Entry] = [:]
        for (key, value) in entries { map[key] = value }
        return FigmaFolderChoice.answer(
            forms: directory.map { FigmaFolderPath.Forms(shell: $0, resolved: $0) },
            entries: FigmaFolderEntries(map),
            defaultFolder: defaultFolder,
            home: home
        )
    }

    private static func model(_ choice: FigmaFolderChoice, canSetFolder: Bool = true) -> FigmaButtonMenuModel {
        FigmaButtonMenuModel(
            files: FigmaFileList(),
            choice: choice,
            canEnterDesignFocus: true,
            shortcut: nil,
            canSetFolder: canSetFolder,
            home: home
        )
    }

    private static func titles(_ rows: [FigmaButtonMenuModel.Row]) -> [String] { rows.map(\.title) }

    private static func folderRow(_ model: FigmaButtonMenuModel) -> FigmaButtonMenuModel.Row? {
        model.rows.first { $0.action == .folderRow }
    }

    @Test func row1UsableDirectoryEntry() throws {
        let model = Self.model(Self.choice(in: "/x/a/inner", ["/x/a": .link(Self.linkB)]))
        #expect(Array(Self.titles(model.rows).prefix(5)) == Self.news + ["Figma Folder for a", "Recents…"])
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For /x/a", "Open Folder in Figma", "", "Set Figma Folder…", "Remove Folder for a"])
        #expect(row.submenu.map(\.action) == [.folderNote, .openFolder, nil, .setFolder, .removeFolder(key: "/x/a")])
        #expect(row.submenu.first?.enabled == false)
        #expect(Array(model.rows.prefix(3)).map(\.action) == [.newFile(.design), .newFile(.board), .newFile(.slides)])
    }

    @Test func row2TheDefault() throws {
        let model = Self.model(Self.choice(in: "/y/b", ["/x/a": .link(Self.linkB)]))
        #expect(Array(Self.titles(model.rows).prefix(5)) == Self.news + ["Figma Default Folder", "Recents…"])
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For directories without their own folder", "Open Folder in Figma", "", "Set Figma Folder…"])
        #expect(row.submenu.first?.enabled == false)
    }

    @Test func row3RefusedDirectoryEntry() throws {
        let model = Self.model(Self.choice(in: "/x/a/inner", ["/x/a": .link(Self.noTeam), "/x": .link(Self.linkB)]))
        #expect(Array(Self.titles(model.rows).prefix(2)) == ["⚠ Figma Folder for a", "Recents…"])
        #expect(!model.rows.contains { if case .newFile = $0.action { return true } else { return false } })
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == [
            "For /x/a", "This link has no team in it.", "", "Set Figma Folder…", "Remove Folder for a"
        ])
        #expect(row.submenu.prefix(2).allSatisfy { !$0.enabled })
    }

    @Test func row3RefusedAsNotAFolderLink() throws {
        let model = Self.model(Self.choice(in: "/x/a", ["/x/a": .link("https://example.com/")]))
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu)[1] == "This is not a link to a Figma folder.")
    }

    @Test(arguments: [nil, "bad", noTeam] as [String?])
    func row4NothingUsableKeepsChooseFolder(defaultFolder: String?) {
        let model = Self.model(Self.choice(in: "/y/b", ["/x/a": .link(Self.linkB)], defaultFolder: defaultFolder ?? ""))
        #expect(Self.titles(model.rows) == ["Choose Figma Folder…", "Recents…", "", "Put Design into Figma", "Ask Agent to Design in Figma", "", "Enter Design Focus"])
        #expect(Self.folderRow(model) == nil)
    }

    @Test func row5RemoteWorkspace() throws {
        let model = Self.model(Self.choice(in: nil, ["/": .link(Self.linkB)]), canSetFolder: false)
        #expect(Array(Self.titles(model.rows).prefix(5)) == Self.news + ["Figma Default Folder", "Recents…"])
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For directories without their own folder", "Open Folder in Figma"])
    }

    @Test func row5RemoteWithNothingUsable() {
        let model = Self.model(Self.choice(in: nil, [:], defaultFolder: ""), canSetFolder: false)
        #expect(Self.titles(model.rows).first == "Choose Figma Folder…")
        #expect(Self.folderRow(model) == nil)
    }

    @Test func removeStaysWhenSetIsHidden() throws {
        let model = Self.model(Self.choice(in: "/", ["/": .link(Self.linkB)]), canSetFolder: false)
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For /", "Open Folder in Figma", "", "Remove Folder for /"])
        #expect(row.submenu.last?.action == .removeFolder(key: "/"))
    }

    @Test func removeStaysWhenSetIsHiddenOnARefusedEntry() throws {
        let model = Self.model(Self.choice(in: "/Users", ["/Users": .link(Self.noTeam)]), canSetFolder: false)
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For /Users", "This link has no team in it.", "", "Remove Folder for Users"])
    }

    @Test func row6HomeFolderEntryIsNamedHome() throws {
        let model = Self.model(Self.choice(in: "/Users/probe/src/proj", ["/Users/probe": .link(Self.linkB)]))
        #expect(Self.titles(model.rows).contains("Figma Folder for Home"))
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == ["For ~", "Open Folder in Figma", "", "Set Figma Folder…", "Remove Folder for Home"])
    }

    @Test func row6TildeKeyIsExpandedForNameAndPath() throws {
        let model = Self.model(Self.choice(in: "/Users/probe/src/proj/inner", ["~/src/proj": .link(Self.linkB)]))
        #expect(Self.titles(model.rows).contains("Figma Folder for proj"))
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu).first == "For ~/src/proj")
    }

    @Test func row7MatchedEntryThatIsNotText() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"/x/a": 7}"#.utf8))
        let entries = try #require(FigmaFolderEntries.decodeFromJSON(object))
        let choice = FigmaFolderChoice.answer(
            forms: .init(shell: "/x/a/inner", resolved: "/x/a/inner"),
            entries: entries,
            defaultFolder: Self.linkA,
            home: Self.home
        )
        let model = Self.model(choice)
        #expect(Array(Self.titles(model.rows).prefix(2)) == ["⚠ Figma Folder for a", "Recents…"])
        let row = try #require(Self.folderRow(model))
        #expect(Self.titles(row.submenu) == [
            "For /x/a", "This folder setting is not text.", "", "Set Figma Folder…", "Remove Folder for a"
        ])
        #expect(row.submenu.prefix(2).allSatisfy { !$0.enabled })
    }

    @Test func row8AnUnrelatedEntryThatIsNotTextHidesNothing() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"/x/a": "\#(Self.linkB)", "/x/z": null}"#.utf8))
        let entries = try #require(FigmaFolderEntries.decodeFromJSON(object))
        let choice = FigmaFolderChoice.answer(
            forms: .init(shell: "/x/a/inner", resolved: "/x/a/inner"),
            entries: entries,
            defaultFolder: Self.linkA,
            home: Self.home
        )
        let model = Self.model(choice)
        #expect(Array(Self.titles(model.rows).prefix(5)) == Self.news + ["Figma Folder for a", "Recents…"])
    }
}
