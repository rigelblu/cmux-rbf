import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Group status app integration", .serialized)
struct WorkspaceGroupStatusTests {
    private func managerAndGroup() -> (TabManager, UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let id = UUID()
        workspace.groupId = id
        manager.workspaceGroups = [WorkspaceGroup(id: id, name: "Group", isCollapsed: false, isPinned: false,
                                                 anchorWorkspaceId: workspace.id, customColor: "#123456", iconSymbol: nil)]
        return (manager, id)
    }

    @Test func selectedGroupStatusIsSavedAndRestoredAfterRelaunch() throws {
        let (manager, _) = managerAndGroup()
        manager.workspaceGroups[0].statusId = "parked"
        manager.workspaceGroups[0].customColor = "#765432"
        let data = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)
        #expect(decoded.workspaceGroups?.first?.statusId == "parked")
        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(decoded)
        #expect(restored.workspaceGroups.first?.statusId == "parked")
        #expect(restored.workspaceGroups.first?.customColor == "#765432")
    }

    @Test func legacySessionJSONWithoutStatusIdDecodesAndRestores() throws {
        let (manager, _) = managerAndGroup()
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let data = try JSONEncoder().encode(snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var groups = try #require(json["workspaceGroups"] as? [[String: Any]])
        groups[0].removeValue(forKey: "statusId")
        #expect(groups[0]["statusId"] == nil)
        json["workspaceGroups"] = groups
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.workspaceGroups?.first?.statusId == nil)
        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(decoded)
        #expect(restored.workspaceGroups.first?.statusId == nil)
        #expect(restored.workspaceGroups.first?.customColor == "#123456")
        #expect(restored.tabs.map(\.id) == manager.tabs.map(\.id))
        #expect(restored.tabs.map(\.groupId) == manager.tabs.map(\.groupId))
    }

    @Test func emptyGroupStatusRestoresWithoutAColorPick() throws {
        let (manager, id) = managerAndGroup()
        var group = SessionWorkspaceGroupSnapshot(id: id, name: "Empty", isCollapsed: true,
                                                  anchorIsEmpty: true, isPinned: true, customColor: "#765432")
        group.statusId = "unlisted"
        var base = manager.sessionSnapshot(includeScrollback: false)
        for index in base.workspaces.indices { base.workspaces[index].groupId = nil }
        let saved = SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: base.workspaces, workspaceGroups: [group])
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)
        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(decoded)
        let actual = try #require(restored.workspaceGroups.first)
        #expect(actual.statusId == "unlisted")
        #expect(actual.customColor == "#765432")
        #expect(actual.isEmpty)
    }

    @Test func changingOnlyStatusChangesAutosaveFingerprint() {
        let (manager, _) = managerAndGroup()
        let before = manager.sessionAutosaveFingerprint()
        manager.workspaceGroups[0].statusId = "unlisted"
        #expect(manager.sessionAutosaveFingerprint() != before)
    }

    @Test func groupColorStillPicksAndClearsStatusWithControlsOff() throws {
        try underListWithControlsOff {
            let (manager, id) = managerAndGroup()
            #expect(!WorkspaceTodoFeature.isEnabled)
            manager.setWorkspaceGroupColor(groupId: id, hex: "#765432")
            #expect(manager.workspaceGroups[0].statusId == "parked")
            manager.setWorkspaceGroupColor(groupId: id, hex: nil)
            #expect(manager.workspaceGroups[0].statusId == nil)
            #expect(manager.workspaceGroups[0].customColor == nil)
        }
    }

    @Test func unchangedLegacyColorCanBePickedToGiveItStatus() throws {
        try underListWithControlsOff {
            let (manager, id) = managerAndGroup()
            manager.workspaceGroups[0].customColor = "#765432"
            manager.setWorkspaceGroupColor(groupId: id, hex: "#765432")
            #expect(manager.workspaceGroups[0].statusId == "parked")
        }
    }

    @Test(arguments: [nil, "parked", "unlisted"] as [String?])
    func palettePropagationPreservesStatusInsteadOfPickingOne(_ savedStatus: String?) throws {
        try underListWithControlsOff(palette: ["Custom 11": "#765432"]) {
            let (manager, _) = managerAndGroup()
            manager.workspaceGroups[0].customColor = "#765432"
            manager.workspaceGroups[0].statusId = savedStatus
            AppDelegate.shared?.tabManager = manager
            let coordinator = WorkspacePaletteColorEditCoordinator()
            let preview = try coordinator.preview(appDelegate: AppDelegate.shared, paletteName: "Custom 11",
                                                  expectedOldHex: "#765432", proposedHex: "#008800").get()
            #expect(preview.groupCount == 1)
            #expect(coordinator.apply(preview, decision: .paletteAndAssignments, appDelegate: AppDelegate.shared)
                == .applied(palette: ["Custom 11": "#008800"]))
            #expect(manager.workspaceGroups[0].customColor == "#008800")
            #expect(manager.workspaceGroups[0].statusId == savedStatus)
        }
    }

    private func underListWithControlsOff(palette: [String: String]? = nil, _ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let colorReference = palette == nil ? "#765432" : "Custom 11"
        let oldPalette = UserDefaults.standard.dictionary(forKey: WorkspaceTabColorSettings.paletteKey)
        if let palette { WorkspaceTabColorSettings.persistPaletteMap(palette) }
        defer {
            if palette != nil {
                WorkspaceTabColorSettings.reset(defaults: .standard)
                if let oldPalette { UserDefaults.standard.set(oldPalette, forKey: WorkspaceTabColorSettings.paletteKey) }
            }
        }
        try """
        { "workspaceStatuses": [{ "id": "parked", "name": "Parked", "extends": "todo", "color": "\(colorReference)" }] }
        """.write(to: file, atomically: true, encoding: .utf8)
        let suite = "GroupStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults,
                                             resolveColor: { WorkspaceTabColorSettings.resolvedColorHex($0) },
                                             paletteFingerprint: { "fixed" }, clock: ContinuousClock())
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let previousControl = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            AppDelegate.shared = previous
            if let previousControl { UserDefaults.standard.set(previousControl, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }
}
