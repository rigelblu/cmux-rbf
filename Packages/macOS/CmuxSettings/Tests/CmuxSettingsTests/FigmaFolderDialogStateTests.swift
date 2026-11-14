import Foundation
import Testing
@testable import CmuxSettings

/// `FigmaFolderDialogState`: the Set Figma Folder dialog's pop-up, preselection and Set Folder rule
/// (cm-73.42, Scenario 377).
@Suite("FigmaFolderDialogState")
struct FigmaFolderDialogStateTests {

    static let linkA = FigmaFolderChoiceTests.linkA
    static let linkB = FigmaFolderChoiceTests.linkB
    static let linkC = FigmaFolderChoiceTests.linkC
    static let home = "/Users/probe"

    static func state(
        _ directory: String,
        _ entries: KeyValuePairs<String, FigmaFolderEntries.Entry> = [:],
        defaultFolder: String = linkA
    ) -> FigmaFolderDialogState {
        let map = FigmaFolderChoiceTests.entries(entries)
        let choice = FigmaFolderChoice.answer(
            forms: FigmaFolderPath.Forms(shell: directory, resolved: directory),
            entries: map,
            defaultFolder: defaultFolder,
            home: home
        )
        return FigmaFolderDialogState(directory: directory, entries: map, choice: choice, home: home)
    }

    @Test("the items for a path on a volume are the path, each parent, and the volume's root, never /Volumes or /")
    func itemsOnAVolume() {
        let state = Self.state("/Volumes/tom-ssd/src/worktrees/rb-monorepo/rbps-12")
        #expect(state.items.map(\.directory) == [
            "/Volumes/tom-ssd/src/worktrees/rb-monorepo/rbps-12",
            "/Volumes/tom-ssd/src/worktrees/rb-monorepo",
            "/Volumes/tom-ssd/src/worktrees",
            "/Volumes/tom-ssd/src",
            "/Volumes/tom-ssd"
        ])
    }

    @Test("the items for a path under home end at ~, never /Users")
    func itemsUnderHome() {
        let state = Self.state("/Users/probe/src/proj/inner")
        #expect(state.items.map(\.directory) == [
            "/Users/probe/src/proj/inner", "/Users/probe/src/proj", "/Users/probe/src", "/Users/probe"
        ])
        #expect(state.items.last?.title == "~")
        #expect(state.items.first?.title == "~/src/proj/inner")
        #expect(!state.items.map(\.directory).contains("/Users"))
    }

    @Test("the items for the home folder itself, and for a path outside home and volumes, never reach /")
    func itemsNeverReachRoot() {
        #expect(Self.state("/Users/probe").items.map(\.directory) == ["/Users/probe"])
        #expect(Self.state("/opt/a/b").items.map(\.directory) == ["/opt/a/b", "/opt/a", "/opt"])
        for path in ["/Volumes/tom-ssd", "/Volumes/tom-ssd/x"] {
            let found = Self.state(path).items.map(\.directory)
            #expect(!found.contains("/") && !found.contains("/Volumes"), "\(path): \(found)")
        }
    }

    @Test("a workspace in /, /Volumes or /Users is offered nothing, and Set Folder stays off", arguments: ["/", "/Volumes", "/Users"])
    func bannedDirectoriesOfferNothing(directory: String) {
        var state = Self.state(directory)
        #expect(state.items.isEmpty, "\(directory): \(state.items.map(\.directory))")
        state.type(Self.linkB)
        #expect(!state.canSet)
        #expect(state.selectedDirectory.isEmpty)
    }

    @Test("a workspace in a link to /, or to /Users, is offered nothing, and Set Folder stays off")
    func linkedBannedDirectoriesOfferNothing() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/ln-root", withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: root + "/ln-users", withDestinationPath: "/Users")
        for directory in [root + "/ln-root", root + "/ln-users", root + "/ln-root/Users"] {
            var state = Self.state(directory)
            #expect(state.items.isEmpty, "\(directory): \(state.items.map(\.directory))")
            state.type(Self.linkB)
            #expect(!state.canSet, "\(directory)")
        }
    }

    @Test("no item of a workspace under a link to / resolves to a banned directory")
    func noItemResolvesToABannedDirectory() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/ln-root", withDestinationPath: "/")
        for directory in [root + "/ln-root/private/tmp", root + "/ln-root/Users/Shared", root + "/ln-root/private"] {
            let state = Self.state(directory)
            let resolved = state.items.map { FigmaFolderPath.resolvedForm($0.directory) }
            #expect(!resolved.contains { FigmaFolderPath.isNeverSet(resolved: $0) }, "\(directory): \(resolved)")
            #expect(!state.items.map(\.directory).contains(root + "/ln-root"), "\(directory)")
            #expect(!state.resolvedDirectory.isEmpty && !FigmaFolderPath.isNeverSet(resolved: state.resolvedDirectory), "\(directory)")
        }
    }

    @Test("an answering key that is a link to a banned directory adds no item")
    func linkedBannedAnsweringKeyAddsNoItem() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/ln-root", withDestinationPath: "/")
        let state = Self.state("/x/a", [root + "/ln-root": .link(Self.linkB)])
        #expect(!state.items.map(\.directory).contains(root + "/ln-root"))
    }

    @Test("an entry that answers with a banned key adds no banned item")
    func bannedAnsweringKeyAddsNoItem() {
        let state = Self.state("/x/a", ["/": .link(Self.linkB)])
        #expect(!state.items.map(\.directory).contains("/"))
        #expect(state.items.first?.directory == "/x/a")
    }

    @Test("a volume's root still offers itself, with no parent")
    func volumeRootOffersItself() {
        #expect(Self.state("/Volumes/tom-ssd").items.map(\.directory) == ["/Volumes/tom-ssd"])
    }

    @Test("the workspace's directory is shown as its terminal reported it, dots dropped")
    func itemsShowTheShellForm() {
        let state = Self.state("/Volumes/tom-ssd/src/rb/cmux-rbf/rb-drive/projects/")
        #expect(state.items.first?.directory == "/Volumes/tom-ssd/src/rb/cmux-rbf/rb-drive/projects")
        #expect(state.items.map(\.directory).contains("/Volumes/tom-ssd/src/rb/cmux-rbf"))
    }

    @Test("when an entry answers, its directory is selected and its link fills the field")
    func entryAnswersPreselects() {
        let state = Self.state("/x/a/inner", ["/x/a": .link(Self.linkB), "/x": .link(Self.linkC)])
        #expect(state.selectedDirectory == "/x/a")
        #expect(state.text == Self.linkB)
        #expect(state.canSet)
        #expect(state.refusal == nil)
    }

    @Test("when the default answers, the workspace's own directory is selected and the field is empty")
    func defaultAnswersPreselectsOwnDirectory() {
        let state = Self.state("/x/a/inner", ["/x/b": .link(Self.linkB)])
        #expect(state.selectedIndex == 0)
        #expect(state.selectedDirectory == "/x/a/inner")
        #expect(state.text.isEmpty)
        #expect(!state.canSet)
    }

    @Test("an entry that answers but is not text selects its directory with an empty field")
    func notTextEntryPreselects() {
        let state = Self.state("/x/a/inner", ["/x/a": .notText(rawJSON: "7")])
        #expect(state.selectedDirectory == "/x/a")
        #expect(state.text.isEmpty)
        #expect(state.items.first { $0.directory == "/x/a" }?.hasFolder == true)
    }

    @Test("Set Folder is enabled only while the field's text passes the link check")
    func setFolderRule() {
        var state = Self.state("/x/a/inner")
        state.type("")
        #expect(!state.canSet && state.refusal == nil)
        state.type(Self.linkB)
        #expect(state.canSet && state.refusal == nil)
        state.type("https://www.figma.com/files/folder/9")
        #expect(!state.canSet && state.refusal == .noTeam)
        state.type("https://example.com")
        #expect(!state.canSet && state.refusal == .notAFolderLink)
        state.type("  \(Self.linkB)?fuid=1  ")
        #expect(state.canSet)
        #expect(state.link?.url == Self.linkB)
    }

    @Test("switching the pop-up shows that directory's stored link until the person types, then keeps their text")
    func switchingKeepsTypedText() throws {
        var state = Self.state("/x/a/inner", ["/x/a": .link(Self.linkB), "/x": .link(Self.linkC)])
        let aIndex = try #require(state.items.firstIndex { $0.directory == "/x/a" })
        let xIndex = try #require(state.items.firstIndex { $0.directory == "/x" })
        let innerIndex = try #require(state.items.firstIndex { $0.directory == "/x/a/inner" })
        state.select(xIndex)
        #expect(state.text == Self.linkC)
        state.select(innerIndex)
        #expect(state.text.isEmpty)
        state.select(aIndex)
        #expect(state.text == Self.linkB)
        state.type("my own text")
        state.select(xIndex)
        #expect(state.text == "my own text")
        #expect(state.selectedDirectory == "/x")
    }

    @Test("an item whose directory has an entry says so; the others do not")
    func hasFolderMarks() {
        let state = Self.state("/x/a/inner", ["/x/a": .link(Self.linkB), "/x": .notText(rawJSON: "7")])
        let marked = state.items.filter(\.hasFolder).map(\.directory)
        #expect(Set(marked) == ["/x/a", "/x"])
        #expect(state.items.first { $0.directory == "/x/a/inner" }?.hasFolder == false)
    }

    @Test("an entry that answers by its resolved form, in no listed item, is appended and preselected")
    func answeringKeyOutsideTheListIsAppendedAndPreselected() throws {
        // The drive-store case: a terminal in <proj>/rb-drive/..., a symlink out to <store>/<proj>-drive/rb-drive,
        // and the entry set on <store>/<proj>-drive.
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = root + "/store/proj-drive"
        try FileManager.default.createDirectory(atPath: key + "/rb-drive/projects/v0.x", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/proj", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/proj/rb-drive", withDestinationPath: key + "/rb-drive")
        let directory = root + "/proj/rb-drive/projects/v0.x"
        let entries = FigmaFolderEntries([key: .link(Self.linkB)])
        let forms = FigmaFolderPath.forms(of: directory, home: Self.home)
        let choice = FigmaFolderChoice.answer(forms: forms, entries: entries, defaultFolder: Self.linkA, home: Self.home)
        #expect(choice == .folder(FigmaFolderChoiceTests.link(Self.linkB), from: .directory(key)))

        let state = FigmaFolderDialogState(directory: directory, entries: entries, choice: choice, home: Self.home)
        #expect(!state.items.dropLast().contains { $0.directory == key }, "the key is not one of the listed parents")
        #expect(state.items.last?.directory == key)
        #expect(state.items.last?.hasFolder == true)
        #expect(state.selectedDirectory == key)
        #expect(state.text == Self.linkB)
        #expect(state.resolvedDirectory == key)
        #expect(state.canSet)
    }

    @Test("the key written is the picked directory with symlinks resolved")
    func resolvedDirectoryKey() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/real/inner", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/ln", withDestinationPath: root + "/real")
        let entries = FigmaFolderEntries.empty
        let state = FigmaFolderDialogState(
            directory: root + "/ln/inner",
            entries: entries,
            choice: .defaultOnly(Self.linkA),
            home: Self.home
        )
        #expect(state.selectedDirectory == root + "/ln/inner")
        #expect(state.resolvedDirectory == root + "/real/inner")
        let parents = state.items.map(\.directory)
        #expect(parents.contains(root + "/ln"))
    }
}
