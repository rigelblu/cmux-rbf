import AppKit
import CmuxSettings
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarSectionNameTests {
    private let key = SidebarCatalogSection().sectionNames.userDefaultsKey

    private func withNames(_ value: Any? = nil, _ body: @MainActor () async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let keys = [key, "cmux.settingsFile.backups.v1", "cmux.settingsFile.importedManagedDefaults.v1"]
            let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, previous) {
                    if let value { UserDefaults.standard.set(value, forKey: key) }
                    else { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
            if let value { UserDefaults.standard.set(value, forKey: key) }
            try await body()
        }
    }

    private func assertNames(_ pinned: String, _ workspaces: String, _ statuses: String) {
        #expect(SidebarStatusHeaderText.pinnedAreaTitle == pinned)
        #expect(SidebarStatusHeaderText.workspacesAreaTitle == workspaces)
        #expect(SidebarStatusHeaderText.statusesAreaTitle == statuses)
        for collapsed in [false, true] {
            let state = collapsed ? "collapsed" : "expanded"
            let action = collapsed ? "Expand" : "Collapse"
            #expect(SidebarStatusHeaderText.pinnedAreaLabel(isCollapsed: collapsed) == "\(pinned), \(state)")
            #expect(SidebarStatusHeaderText.workspacesAreaLabel(isCollapsed: collapsed) == "\(workspaces), \(state)")
            #expect(SidebarStatusHeaderText.statusesAreaLabel(groupCount: 3, isCollapsed: collapsed) == "\(statuses), 3 status groups, \(state)")
            for (kind, name) in [(SidebarStatusHeaderKind.pinnedArea, pinned), (.workspacesArea, workspaces), (.statusesArea, statuses)] {
                #expect(SidebarStatusHeaderText.chevronLabel(kind: kind, isCollapsed: collapsed) == "\(action) \(name) area")
            }
        }
    }

    @Test func absentNamesUseWorkblocksAndTheSameFormatsAsExplicitDefaults() async throws {
        try await withNames {
            assertNames("Pinned", "Workspaces", "Workblocks")
            UserDefaults.standard.set(["pinned": "Pinned", "workspaces": "Workspaces", "statuses": "Workblocks"], forKey: key)
            assertNames("Pinned", "Workspaces", "Workblocks")
        }
    }

    @Test func eachTrimmedNameReplacesOnlyItsOwnHeaderWords() async throws {
        try await withNames(["pinned": " Favorites\n", "workspaces": " Loose ", "statuses": "\tBoard "]) {
            assertNames("Favorites", "Loose", "Board")
            #expect(SidebarStatusHeaderText.statusGroupLabel(name: "Parked", memberCount: 2, isCollapsed: false) == "Status group, Parked, 2 workspaces, expanded")
            #expect(SidebarStatusHeaderText.chevronLabel(kind: .statusGroup("parked"), isCollapsed: true) == "Expand status group")
            #expect(String(localized: "sidebar.tree.group.pinned", defaultValue: "Pinned") == "Pinned")
        }
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyNamesFallBackWithoutDiscardingSiblings(_ invalid: String) async throws {
        try await withNames(["statuses": invalid, "workspaces": "Loose"]) {
            assertNames("Pinned", "Loose", "Workblocks")
        }
    }

    @Test func nonStringAndUnknownChildrenFallBackWithoutDiscardingSiblings() async throws {
        try await withNames(["statuses": 7, "pinned": "Favorites", "pins": "Wrong"]) {
            assertNames("Favorites", "Workspaces", "Workblocks")
        }
    }

    @Test func userNamesKeepPercentSignsUnicodeAndLongText() async throws {
        let name = "Board %@ • 作業 " + String(repeating: "x", count: 60)
        try await withNames(["statuses": name]) { assertNames("Pinned", "Workspaces", name) }
    }

    @Test func fileParserDispatchesTheObjectAndRemovalRestoresDefaultsWithoutRewritingTheFile() async throws {
        try await withNames {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("cmux.json")
            let data = Data(#"{"sidebar":{"sectionNames":{"pinned":" Favorites ","workspaces":" Loose ","statuses":" Board ","pins":"Ignored"}}}"#.utf8)
            try data.write(to: file)
            let store = CmuxSettingsFileStore(primaryPath: file.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: false)
            assertNames("Favorites", "Loose", "Board")
            #expect(UserDefaults.standard.dictionary(forKey: key) as? [String: String] == ["pinned": "Favorites", "workspaces": "Loose", "statuses": "Board"])
            #expect(try Data(contentsOf: file) == data)
            let removed = Data("{}".utf8)
            try removed.write(to: file)
            store.reload()
            assertNames("Pinned", "Workspaces", "Workblocks")
            #expect(try Data(contentsOf: file) == removed)
        }
    }

    @Test func nonObjectNamesUseDefaultsAndLogOneInvalidSetting() async throws {
        try await withNames {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("cmux.json")
            try #"{"sidebar":{"sectionNames":"Board"}}"#.write(to: file, atomically: true, encoding: .utf8)
            let store = CmuxSettingsFileStore(primaryPath: file.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: false)
            defer { withExtendedLifetime(store) {} }
            assertNames("Pinned", "Workspaces", "Workblocks")
            #expect(store.invalidSettingPaths == ["sidebar.sectionNames"])
            try "{}".write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(store.invalidSettingPaths.isEmpty, "a successful reload clears the previous invalid paths")
        }
    }

    @Test func settingsPathsExposeAllThreeChildrenAndNewFileTemplateOmitsNames() async throws {
        for name in ["pinned", "workspaces", "statuses"] {
            #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.sectionNames.\(name)"))
        }
        #expect(!CmuxSettingsFileStore.defaultTemplate().contains("sectionNames"))
    }

    @Test func debugRowsUseTheSameResolvedTitlesAndKeepSemanticIdentities() async throws {
        try await withNames(["pinned": "Favorites", "workspaces": "Loose", "statuses": "Board"]) {
            let rows = SidebarDebugRow.rows(from: [.pinnedHeader, .workspacesHeader, .statusesHeader], workspaceTitle: { _ in "" }, groupName: { _ in "" }, groupIsFolded: { _ in false }, groupIdOfWorkspace: { _ in nil }, statusName: { $0 })
            #expect(rows.map(\.title) == ["Favorites", "Loose", "Board"])
            #expect(rows.map(\.kind) == ["pinnedHeader", "workspacesHeader", "statusesHeader"])
            #expect(rows.map(\.id) == [SidebarStatusHeaderIdentity.pinnedAreaUUID, SidebarStatusHeaderIdentity.workspacesAreaUUID, SidebarStatusHeaderIdentity.statusesAreaUUID].map(\.uuidString))
        }
    }
    private func descendants<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var matches = (root as? T).map { [$0] } ?? []
        matches += root.subviews.flatMap { descendants(type, in: $0) }
        return matches
    }

    @Test func nativeHeaderModelsAndAXReadNamesIndependentlyOfTheFileParser() async throws {
        try await withNames(["pinned": "Favorites", "workspaces": "Loose", "statuses": "Board"]) {
            let environment = SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: SidebarLazyContractProbe()
            )
            for collapsed in [false, true] {
                let state = collapsed ? "collapsed" : "expanded"
                let action = collapsed ? "Expand" : "Collapse"
                for (kind, name) in [(SidebarStatusHeaderKind.pinnedArea, "Favorites"), (.workspacesArea, "Loose"), (.statusesArea, "Board")] {
                    let model = VerticalTabsSidebar.statusHeaderModel(kind: kind, presentation: nil, memberCount: 3,
                        unreadCount: 0, isCollapsed: collapsed, environment: environment)
                    #expect(model.name == name, "the native model reads its section's resolved title")
                    let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
                    cell.configurePresentation(model: model)
                    let label = kind == .statusesArea ? "\(name), 3 status groups, \(state)" : "\(name), \(state)"
                    #expect(cell.accessibilityLabel() == label)
                    #expect(descendants(NSButton.self, in: cell).contains { $0.accessibilityLabel() == "\(action) \(name) area" })
                    #expect(descendants(NSTextField.self, in: cell).contains { $0.stringValue == name })
                }
            }
        }
    }

    @Test func savingNamesRefreshesMountedHeadersWithoutChangingWindowOrWorkspaceState() async throws {
        try await withNames {
            let handle = try SidebarNestedRootStatusTests.installStatusListHandle()
            defer { handle.restore() }
            let world = try SidebarSectionIndentMountedTests.World(nested: false, colored: false)
            let harness = SidebarSectionIndentMountedTests()
            let mounted = try await harness.mount(world.manager)
            defer { harness.close(mounted) }
            let store = CmuxSettingsFileStore(primaryPath: handle.file.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: true)
            defer { withExtendedLifetime(store) {} }
            let order = world.manager.tabs.map(\.id)
            let groups = world.manager.workspaceGroups
            let pid = ProcessInfo.processInfo.processIdentifier
            @MainActor func cells() -> [SidebarGroupHeaderTableCellView] {
                descendants(SidebarGroupHeaderTableCellView.self, in: mounted.table).filter {
                    guard let kind = $0.currentModelForTesting?.statusHeaderKind else { return false }
                    return [SidebarStatusHeaderKind.pinnedArea, .workspacesArea, .statusesArea].contains(kind)
                }
            }
            @MainActor func readNames() -> Set<String> { Set(cells().compactMap { $0.currentModelForTesting?.name }) }
            #expect(readNames() == ["Pinned", "Workspaces", "Workblocks"])
            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: handle.file)) as? [String: Any])
            var renamed = object
            renamed["sidebar"] = ["sectionNames": ["pinned": "Favorites", "workspaces": "Loose", "statuses": "Board"]]
            let data = try JSONSerialization.data(withJSONObject: renamed, options: [.sortedKeys])
            try data.write(to: handle.file)
            let deadline = Date().addingTimeInterval(5)
            while readNames() != ["Favorites", "Loose", "Board"] && Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
                await harness.drain(mounted.window, iterations: 2)
            }
            #expect(readNames() == ["Favorites", "Loose", "Board"], "saving the file refreshes the existing native header models within five seconds")
            for cell in cells() {
                let name = try #require(cell.currentModelForTesting?.name)
                #expect(cell.accessibilityLabel()?.hasPrefix(name + ", ") == true)
                #expect(descendants(NSButton.self, in: cell).contains { $0.accessibilityLabel() == "Collapse \(name) area" })
            }
            #expect(try Data(contentsOf: handle.file) == data)
            let removed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try removed.write(to: handle.file)
            let removalDeadline = Date().addingTimeInterval(5)
            while readNames() != ["Pinned", "Workspaces", "Workblocks"] && Date() < removalDeadline {
                try await Task.sleep(for: .milliseconds(25))
                await harness.drain(mounted.window, iterations: 2)
            }
            #expect(readNames() == ["Pinned", "Workspaces", "Workblocks"])
            #expect(try Data(contentsOf: handle.file) == removed)
            #expect(world.manager.tabs.map(\.id) == order)
            #expect(world.manager.workspaceGroups == groups)
            #expect(ProcessInfo.processInfo.processIdentifier == pid)
        }
    }

    @Test func swiftUIHeaderValuesAndEqualityIncludeTheResolvedName() async throws {
        try await withNames {
            let original = SidebarStatusesAreaSwiftUIHeader(groupCount: 3, isCollapsed: false)
            UserDefaults.standard.set(["pinned": "Favorites", "workspaces": "Loose", "statuses": "Board"], forKey: key)
            let renamed = SidebarStatusesAreaSwiftUIHeader(groupCount: 3, isCollapsed: false)
            #expect(original != renamed, "a new name invalidates an otherwise unchanged SwiftUI status header")
            let status = try #require(renamed.body as? SidebarSectionSwiftUIHeader)
            #expect(status.title == "Board")
            #expect(status.label == "Board, 3 status groups, expanded")
            let pinned = VerticalTabsSidebar.sidebarPinnedAreaHeaderRow(folds: .init(), memberIds: [], unreadSnapshot: .init(), onToggle: {})
            #expect(pinned.title == "Favorites" && pinned.label == "Favorites, expanded")
            let loose = VerticalTabsSidebar.sidebarWorkspacesAreaHeaderRow(folds: .init(), memberIds: [], unreadSnapshot: .init(), onToggle: {})
            #expect(loose.title == "Loose" && loose.label == "Loose, expanded")
        }
    }

}
