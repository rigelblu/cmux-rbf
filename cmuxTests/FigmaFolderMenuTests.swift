import AppKit
import Bonsplit
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A throwaway `cmux.json` and the directories a workspace can be in, resolved so the keys
/// the tests write are the keys the code writes. Never Tom's file.
@MainActor
private final class FolderFixture {
    static let linkA = "https://www.figma.com/files/team/764866853003674551/folder/643299150"
    static let linkB = "https://www.figma.com/files/team/1/folder/2"
    static let linkC = "https://www.figma.com/files/team/5/folder/6"

    let root: String
    let file: URL
    var a: String { root + "/a" }
    var aInner: String { root + "/a/inner" }
    var b: String { root + "/b" }

    init(config: (FolderFixture) -> String) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("figma-folder-menu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = FigmaFolderPath.resolvedForm(base.path)
        file = URL(fileURLWithPath: root + "/config/cmux.json")
        for path in [aInner, b + "/inner"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: root + "/config", withIntermediateDirectories: true)
        try Data(config(self).utf8).write(to: file)
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], atPath: root + "/config")
        try? FileManager.default.removeItem(atPath: root)
    }

    /// The `figma.folders` object now in the file.
    var folders: [String: Any]? {
        let data = (try? Data(contentsOf: file)) ?? Data()
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (root?["figma"] as? [String: Any])?["folders"] as? [String: Any]
    }

    var bytes: Data? { try? Data(contentsOf: file) }
}

private extension FileManager {
    func setAttributes(_ attributes: [FileAttributeKey: Any], atPath path: String) throws {
        try setAttributes(attributes, ofItemAtPath: path)
    }
}

/// cm-73.42, Scenario 375: the workspace's directory picks the folder for the New entries.
/// The model test passes with the menu still reading `figma.defaultFolder` alone, which is why
/// these go from the workspace to the address a tab opens on.
@MainActor @Suite(.serialized) struct FigmaButtonMenuFolderTests {
    private func select(_ title: String, in menu: NSMenu) throws {
        let index = try #require(menu.items.firstIndex { $0.title == title })
        menu.performActionForItem(at: index)
    }

    private func newDesignAddress(_ workspace: Workspace, in fixture: FolderFixture, pane: PaneID) throws -> String? {
        let menu = workspace.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        try select("New Design File", in: menu)
        let panel = try #require(workspace.panels[workspace.focusedPanelId ?? UUID()] as? BrowserPanel)
        return (panel.navigationDelegate?.lastAttemptedURL ?? panel.currentURL)?.absoluteString
    }

    private func config(_ fixture: FolderFixture, extra: String = "") -> String {
        #"{"figma": {"defaultFolder": "\#(FolderFixture.linkA)", "folders": {"\#(fixture.a)": "\#(FolderFixture.linkB)"\#(extra)}}}"#
    }

    @Test func workspaceDirectoryPicksTheFolderForNewDesignFile() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)

        w.currentDirectory = fixture.aInner
        #expect(try newDesignAddress(w, in: fixture, pane: pane) == "https://www.figma.com/design/new?folder_id=2&team_id=1")

        w.currentDirectory = fixture.b + "/inner"
        #expect(try newDesignAddress(w, in: fixture, pane: pane)
                == "https://www.figma.com/design/new?folder_id=643299150&team_id=764866853003674551")
    }

    @Test func remoteWorkspaceGetsTheDefault() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = fixture.aInner
        w.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
        #expect(w.usesRemoteDirectoryProvenance)
        #expect(try newDesignAddress(w, in: fixture, pane: pane)
                == "https://www.figma.com/design/new?folder_id=643299150&team_id=764866853003674551")
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        let row = try #require(menu.items.first { $0.title == "Figma Default Folder" })
        #expect(row.submenu?.items.map(\.title) == ["For directories without their own folder", "Open Folder in Figma"])
    }

    @Test func anEntryThatIsNotTextForAnotherDirectoryHidesNothing() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture, extra: #", "/nowhere/else": 7"#).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = fixture.aInner
        #expect(try newDesignAddress(w, in: fixture, pane: pane) == "https://www.figma.com/design/new?folder_id=2&team_id=1")
    }

    @Test func anEntryThatIsNotTextForThisDirectoryHidesTheNewEntries() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(#"{"figma": {"defaultFolder": "\#(FolderFixture.linkA)", "folders": {"\#(fixture.a)": 7}}}"#.utf8)
            .write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = fixture.aInner
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        #expect(!menu.items.contains { $0.title == "New Design File" })
        #expect(menu.items.contains { $0.title.hasPrefix("⚠ Figma Folder for ") })
    }

    @Test(arguments: ["/", "/Volumes", "/Users"])
    func aBannedDirectoryOffersNoSetFolder(directory: String) throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = directory
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        let row = try #require(menu.items.first { $0.title == "Figma Default Folder" })
        #expect(row.submenu?.items.map(\.title) == ["For directories without their own folder", "Open Folder in Figma"], "\(directory)")
    }

    @Test(arguments: ["/", "/Volumes", "/Users"])
    func aBannedDirectoryWithAnEntryKeepsRemove(directory: String) throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(#"{"figma": {"defaultFolder": "\#(FolderFixture.linkA)", "folders": {"\#(directory)": "\#(FolderFixture.linkB)"}}}"#.utf8)
            .write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = directory
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        let row = try #require(menu.items.first { $0.title.hasPrefix("Figma Folder for ") })
        let titles = try #require(row.submenu?.items.map(\.title))
        #expect(!titles.contains("Set Figma Folder…"), "\(titles)")
        #expect(titles.contains { $0.hasPrefix("Remove Folder for ") }, "\(titles)")
    }

    @Test func aVolumeRootStillOffersItself() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = "/Volumes/tom-ssd"
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        let row = try #require(menu.items.first { $0.title == "Figma Default Folder" })
        #expect(row.submenu?.items.map(\.title).contains("Set Figma Folder…") == true)
    }

    @Test func openFolderInFigmaOpensTheFoldersLinkInTheClickedPane() throws {
        let fixture = try FolderFixture { _ in "{}" }
        defer { fixture.cleanup() }
        try Data(config(fixture).utf8).write(to: fixture.file)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        w.currentDirectory = fixture.aInner
        let menu = w.figmaButtonMenu(inPane: pane, configFile: fixture.file, openExternally: { _ in })
        let row = try #require(menu.items.first { $0.title == "Figma Folder for a" })
        let submenu = try #require(row.submenu)
        let index = try #require(submenu.items.firstIndex { $0.title == "Open Folder in Figma" })
        submenu.performActionForItem(at: index)
        let panel = try #require(w.panels[w.focusedPanelId ?? UUID()] as? BrowserPanel)
        let address = (panel.navigationDelegate?.lastAttemptedURL ?? panel.currentURL)?.absoluteString
        #expect(address == FolderFixture.linkB)
    }
}

/// cm-73.42, Scenario 376: Set (the dialog) and Remove (the submenu) write through one plan.
@MainActor @Suite(.serialized) struct FigmaFolderMenuActionTests {
    private final class Counter: @unchecked Sendable {
        var plans = 0
        var alerts: [String] = []
    }

    private func writer(_ fixture: FolderFixture, _ counter: Counter) -> FigmaFolderWriter {
        FigmaFolderWriter(
            store: JSONConfigStore(fileURL: fixture.file),
            planner: { change, directory, entries in
                counter.plans += 1
                return FigmaFolders.plan(change, directory: directory, entries: entries)
            },
            showError: { counter.alerts.append($0) }
        )
    }

    private func fixture(_ folders: String) throws -> FolderFixture {
        try FolderFixture { f in
            #"{"zz_keep": 1, "figma": {"defaultFolder": "\#(FolderFixture.linkA)", "folders": {\#(folders.replacingOccurrences(of: "@a", with: f.a).replacingOccurrences(of: "@b", with: f.b))}}}"#
        }
    }

    private func menu(_ w: Workspace, _ fixture: FolderFixture, writer: FigmaFolderWriter, dialog: (@MainActor (FigmaFolderDialogState, NSWindow?) -> FigmaFolderDialogResult?)? = nil) throws -> NSMenu {
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        return w.figmaButtonMenu(
            inPane: pane,
            configFile: fixture.file,
            folderWriter: writer,
            runFolderDialog: dialog ?? { _, _ in nil },
            openExternally: { _ in }
        )
    }

    private func pick(_ title: String, inSubmenuOf parent: String, of menu: NSMenu) throws {
        let row = try #require(menu.items.first { $0.title.hasSuffix(parent) })
        let submenu = try #require(row.submenu)
        let index = try #require(submenu.items.firstIndex { $0.title == title })
        submenu.performActionForItem(at: index)
    }

    private func settle() async { await FigmaFolderWriteTracker.last?.value }

    @Test func removeLeavesTheOthersAndUsesOnePlan() async throws {
        let fixture = try fixture(#""@a": "\#(FolderFixture.linkB)", "@b": "\#(FolderFixture.linkC)""#)
        defer { fixture.cleanup() }
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter))
        try pick("Remove Folder for a", inSubmenuOf: "Figma Folder for a", of: menu)
        await settle()
        let folders = try #require(fixture.folders)
        #expect(folders.keys.sorted() == [fixture.b])
        #expect(folders[fixture.b] as? String == FolderFixture.linkC)
        #expect(counter.plans == 1)
        #expect(counter.alerts.isEmpty)
    }

    @Test func theDialogsSaveWritesTheResolvedKeyAndTheTrimmedLinkThroughOnePlan() async throws {
        let fixture = try fixture("")
        defer { fixture.cleanup() }
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        var seen: FigmaFolderDialogState?
        let menu = try menu(w, fixture, writer: writer(fixture, counter), dialog: { state, _ in
            seen = state
            var picked = state
            picked.type("  \(FolderFixture.linkA)?fuid=1  ")
            return picked.link.map { FigmaFolderDialogResult(link: $0, directory: picked.resolvedDirectory) }
        })
        try pick("Set Figma Folder…", inSubmenuOf: "Figma Default Folder", of: menu)
        await settle()
        #expect(seen?.selectedDirectory == fixture.aInner)
        let folders = try #require(fixture.folders)
        #expect(folders.keys.sorted() == [fixture.aInner])
        #expect(folders[fixture.aInner] as? String == FolderFixture.linkA)
        #expect(counter.plans == 1)
        #expect(counter.alerts.isEmpty)
    }

    @Test func cancelWritesNothing() async throws {
        let fixture = try fixture("")
        defer { fixture.cleanup() }
        let before = fixture.bytes
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter))
        try pick("Set Figma Folder…", inSubmenuOf: "Figma Default Folder", of: menu)
        await settle()
        #expect(fixture.bytes == before)
        #expect(counter.plans == 0)
    }

    @Test func aFailedWriteLeavesTheFileAndShowsTheAlertOnce() async throws {
        let fixture = try fixture(#""@a": "\#(FolderFixture.linkB)""#)
        defer { fixture.cleanup() }
        let before = fixture.bytes
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], atPath: fixture.root + "/config")
        try pick("Remove Folder for a", inSubmenuOf: "Figma Folder for a", of: menu)
        await settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], atPath: fixture.root + "/config")
        #expect(fixture.bytes == before)
        #expect(counter.alerts.count == 1)
        #expect(counter.alerts.first?.hasPrefix("figma.folders: ") == true, "\(counter.alerts)")
    }

    @Test func aFileThatIsNotValidJSONGetsTheAlertAndIsNotWritten() async throws {
        let fixture = try fixture(#""@a": "\#(FolderFixture.linkB)""#)
        defer { fixture.cleanup() }
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter))
        try Data("{ not json".utf8).write(to: fixture.file)
        try pick("Remove Folder for a", inSubmenuOf: "Figma Folder for a", of: menu)
        await settle()
        #expect(fixture.bytes == Data("{ not json".utf8))
        #expect(counter.alerts.count == 1)
    }

    @Test func setReReadsTheFileAtThePressSoAnEntryWrittenMeanwhileStays() async throws {
        let fixture = try fixture(#""@a": "\#(FolderFixture.linkB)""#)
        defer { fixture.cleanup() }
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter), dialog: { state, _ in
            // The shape of a CLI's `set --dir`, written while the dialog is open.
            let other = JSONConfigStore(fileURL: fixture.file)
            var written = (try? other.strictRoot()) ?? [:]
            var figma = (written["figma"] as? [String: Any]) ?? [:]
            var folders = (figma["folders"] as? [String: Any]) ?? [:]
            folders[fixture.b] = FolderFixture.linkC
            figma["folders"] = folders
            written["figma"] = figma
            try? JSONSerialization.data(withJSONObject: written).write(to: fixture.file)
            var picked = state
            picked.type(FolderFixture.linkA)
            return picked.link.map { FigmaFolderDialogResult(link: $0, directory: picked.resolvedDirectory) }
        })
        try pick("Set Figma Folder…", inSubmenuOf: "Figma Folder for a", of: menu)
        await settle()
        let folders = try #require(fixture.folders)
        #expect(folders[fixture.b] as? String == FolderFixture.linkC, "\(folders)")
        #expect(folders[fixture.a] as? String == FolderFixture.linkA, "\(folders)")
    }

    @Test func removeReReadsTheFileAtThePickSoAnEntryWrittenMeanwhileStays() async throws {
        let fixture = try fixture(#""@a": "\#(FolderFixture.linkB)""#)
        defer { fixture.cleanup() }
        let counter = Counter()
        let w = Workspace(); defer { w.teardownAllPanels() }
        w.currentDirectory = fixture.aInner
        let menu = try menu(w, fixture, writer: writer(fixture, counter))
        let other = JSONConfigStore(fileURL: fixture.file)
        var written = try other.strictRoot()
        var figma = try #require(written["figma"] as? [String: Any])
        var folders = try #require(figma["folders"] as? [String: Any])
        folders[fixture.b] = FolderFixture.linkC
        figma["folders"] = folders
        written["figma"] = figma
        try JSONSerialization.data(withJSONObject: written).write(to: fixture.file)
        try pick("Remove Folder for a", inSubmenuOf: "Figma Folder for a", of: menu)
        await settle()
        let after = try #require(fixture.folders)
        #expect(after.keys.sorted() == [fixture.b], "\(after)")
    }
}

/// cm-73.42, Scenarios 380 and 381: the key's registrations and its text in 20 locales. Each test
/// reads data the app ships (the schema, the string catalog, the web message catalogs), never prose.
struct FigmaFolderRegistrationTests {
    private static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let locales = [
        "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km",
        "ko", "nb", "pl", "pt-BR", "ru", "th", "tr", "uk", "zh-Hans", "zh-Hant"
    ]
    private static let webLocales = [
        "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km",
        "ko", "no", "pl", "pt-BR", "ru", "th", "tr", "uk", "zh-CN", "zh-TW"
    ]
    private static let newKeys = [
        "figma.menu.folder.forDirectory", "figma.menu.folder.default", "figma.menu.folder.forPath",
        "figma.menu.folder.defaultScope", "figma.menu.folder.open", "figma.menu.folder.set",
        "figma.menu.folder.remove", "figma.menu.folder.noTeam", "figma.menu.folder.notAFolder",
        "figma.menu.folder.notText", "figma.menu.folder.home", "figma.folderDialog.title",
        "figma.folderDialog.message", "figma.folderDialog.directory", "figma.folderDialog.link",
        "figma.folderDialog.placeholder", "figma.folderDialog.noTeam", "figma.folderDialog.notAFolder",
        "figma.folderDialog.hasFolder", "figma.folderDialog.set", "figma.folderDialog.invalidJSON"
    ]
    private static let oldDefaultWords = "where new designs your agent creates should go"

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func settingsFileStoreSupportsTheKey() {
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("figma.folders"))
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("figma.defaultFolder"))
    }

    @Test func schemaDescribesFoldersAsAnObjectOfStrings() throws {
        let schema = try json("web/data/cmux.schema.json")
        let figma = try #require((schema["properties"] as? [String: Any])?["figma"] as? [String: Any])
        let properties = try #require(figma["properties"] as? [String: Any])
        let folders = try #require(properties["folders"] as? [String: Any])
        #expect(folders["type"] as? String == "object")
        #expect((folders["additionalProperties"] as? [String: Any])?["type"] as? String == "string")
        #expect(folders["descriptionKey"] as? String == "schemaDescriptions.figma.folders")
        let defaultFolder = try #require(properties["defaultFolder"] as? [String: Any])
        let description = try #require(defaultFolder["description"] as? String)
        #expect(description.contains("when figma.folders has no entry for their directory"), "\(description)")
        #expect(!description.lowercased().contains(Self.oldDefaultWords))
    }

    @Test func everyWebMessageCatalogDescribesBothKeys() throws {
        func figmaDescriptions(_ locale: String) throws -> [String: String] {
            let messages = try json("web/messages/\(locale).json")
            let docs = try #require(messages["docs"] as? [String: Any])
            let configuration = try #require(docs["configuration"] as? [String: Any])
            let descriptions = try #require(configuration["schemaDescriptions"] as? [String: Any])
            return try #require(descriptions["figma"] as? [String: String], "\(locale)")
        }
        let english = try figmaDescriptions("en")
        for locale in Self.webLocales {
            let figma = try figmaDescriptions(locale)
            let folders = try #require(figma["folders"], "\(locale): figma.folders")
            let defaultFolder = try #require(figma["defaultFolder"], "\(locale): figma.defaultFolder")
            #expect(!folders.isEmpty && !defaultFolder.isEmpty && folders != defaultFolder, "\(locale)")
            #expect(folders.contains("cmux figma folder"), "\(locale): the command is named")
            #expect(defaultFolder.contains("figma.folders"), "\(locale): the default description names the key")
            if locale != "en" { #expect(folders != english["folders"], "\(locale) is still English") }
        }
        #expect(english["folders"]?.hasPrefix("Figma folders for directories: each key is a directory") == true)
        #expect(!(english["defaultFolder"] ?? "").lowercased().contains(Self.oldDefaultWords))
    }

    @Test func catalogHasEveryNewAndChangedStringInTwentyLocales() throws {
        let catalog = try json("Resources/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        func values(_ key: String) throws -> [String: String] {
            let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key)")
            var result: [String: String] = [:]
            for (locale, body) in localizations {
                result[locale] = ((body as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            return result
        }
        for key in Self.newKeys {
            let found = try values(key)
            #expect(Set(found.keys) == Set(Self.locales), "\(key): \(Set(Self.locales).symmetricDifference(found.keys))")
            #expect(found.values.allSatisfy { !($0 ?? "").isEmpty }, "\(key) has an empty value")
        }
        for key in ["figma.menu.folder.forDirectory", "figma.menu.folder.forPath", "figma.menu.folder.remove"] {
            let found = try values(key)
            #expect(found.values.allSatisfy { ($0 ?? "").contains("%@") }, "\(key) lost its %@")
        }
        for key in [
            "settings.automation.figma.defaultFolder.subtitle.set",
            "settings.automation.figma.defaultFolder.subtitle.notSet"
        ] {
            let found = try values(key)
            #expect(found["en"]?.contains("unless their directory has") == true, "\(key): \(String(describing: found["en"]))")
            #expect(Set(found.values.compactMap { $0 }).count == 20, "\(key) shares a value between locales")
        }
        #expect(try values("settings.automation.figma.defaultFolder.subtitle.set")["en"]?.contains("%@") == true)
    }
}

/// cm-73.42, fix round 1 (item 5): the refusal line must fit inside the alert's window. The alert sizes
/// its window once from the accessory view, before the empty refusal label is hidden, and the no-team
/// refusal is two lines. Measured on the base sizing: it fits, so this guards a regression, not a bug.
@MainActor @Suite(.serialized) struct FigmaFolderDialogLayoutTests {
    /// The real flow: the alert sizes its window from the accessory view once, before the person types.
    @Test(arguments: [
        "https://www.figma.com/files/folder/643299150",
        "https://example.com/not-a-figma-folder"
    ])
    func theRefusalLineSitsInsideTheAlertWindow(link: String) throws {
        // (The accessibility help and the tab order are asserted below, after the link is typed.)
        let state = FigmaFolderDialogState(
            directory: "/Volumes/tom-ssd/src/proj",
            entries: .empty,
            choice: .defaultOnly(FolderFixture.linkA)
        )
        let controller = FigmaFolderDialog.Controller(state: state)
        let alert = NSAlert()
        alert.messageText = "Set Figma Folder"
        alert.informativeText = "New designs made in this directory, or any directory inside it, go to the Figma folder you paste here."
        alert.accessoryView = controller.view
        alert.addButton(withTitle: "Set Folder")
        alert.addButton(withTitle: "Cancel")
        controller.setButton = alert.buttons.first
        controller.refresh()
        alert.layout()
        let window = alert.window
        let content = try #require(window.contentView)
        controller.field.stringValue = link
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.field))
        content.layoutSubtreeIfNeeded()
        let label = controller.refusal
        let drawn = label.convert(label.alignmentRect(forFrame: label.frame), to: nil)
        let windowRect = NSRect(origin: .zero, size: content.frame.size)
        #expect(windowRect.contains(drawn), "refusal \(drawn) is outside the window content \(windowRect)")
        #expect(controller.view.bounds.contains(label.alignmentRect(forFrame: label.frame)))
        #expect(label.alignmentRect(forFrame: label.frame).height >= label.fittingSize.height - 0.5)
        // Accessibility (16): the field's help is the refusal's words while it shows, without the mark.
        let shown = label.stringValue
        #expect(shown.hasPrefix("⚠ "))
        #expect(controller.field.accessibilityHelp() == String(shown.dropFirst(2)), "\(String(describing: controller.field.accessibilityHelp()))")
        // Nothing else of the dialog was pushed out either.
        for view in [controller.popUp, controller.field] as [NSView] {
            #expect(controller.view.bounds.contains(view.frame), "\(view) \(view.frame) vs \(controller.view.bounds)")
        }
        // A link that passes clears the help.
        controller.field.stringValue = FolderFixture.linkB
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.field))
        #expect(controller.field.accessibilityHelp() == nil)
    }
}
