import CmuxControlSocket
import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Opens once, from any thread; `wait()` returns what it was opened with. (A copy of the one in
/// `WorkspaceStatusListStoreTests.swift`, which is private to that file.)
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func open(_ newValue: Bool) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = newValue
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: newValue)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { next in
            lock.lock()
            if let value { lock.unlock(); next.resume(returning: value) } else { continuation = next; lock.unlock() }
        }
    }
}

/// The app's side of the socket (#cm-109.2, step 2e): `TerminalController`'s three status methods and the list method,
/// under an app delegate that holds his list. The delegate gets a store on a temporary file and its own defaults suite,
/// made with `load()`; the app's store is never started. Nothing reads `~/.config/cmux/cmux.json` or `.standard`.
@MainActor
@Suite("Workspace status socket, the app's side", .serialized)
struct WorkspaceStatusSocketTests {
    private typealias A = WorkspaceStatusActionsTests
    private struct NoDefaultsSuite: Error {}
    private struct NotResolved: Error { let text: String }

    private static let hisText = """
    { "workspaceStatuses": [
      { "id": "doing", "name": "Doing", "extends": "working", "color": "#112233" },
      { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" },
      { "id": "done", "name": "Done", "color": "#778899" }
    ] }
    """

    /// Eleven entries and two problems: a twelfth entry with a reserved id, and a color this app lacks.
    private static let elevenText = """
    { "workspaceStatuses": [
      { "id": "inbox", "name": "Inbox", "extends": "todo", "color": "#101010" },
      { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" },
      { "id": "doing", "name": "Doing", "extends": "working", "color": "#112233" },
      { "id": "blocked", "name": "Blocked", "extends": "needs-attention", "color": "Mauve" },
      { "id": "waiting", "name": "Waiting", "extends": "needs-attention" },
      { "id": "review", "name": "Reviewing", "color": "#778800" },
      { "id": "qa", "name": "QA", "extends": "review", "color": "#334455" },
      { "id": "shipped", "name": "Shipped", "extends": "done", "color": "#00AA00" },
      { "id": "done", "name": "Done", "color": "#778899" },
      { "id": "later", "name": "Later", "extends": "todo" },
      { "id": "idea", "name": "Idea", "extends": "todo", "color": "#ABCDEF" },
      { "id": "auto", "name": "Auto", "extends": "todo" }
    ] }
    """

    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    /// Runs `body` with `AppDelegate.shared` holding a store that has loaded `text`.
    private func underList(_ text: String, _ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusSocketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let suite = "WorkspaceStatusSocketTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkspaceStatusListStore(
            fileURL: file,
            defaults: defaults,
            resolveColor: { $0.hasPrefix("#") ? $0.uppercased() : nil },
            paletteFingerprint: { "fixed" },
            clock: ContinuousClock()
        )
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        defer { AppDelegate.shared = previous }
        try body()
    }

    /// Runs `body` with a workspace a `TabManager` holds, registered with the delegate so the socket's methods and the
    /// app's color writer find it, on a customization store of its own.
    private func inATabManager(_ body: (TabManager, Workspace, WorkspaceCustomizationStore) throws -> Void) throws {
        let suite = "WorkspaceStatusSocketTests.customizations.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer { defaults.removePersistentDomain(forName: suite) }
        let customizations = WorkspaceCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations",
            legacyStorageKey: "test.legacy-customizations"
        )
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: customizations)
        let workspace = try #require(manager.selectedWorkspace)
        let delegate = try #require(AppDelegate.shared)
        let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { delegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        try body(manager, workspace, customizations)
    }

    private func read(_ workspace: Workspace) throws -> ControlWorkspaceTodoStatusSnapshot {
        let before = A.held(workspace)
        let resolution = TerminalController.shared.controlWorkspaceTaskStatus(
            routing: routing, workspaceID: workspace.id
        )
        guard case .resolved(_, let status) = resolution else {
            throw NotResolved(text: "the read did not resolve the workspace: \(resolution)")
        }
        #expect(A.held(workspace) == before, "a read changed what the workspace holds")
        return status
    }

    /// Lets the store's second look run: waits (at most 5 s of real time, only ever spent on failure) for it to go to
    /// sleep on the clock, lets one second pass, and waits (the same cap) for the pending task to finish. A store that
    /// scheduled no look, or never let it sleep, fails here with a named issue and cannot hang the run.
    private func letTheSecondLookRun(_ store: WorkspaceStatusListStore, _ clock: SidebarTestManualClock) async -> Bool {
        guard let pending = store.pendingSecondLoad else {
            Issue.record("no second load was scheduled for the file that is gone")
            return false
        }
        let asleep = OneShot()
        Task { await clock.waitUntilSleeping(); asleep.open(true) }
        Task { try? await Task.sleep(for: .seconds(5)); asleep.open(false) }
        guard await asleep.wait() else {
            clock.releasePendingSleepWaitersForTesting()
            Issue.record("the second look never went to sleep on the store's clock")
            return false
        }
        clock.advance(by: .seconds(1))
        let finished = OneShot()
        Task { await pending.value; finished.open(true) }
        Task { try? await Task.sleep(for: .seconds(5)); finished.open(false) }
        guard await finished.wait() else {
            Issue.record("the second look did not finish once one second had passed on the store's clock")
            return false
        }
        return true
    }

    // MARK: - set

    @Test func oneOfHisIdsIsSetAndItsColorIsWritten() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                let resolution = TerminalController.shared.controlSetWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id, statusRaw: "parked"
                )
                guard case .resolved(_, let status) = resolution else {
                    Issue.record("the set did not resolve: \(resolution)")
                    return
                }
                A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "the socket's set parked")
                #expect(workspace.customColor == "#445566", "a script's set wrote no color")
                #expect(status.statusID == "parked")
            }
        }
    }

    @Test func aCmuxStatusHisListLeavesOutIsSetWithNoColor() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.setCustomColor("#ABCDEF")
                let resolution = TerminalController.shared.controlSetWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id, statusRaw: "working"
                )
                guard case .resolved(_, let status) = resolution else {
                    Issue.record("the set did not resolve: \(resolution)")
                    return
                }
                A.expectHolds(workspace, override: .working, own: nil, hidden: false, "the socket's set working")
                #expect(workspace.customColor == "#ABCDEF", "a status the list leaves out wrote a color")
                #expect(status.statusID == "working")
                #expect(status.overrideStatus == "working")
            }
        }
    }

    @Test func anUnknownIDIsRefusedWithHisIDsThenCmuxsLeftOutIDsThenAutoAndNone() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.setOwnStatus(A.hisEntries[1])
                let before = A.held(workspace)
                let colorBefore = workspace.customColor
                let resolution = TerminalController.shared.controlSetWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id, statusRaw: "later"
                )
                guard case .unknownStatus(let raw, let accepted) = resolution else {
                    Issue.record("expected a refusal naming the id, got \(resolution)")
                    return
                }
                #expect(raw == "later")
                #expect(accepted == ["doing", "parked", "done", "todo", "working", "needs-attention", "review", "auto", "none"])
                #expect(A.held(workspace) == before, "a refused set changed what the workspace holds")
                #expect(workspace.customColor == colorBefore, "a refused set wrote a color")
            }
        }
    }

    @Test func autoAndNoneKeepTheirBranches() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.setOwnStatus(A.hisEntries[1])
                _ = TerminalController.shared.controlSetWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id, statusRaw: "none"
                )
                A.expectHolds(workspace, override: nil, own: nil, hidden: true, "the socket's none")
                _ = TerminalController.shared.controlSetWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id, statusRaw: nil
                )
                A.expectHolds(workspace, override: nil, own: nil, hidden: false, "the socket's auto")
            }
        }
    }

    /// The phone's `set` goes through the same coordinator and the same write path, under its own origin: it sets the
    /// status of his and leaves the color, as the phone's cycle does.
    @Test func thePhonesSetHoldsHisStatusAndLeavesTheColor() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.setCustomColor("#ABCDEF")
                let phone = TerminalController.shared.v2MobileTodoDispatch(
                    method: "mobile.status.set",
                    params: ["workspace_id": workspace.id.uuidString, "status": "parked"]
                )
                guard case .ok = phone else {
                    Issue.record("the phone's set was not answered ok: \(phone)")
                    return
                }
                A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "the phone's set parked")
                #expect(workspace.customColor == "#ABCDEF", "the phone's set recolored the workspace")
            }
        }
    }

    // MARK: - get: the seven rows of T2's table

    @Test func nothingHeldAnswersWhatCmuxDetectsAndNoStatusID() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                // A new workspace starts on None; this row is Auto.
                workspace.clearTaskStatusOverride()
                let auto = try read(workspace)
                #expect(auto.effective == auto.inferred)
                #expect(auto.overrideStatus == nil && auto.overrideInferredAt == nil)
                #expect(auto.statusID == nil)
                workspace.hideTaskStatus()
                let none = try read(workspace)
                #expect(none.overrideStatus == nil && none.statusID == nil)
            }
        }
    }

    @Test func aCmuxStatusInEffectIsOverrideAndStatusID() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                for status in [WorkspaceTaskStatus.done, .working] {
                    workspace.setTaskStatusOverride(status)
                    let answer = try read(workspace)
                    #expect(answer.effective == status.rawValue)
                    #expect(answer.overrideStatus == status.rawValue)
                    #expect(answer.overrideInferredAt == answer.inferred)
                    #expect(answer.statusID == status.rawValue)
                }
            }
        }
    }

    /// A cmux status set by hand lapses when detection without states moves away (e.g. PR opened) (11_expected-results.md:98, 19_technical-system.md:432).
    @Test func aLapsedCmuxStatusIsNotInEffectAndStaysStored() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                let panelId = try #require(workspace.focusedPanelId)
                workspace.setTaskStatusOverride(.done)
                workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "feature/pr", isDirty: false)
                workspace.panelPullRequests[panelId] = SidebarPullRequestState(
                    number: 1,
                    label: "PR #1",
                    url: try #require(URL(string: "https://example.com/pr/1")),
                    status: .open,
                    branch: "feature/pr"
                )
                let answer = try read(workspace)
                #expect(answer.effective == "review")
                #expect(answer.overrideStatus == nil && answer.overrideInferredAt == nil)
                #expect(answer.statusID == nil)
                #expect(workspace.todoState.statusOverride?.status == .done, "the read removed the lapsed status")
            }
        }
    }

    /// cmuxFive twin: under cmuxFive with no list, running an agent lapses Done.
    @Test func aLapsedCmuxStatusIsNotInEffectAndStaysStoredUnderCmuxFive() throws {
        try underList("{}") {
            try inATabManager { _, workspace, _ in
                let panelId = try #require(workspace.focusedPanelId)
                workspace.setTaskStatusOverride(.done)
                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
                let answer = try read(workspace)
                #expect(answer.effective == "working")
                #expect(answer.overrideStatus == nil && answer.overrideInferredAt == nil)
                #expect(answer.statusID == nil)
                #expect(workspace.todoState.statusOverride?.status == .done)
            }
        }
    }

    @Test func oneOfHisOwnInEffectAnswersTheStatusItExtends() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.setOwnStatus(A.hisEntries[0])
                let answer = try read(workspace)
                #expect(answer.effective == "working")
                #expect(answer.overrideStatus == "working")
                #expect(answer.overrideInferredAt == answer.inferred)
                #expect(answer.statusID == "doing")
            }
        }
    }

    /// With his list, detection without states in a wait is .todo, so doing (which extends working) stays in effect (19_technical-system.md:435).
    @Test func oneOfHisOwnWhileAnAgentWaitsStaysInEffect() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                let panelId = try #require(workspace.focusedPanelId)
                workspace.setOwnStatus(A.hisEntries[0])
                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
                let answer = try read(workspace)
                #expect(answer.effective == "working")
                #expect(answer.overrideStatus == "working")
                #expect(answer.overrideInferredAt == "todo")
                #expect(answer.statusID == "doing")
            }
        }
    }

    /// One of his own picked during a wait is in effect, and overrideInferredAt reports detection without states (.todo) (19_technical-system.md:435).
    @Test func oneOfHisOwnPickedDuringAWaitIsInEffectInThatWait() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                let panelId = try #require(workspace.focusedPanelId)
                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
                workspace.setOwnStatus(A.hisEntries[1])
                let answer = try read(workspace)
                #expect(answer.effective == "todo")
                #expect(answer.overrideStatus == "todo")
                #expect(answer.overrideInferredAt == "todo")
                #expect(answer.statusID == "parked")
            }
        }
    }


    @Test func oneOfHisOwnThatTheListLacksIsHeldAndNotInEffect() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                // A new `Workspace` starts with None on; this row is a held id with None off.
                workspace.todoState.statusHidden = false
                workspace.todoState.ownStatus = WorkspaceOwnStatus(id: "gone")
                let answer = try read(workspace)
                #expect(answer.effective == answer.inferred)
                #expect(answer.overrideStatus == nil && answer.overrideInferredAt == nil)
                #expect(answer.statusID == "gone")

                // The same id with None on is not reported.
                workspace.todoState.statusHidden = true
                #expect(try read(workspace).statusID == nil)
            }
        }
    }

    /// A restored session can hold None and his id at once (Decisions, 2026-10-12, point 14). `status_id` is `null`
    /// under None, also with a status held (answer 5 of the main session, 2026-10-13).
    @Test func noneAnswersNoStatusIDEvenWhileAStatusOfHisIsHeld() throws {
        try underList(Self.hisText) {
            try inATabManager { _, workspace, _ in
                workspace.todoState.ownStatus = WorkspaceOwnStatus(id: "doing")
                workspace.todoState.statusHidden = true
                let answer = try read(workspace)
                #expect(answer.statusID == nil, "None answered a status id: \(String(describing: answer.statusID))")
            }
        }
    }

    // MARK: - list

    @Test func theListAnswersHisElevenInOrderWithTheirColors() throws {
        try underList(Self.elevenText) {
            let list = TerminalController.shared.controlWorkspaceStatusList()
            #expect(list.source == .file)
            #expect(list.statuses.map(\.id) == [
                "inbox", "parked", "doing", "blocked", "waiting", "review", "qa", "shipped", "done", "later", "idea",
            ])
            #expect(list.statuses.map(\.name) == [
                "Inbox", "Parked", "Doing", "Blocked", "Waiting", "Reviewing", "QA", "Shipped", "Done", "Later", "Idea",
            ])
            // One of cmux's five has no `extends`, whatever his entry held.
            #expect(list.statuses.map(\.extends) == [
                "todo", "todo", "working", "needs-attention", "needs-attention", nil, "review", "done", nil, "todo", "todo",
            ])
            #expect(list.statuses.map(\.colorHex) == [
                "#101010", "#445566", "#112233", nil, nil, "#778800", "#334455", "#00AA00", "#778899", nil, "#ABCDEF",
            ])
            #expect(list.statuses[3].color == "Mauve")
            #expect(list.statuses[4].color == nil)
        }
    }

    @Test func theListAnswersAProblemsFieldsInTheOrderThePillShowsThem() throws {
        try underList(Self.elevenText) {
            let list = TerminalController.shared.controlWorkspaceStatusList()
            #expect(list.problems == [
                .init(code: "reserved_id", entry: 12, id: "auto", value: nil),
                .init(code: "color_not_in_this_app", entry: nil, id: "blocked", value: "Mauve"),
            ])
        }
    }

    @Test func theListWithCmuxsFiveHasNoNamesAndNoExtends() throws {
        let previous = AppDelegate.shared
        defer { AppDelegate.shared = previous }
        AppDelegate.shared = AppDelegate()
        let list = TerminalController.shared.controlWorkspaceStatusList()
        #expect(list.source == .cmux)
        #expect(list.statuses.map(\.id) == ["todo", "working", "needs-attention", "review", "done"])
        #expect(list.statuses.allSatisfy { $0.name == nil && $0.extends == nil && $0.color == nil })
        #expect(list.problems.isEmpty)
    }

    @Test func theListSaysWhetherTheControlsAreOn() throws {
        try underList(Self.hisText) {
            // The host's gate is a beta setting, off by default; the true side is the package's test of the answer.
            try #require(!WorkspaceTodoFeature.isEnabled, "this test needs the status controls off in the test host")
            let list = TerminalController.shared.controlWorkspaceStatusList()
            #expect(list.controlsEnabled == false)
        }
    }

    /// The file that was not read: `value` carries the reader's detail, `null` when it is empty, and `missing` shows
    /// only through the sentence. An unreadable file with cmux's five in use reports nothing at once and keeps no
    /// problem (the store's rulings), so each half starts from a file that loads his list: the unreadable file is
    /// reported at once, the missing one after the store's second look, one second later on the store's clock.
    @Test func aFileNotReadShowsItsDetailAsTheValue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusSocketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "WorkspaceStatusSocketTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = directory.appendingPathComponent("cmux.json")
        let clock = SidebarTestManualClock()
        let store = WorkspaceStatusListStore(
            fileURL: file, defaults: defaults, resolveColor: { $0.hasPrefix("#") ? $0.uppercased() : nil },
            paletteFingerprint: { "fixed" }, clock: clock
        )
        let previous = AppDelegate.shared
        defer { AppDelegate.shared = previous }
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate

        try Self.hisText.write(to: file, atomically: true, encoding: .utf8)
        store.load()
        #expect(TerminalController.shared.controlWorkspaceStatusList().problems.isEmpty)

        // A file that does not parse, with his list in use: reported at once, with the reader's detail.
        try "{ \"workspaceStatuses\": ".write(to: file, atomically: true, encoding: .utf8)
        store.load()
        let unreadable = try #require(
            TerminalController.shared.controlWorkspaceStatusList().problems.first(where: { $0.code == "file_not_read" }),
            "the file with a typo was not reported"
        )
        #expect(unreadable.code == "file_not_read")
        #expect(unreadable.fileMissing == false)
        #expect(unreadable.value?.isEmpty == false, "the reader's detail did not reach the value")

        // A file that is gone: nothing at once, then the problem after the second look.
        try FileManager.default.removeItem(at: file)
        store.load()
        #expect(
            TerminalController.shared.controlWorkspaceStatusList().problems.first(where: { $0.fileMissing }) == nil,
            "a missing file was reported before the second look"
        )
        guard await letTheSecondLookRun(store, clock) else { return }
        let missing = try #require(
            TerminalController.shared.controlWorkspaceStatusList().problems.first(where: { $0.code == "file_not_read" }),
            "the missing file was not reported after the store's second look"
        )
        #expect(missing.code == "file_not_read")
        #expect(missing.fileMissing == true)
        #expect(missing.value == nil, "a missing file gave a value: \(String(describing: missing.value))")
    }
}
