import AppKit
import CmuxCommandPalette
import CmuxCore
import CmuxSettings
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

fileprivate let windowIdString = "01234567-89AB-CDEF-0123-456789ABCDEF"

/// #cm-104 — a window carries an optional name the user gave it; the macOS
/// title leads with it. Serialized within this suite. Tests writing the
/// shared title template key in `UserDefaults.standard` live in
/// `WindowTitleTemplateTests` below so they join that suite's `.serialized` order.
@MainActor
@Suite(.serialized)
struct WindowNameTests {

    // MARK: Scenario 1 — the core rule

    @Test func namedWindowTitleLeadsWithName() throws {
        let (manager, window) = makeManager(title: "Build")
        defer { detach(manager, window) }

        manager.refreshWindowTitle()
        #expect(window.title == "Build")

        #expect(manager.setWindowName("research"))
        // Space, em dash (U+2014), space — and written at once, with no refresh call.
        #expect(window.title == "research \u{2014} Build")
        #expect(manager.windowName == "research")
    }

    // MARK: Scenario 2 — the name stays put

    @Test func nameSurvivesWorkspaceSwitchAndRename() async throws {
        // windowId stays nil so a title template left set elsewhere cannot apply.
        let (manager, window) = makeManager(title: "Build")
        defer { detach(manager, window) }
        manager.setWindowName("research")
        #expect(window.title == "research \u{2014} Build")

        let deploy = manager.addWorkspace(title: "Deploy", select: true, autoWelcomeIfNeeded: false)
        // A switch writes the title on the next turn of the main queue.
        await drainMainQueue()
        #expect(manager.selectedTabId == deploy.id)
        #expect(window.title == "research \u{2014} Deploy")

        manager.setCustomTitle(tabId: deploy.id, title: "Ship")
        #expect(window.title == "research \u{2014} Ship")
        #expect(manager.windowName == "research")
    }

    // MARK: Scenario 3 — unnamed is unchanged; the fallbacks hold when named

    /// Guards existing behaviour: passes with and without #cm-104.
    @Test func unnamedWindowTitleIsUnchanged() throws {
        let (manager, window) = makeManager(title: "Build", directory: "/tmp/old")
        defer { detach(manager, window) }
        #expect(manager.windowName == nil)

        manager.refreshWindowTitle()
        #expect(window.title == "Build")

        let workspace = try #require(manager.selectedWorkspace)
        workspace.title = "   "
        manager.refreshWindowTitle()
        #expect(window.title == "/tmp/old")

        manager.updateWindowTitle(for: nil)
        #expect(window.title == "cmux")
    }

    @Test func namedWindowTitleUsesSameFallbacks() throws {
        let (manager, window) = makeManager(title: "Build", directory: "/tmp/old")
        defer { detach(manager, window) }
        manager.setWindowName("research")
        #expect(window.title == "research \u{2014} Build")

        let workspace = try #require(manager.selectedWorkspace)
        workspace.title = "   "
        manager.refreshWindowTitle()
        #expect(window.title == "research \u{2014} /tmp/old")

        manager.updateWindowTitle(for: nil)
        #expect(window.title == "research \u{2014} cmux")
    }

    // MARK: Scenario 4 — the one setter normalizes for every way in

    @Test func setterTrimsAndBlankClears() throws {
        let (manager, window) = makeManager(title: "Build")
        defer { detach(manager, window) }

        // Blank on an unnamed window changes nothing.
        #expect(!manager.setWindowName(""))
        #expect(!manager.setWindowName("   \n"))
        #expect(!manager.setWindowName(nil))
        #expect(manager.windowName == nil)

        #expect(manager.setWindowName("  research  "))
        #expect(manager.windowName == "research")
        #expect(window.title == "research \u{2014} Build")

        // The same name again changes nothing.
        #expect(!manager.setWindowName("research"))
        #expect(!manager.setWindowName(" research\n"))

        for blank in ["", "   \n", "\n\n"] {
            manager.setWindowName("research")
            #expect(manager.setWindowName(blank))
            #expect(manager.windowName == nil)
            // Back to the unnamed title at once.
            #expect(window.title == "Build")
        }

        manager.setWindowName("research")
        #expect(manager.setWindowName(nil))
        #expect(manager.windowName == nil)
        #expect(window.title == "Build")

        let longName = "research notes for the window naming feature in cmux rbf dev"
        #expect(longName.count == 60)
        #expect(manager.setWindowName(longName))
        #expect(manager.windowName == longName)
        #expect(window.title == "\(longName) \u{2014} Build")
    }

    @Test func setterTurnsLineBreaksIntoSpaces() throws {
        let (manager, window) = makeManager(title: "Build")
        defer { detach(manager, window) }

        #expect(manager.setWindowName("research\nnotes"))
        #expect(manager.windowName == "research notes")
        #expect(window.title == "research notes \u{2014} Build")

        // Each RUN of newline characters is one space, not one per character.
        manager.setWindowName(nil)
        #expect(manager.setWindowName("research\n\n\nnotes"))
        #expect(manager.windowName == "research notes")

        manager.setWindowName(nil)
        #expect(manager.setWindowName("research\r\nnotes\n"))
        #expect(manager.windowName == "research notes")
    }

    // MARK: Scenario 5 — each window has its own name

    @Test func nameIsPerWindow() throws {
        let (first, firstWindow) = makeManager(title: "Build")
        defer { detach(first, firstWindow) }
        let (second, secondWindow) = makeManager(title: "Deploy")
        defer { detach(second, secondWindow) }
        first.refreshWindowTitle()
        second.refreshWindowTitle()

        #expect(first.setWindowName("research"))
        #expect(firstWindow.title == "research \u{2014} Build")
        #expect(second.windowName == nil)
        #expect(secondWindow.title == "Deploy")

        let fresh = TabManager(initialWorkspaceTitle: "Fresh", autoWelcomeIfNeeded: false)
        #expect(fresh.windowName == nil)
    }


    // MARK: Scenario 7 — saved, restored, and first in restore

    @Test func nameRoundTripsThroughSessionSnapshot() throws {
        let (source, sourceWindow) = makeManager(title: "Build")
        defer { detach(source, sourceWindow) }
        source.setWindowName("research")

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.windowName == "research")

        // Through the encoder too: this is what the session file holds.
        let decoded = try JSONDecoder().decode(
            SessionTabManagerSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.windowName == "research")

        let (restored, restoredWindow) = makeManager(title: "Initial")
        defer { detach(restored, restoredWindow) }
        #expect(restored.windowName == nil)
        restored.restoreSessionSnapshot(decoded)
        #expect(restored.windowName == "research")
    }

    @Test func everyTitleAfterRestoreBeginsIsNamed() async throws {
        let (source, sourceWindow) = makeManager(title: "Build")
        defer { detach(source, sourceWindow) }
        source.setWindowName("research")
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        // windowId stays nil so a title template left set elsewhere cannot apply.
        let restored = TabManager(initialWorkspaceTitle: "Initial", autoWelcomeIfNeeded: false)
        let window = RecordingTitleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        restored.window = window
        defer { detach(restored, window) }
        restored.refreshWindowTitle()
        #expect(window.title == "Initial")

        // The probe: force a title write whenever the manager announces a
        // change, which restore does synchronously when it swaps `tabs`.
        // This stands in for the in-place restore path, where a UserDefaults
        // change can refresh the title mid-restore.
        var probeFireCount = 0
        let probe = restored.objectWillChange.sink { [weak restored] _ in
            probeFireCount += 1
            restored?.refreshWindowTitle()
        }
        defer { probe.cancel() }

        window.recordedTitles.removeAll()
        restored.restoreSessionSnapshot(snapshot)

        // Before draining: these titles were written INSIDE restoreSessionSnapshot.
        let midRestoreTitles = window.recordedTitles
        #expect(probeFireCount > 0)
        #expect(!midRestoreTitles.isEmpty, "no title was written mid-restore; the order is not pinned")
        for title in midRestoreTitles {
            #expect(title.hasPrefix("research \u{2014} "), "mid-restore title was unnamed: \(title)")
        }

        await drainMainQueue()
        #expect(!window.recordedTitles.isEmpty)
        for title in window.recordedTitles {
            #expect(title.hasPrefix("research \u{2014} "), "title after restore began was unnamed: \(title)")
        }
        #expect(window.title == "research \u{2014} Build")
    }

    @Test func restoringNamelessSnapshotClearsName() async throws {
        let (source, sourceWindow) = makeManager(title: "Deploy")
        defer { detach(source, sourceWindow) }
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.windowName == nil)

        let (target, targetWindow) = makeManager(title: "Build")
        defer { detach(target, targetWindow) }
        target.setWindowName("build")
        #expect(targetWindow.title == "build \u{2014} Build")

        target.restoreSessionSnapshot(snapshot)
        #expect(target.windowName == nil)
        await drainMainQueue()
        #expect(targetWindow.title == "Deploy")
    }

    @Test func restoreNormalizesASavedName() throws {
        let (source, sourceWindow) = makeManager(title: "Deploy")
        defer { detach(source, sourceWindow) }
        var snapshot = source.sessionSnapshot(includeScrollback: false)

        let (target, targetWindow) = makeManager(title: "Build")
        defer { detach(target, targetWindow) }

        snapshot.windowName = ""
        target.restoreSessionSnapshot(snapshot)
        #expect(target.windowName == nil)

        snapshot.windowName = "a\nb"
        target.restoreSessionSnapshot(snapshot)
        #expect(target.windowName == "a b")
    }

    // MARK: Scenario 8 — a name change is a change worth saving

    @Test func nameChangesAutosaveFingerprint() throws {
        let (manager, window) = makeManager(title: "Build")
        defer { detach(manager, window) }

        let unnamed = manager.sessionAutosaveFingerprint()
        manager.setWindowName("research")
        let research = manager.sessionAutosaveFingerprint()
        #expect(research != unnamed)

        manager.setWindowName("research")
        #expect(manager.sessionAutosaveFingerprint() == research)

        manager.setWindowName("build")
        let build = manager.sessionAutosaveFingerprint()
        #expect(build != research)

        manager.setWindowName(nil)
        let cleared = manager.sessionAutosaveFingerprint()
        #expect(cleared != build)
        #expect(cleared == unnamed)
    }

    // MARK: Scenario 9 — a session saved before this build still loads

    @Test func legacySnapshotDecodesWithoutName() throws {
        let legacyJSON = Data(#"{"selectedWorkspaceIndex":0,"workspaces":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: legacyJSON)
        #expect(legacy.windowName == nil)
        #expect(legacy.selectedWorkspaceIndex == 0)
        #expect(legacy.workspaces.isEmpty)

        // A cleared name is saved as no name, not as an empty one.
        let nameless = SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [])
        let encoded = try JSONEncoder().encode(nameless)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["windowName"] == nil)
        let roundTripped = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: encoded)
        #expect(roundTripped.windowName == nil)
    }

    // MARK: Scenario 10 — the two palette rows and the "has a name" gate

    @Test func windowNameRowsCopyAndKeywords() throws {
        let rows = ContentView.commandPaletteWindowNameCommandContributions()
        #expect(rows.map(\.commandId) == ["palette.nameWindow", "palette.clearWindowName"])
        let empty = CommandPaletteContextSnapshot()

        let name = try #require(rows.first { $0.commandId == "palette.nameWindow" })
        #expect(name.title(empty) == "Name Window\u{2026}")
        #expect(name.subtitle(empty) == "Window")
        #expect(name.keywords == ["name", "rename", "window", "label"])
        #expect(!name.dismissOnRun)
        #expect(name.shortcutHint == nil)

        let clear = try #require(rows.first { $0.commandId == "palette.clearWindowName" })
        #expect(clear.title(empty) == "Clear Window Name")
        #expect(clear.subtitle(empty) == "Window")
        #expect(clear.keywords == ["clear", "remove", "window", "name"])
        #expect(clear.dismissOnRun)
        #expect(clear.shortcutHint == nil)
    }

    @Test func clearWindowNameIsOfferedOnlyWhenNamed() throws {
        let rows = ContentView.commandPaletteWindowNameCommandContributions()
        let name = try #require(rows.first { $0.commandId == "palette.nameWindow" })
        let clear = try #require(rows.first { $0.commandId == "palette.clearWindowName" })

        // No workspace, no name: "Name Window…" is still offered.
        let empty = CommandPaletteContextSnapshot()
        #expect(name.when(empty))
        #expect(!clear.when(empty))

        var unnamed = CommandPaletteContextSnapshot()
        unnamed.setBool(CommandPaletteContextKeys.windowHasName, false)
        unnamed.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(name.when(unnamed))
        #expect(!clear.when(unnamed))

        // Named, with no workspace: the gate reads the one key and nothing else.
        var namedWithoutWorkspace = CommandPaletteContextSnapshot()
        namedWithoutWorkspace.setBool(CommandPaletteContextKeys.windowHasName, true)
        #expect(name.when(namedWithoutWorkspace))
        #expect(clear.when(namedWithoutWorkspace))

        var namedWithWorkspace = namedWithoutWorkspace
        namedWithWorkspace.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(clear.when(namedWithWorkspace))
    }

    // MARK: cm-104.2 — the window's name on workspace rows in the workspace search

    @Test func workspaceRowInNamedWindowShowsTheName() {
        let row = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: "research",
            kindWord: "Workspace"
        )
        #expect(row.trailingLabel == "research")
        #expect(row.extraKeywords == ["research"])
    }

    @Test func workspaceRowInUnnamedWindowIsUnchanged() {
        let row = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: nil,
            kindWord: "Kind"
        )
        #expect(row.trailingLabel == "Kind")
        #expect(row.extraKeywords == [])
    }

    @Test func workspaceRowKeywordIsTheNameLowercased() {
        let row = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: "Research Notes",
            kindWord: "Workspace"
        )
        #expect(row.trailingLabel == "Research Notes")
        #expect(row.extraKeywords == ["research notes"])
    }

    @Test func workspaceRowLongNameIsCutAtItsEnd() {
        let exactlyAtLimit = String(repeating: "a", count: 24)
        let atLimit = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: exactlyAtLimit,
            kindWord: "Workspace"
        )
        #expect(atLimit.trailingLabel == exactlyAtLimit)

        let oneOver = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: String(repeating: "a", count: 23) + "bc",
            kindWord: "Workspace"
        )
        #expect(oneOver.trailingLabel == String(repeating: "a", count: 23) + "\u{2026}")
        #expect(oneOver.trailingLabel.count == 24)

        let longName = String(repeating: "a", count: 23) + "bcdef"
        let long = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: longName,
            kindWord: "Workspace"
        )
        #expect(long.trailingLabel == String(repeating: "a", count: 23) + "\u{2026}")
        #expect(long.trailingLabel.count == 24)
        #expect(long.extraKeywords == [longName])

        // The 23rd character is a space: it is dropped before the ellipsis.
        let spaced = ContentView.commandPaletteSwitcherWorkspaceWindowPresentation(
            windowName: "research notes for the window naming feature in cmux rbf dev",
            kindWord: "Workspace"
        )
        #expect(spaced.trailingLabel == "research notes for the\u{2026}")
        #expect(spaced.trailingLabel.count == 23)
    }

    @Test func switcherFingerprintChangesWithAWindowName() {
        let unnamed = ContentView.commandPaletteSwitcherFingerprint(base: 42, windowNames: [nil, nil])
        let named = ContentView.commandPaletteSwitcherFingerprint(base: 42, windowNames: ["research", nil])
        let renamed = ContentView.commandPaletteSwitcherFingerprint(base: 42, windowNames: ["build", nil])
        let otherWindow = ContentView.commandPaletteSwitcherFingerprint(base: 42, windowNames: [nil, "research"])
        #expect(named != unnamed)
        #expect(renamed != named)
        #expect(otherWindow != named)
        #expect(ContentView.commandPaletteSwitcherFingerprint(base: 42, windowNames: ["research", nil]) == named)
        #expect(ContentView.commandPaletteSwitcherFingerprint(base: 43, windowNames: [nil, nil]) != unnamed)
    }

    // MARK: Helpers

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Records every value written to `NSWindow.title`.
    private final class RecordingTitleWindow: NSWindow {
        var recordedTitles: [String] = []

        override var title: String {
            didSet { recordedTitles.append(title) }
        }
    }
}

// MARK: - Fileprivate Helpers

@MainActor
fileprivate func makeManager(title: String, directory: String? = nil) -> (TabManager, NSWindow) {
    let manager = TabManager(
        initialWorkspaceTitle: title,
        initialWorkingDirectory: directory,
        autoWelcomeIfNeeded: false
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    // AppKit defaults to isReleasedWhenClosed, so close() would release a
    // window ARC still owns.
    window.isReleasedWhenClosed = false
    manager.window = window
    manager.refreshWindowTitle()
    return (manager, window)
}

@MainActor
fileprivate func detach(_ manager: TabManager, _ window: NSWindow) {
    manager.window = nil
    window.close()
}

fileprivate func restoreTemplate(_ previous: Any?, defaults: UserDefaults) {
    if let previous {
        defaults.set(previous, forKey: WindowTitleTemplate.userDefaultsKey)
    } else {
        defaults.removeObject(forKey: WindowTitleTemplate.userDefaultsKey)
    }
}

// MARK: - WindowTitleTemplateTests extension (#cm-104)

extension WindowTitleTemplateTests {
    @MainActor
    @Test func templateDefaultTitleCarriesName() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: WindowTitleTemplate.userDefaultsKey)
        defer { restoreTemplate(previous, defaults: defaults) }

        let (manager, window) = makeManager(title: "Build", directory: "/tmp/old")
        defer { detach(manager, window) }
        manager.windowId = try #require(UUID(uuidString: windowIdString))
        manager.setWindowName("research")

        defaults.set("[cmux:{windowToken}] {defaultTitle}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] research \u{2014} Build")

        // A template without {defaultTitle} shows no window name: same as unnamed.
        defaults.set("[cmux:{windowToken}] {activeDirectory}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.refreshWindowTitle()
        #expect(window.title == "[cmux:01234567] /tmp/old")

        // A name is text: placeholders inside it are never expanded.
        defaults.set("[cmux:{windowToken}] {defaultTitle}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.setWindowName("{windowId}")
        #expect(window.title == "[cmux:01234567] {windowId} \u{2014} Build")
    }

    @MainActor
    @Test func blankActiveWorkspaceFallsBackToUnnamedTitle() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: WindowTitleTemplate.userDefaultsKey)
        defer { restoreTemplate(previous, defaults: defaults) }

        let (manager, window) = makeManager(title: "Build", directory: "/tmp/old")
        defer { detach(manager, window) }
        manager.windowId = try #require(UUID(uuidString: windowIdString))
        manager.setWindowName("research")
        let workspace = try #require(manager.selectedWorkspace)
        workspace.title = "   "

        defaults.set("{activeWorkspace}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.refreshWindowTitle()
        #expect(window.title == "/tmp/old")

        defaults.set("{activeWorkspace} | {defaultTitle}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.refreshWindowTitle()
        #expect(window.title == "/tmp/old | research \u{2014} /tmp/old")

        // A template that resolves to nothing falls back to the NAMED title,
        // the one the window shows with no template. No workspace means no
        // title and no directory, so {activeDirectory} resolves to blank.
        defaults.set("{activeDirectory}", forKey: WindowTitleTemplate.userDefaultsKey)
        manager.updateWindowTitle(for: nil)
        #expect(window.title == "research \u{2014} cmux")
    }
}
