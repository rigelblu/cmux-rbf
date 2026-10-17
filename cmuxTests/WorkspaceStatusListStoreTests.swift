import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// A defaults suite that counts what is written and removed under each key. `@unchecked Sendable` is safe because
/// the arrays are only touched from the main actor: the store and every test run there, and nothing hands the suite
/// to another thread.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var writes: [String] = []
    var removals: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        removals.append(defaultName)
        super.removeObject(forKey: defaultName)
    }
}

/// Opens once, from any thread; `wait()` returns what it was opened with.
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

/// What the store's two color closures see and say. Every call comes from the main actor.
private final class Probe: @unchecked Sendable {
    var resolveCalls = 0
    var fingerprint = "palette-1"
    /// A color that begins with `x` names nothing in this app.
    var resolves: (String) -> Bool = { !$0.hasPrefix("x") }

    /// The hex this probe answers for a color: it carries the color, so a store that gives one entry another
    /// entry's hex shows.
    static func hex(for color: String) -> String { "hex<\(color)>" }

    /// Runs inside every `resolve`, to stand for a default written while the colors are being worked out.
    var whileResolving: (() -> Void)?

    func resolve(_ color: String) -> String? {
        resolveCalls += 1
        whileResolving?()
        return resolves(color) ? Self.hex(for: color) : nil
    }
}

private struct NoDefaultsSuite: Error {}

/// A temporary file and its own defaults suite, both removed by `cleanUp()`.
@MainActor
private final class StoreRig {
    let directory: URL
    let fileURL: URL
    let suiteName: String
    let defaults: CountingDefaults
    let clock = SidebarTestManualClock()
    let probe = Probe()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusListStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cmux.json")
        suiteName = "WorkspaceStatusListStoreTests.\(UUID().uuidString)"
        // No fallback: an instance made without a suite is the test host's own defaults.
        guard let made = CountingDefaults(suiteName: suiteName) else { throw NoDefaultsSuite() }
        defaults = made
    }

    func makeStore() -> WorkspaceStatusListStore {
        let probe = self.probe
        return WorkspaceStatusListStore(
            fileURL: fileURL,
            defaults: defaults,
            resolveColor: { probe.resolve($0) },
            paletteFingerprint: { probe.fingerprint },
            clock: clock
        )
    }

    func write(_ text: String) {
        writeData(Data(text.utf8))
    }

    func writeData(_ data: Data) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try? data.write(to: fileURL, options: .atomic)
    }

    var fileBytes: Data? { FileManager.default.contents(atPath: fileURL.path) }

    func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var storedCopy: Data? { defaults.data(forKey: WorkspaceStatusListStore.storedCopyKey) }
    var copyWrites: Int { defaults.writes.filter { $0 == WorkspaceStatusListStore.storedCopyKey }.count }
    var copyRemovals: Int { defaults.removals.filter { $0 == WorkspaceStatusListStore.storedCopyKey }.count }

    /// Lets main-actor tasks that are already due run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// The one place a test waits for the store's second look to go to sleep on the clock. A store that breaks the
    /// rule may never schedule a look, or never let it sleep, and a plain `waitUntilSleeping()` would then wait for
    /// ever and hang the run. This returns `false` and records a named issue in both cases. The 5 s real-time cap
    /// is only ever spent on that failure path: a store that works registers its sleeper at once.
    func waitForTheSecondLookToSleep(_ store: WorkspaceStatusListStore) async -> Bool {
        guard store.pendingSecondLoad != nil else {
            Issue.record("no second load was scheduled for the file that could not be read")
            return false
        }
        let clock = self.clock
        let gate = OneShot()
        Task { await clock.waitUntilSleeping(); gate.open(true) }
        Task {
            try? await Task.sleep(for: .seconds(5))
            gate.open(false)
        }
        guard await gate.wait() else {
            clock.releasePendingSleepWaitersForTesting()
            Issue.record("the second look never went to sleep on the store's clock")
            return false
        }
        return true
    }

    /// Lets one second pass on the store's clock, in two steps, and checks the second look ran at the second step and
    /// not before. A store that waits another length, schedules no look or never lets it sleep fails here and does
    /// not hang the run.
    func letTheSecondLoadRun(_ store: WorkspaceStatusListStore) async {
        let before = store.problems
        guard await waitForTheSecondLookToSleep(store) else { return }
        clock.advance(by: .milliseconds(999))
        await settle()
        #expect(store.pendingSecondLoad != nil, "the second look ran before one second had passed")
        #expect(store.problems == before, "the second look reported before one second had passed")
        clock.advance(by: .milliseconds(1))
        await settle()
        #expect(store.pendingSecondLoad == nil, "the second look did not run once one second had passed")
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// The status list store reading a temporary `cmux.json` (#cm-109.2). None of these touches the user's file or
/// `UserDefaults.standard`, and none starts the store: its watcher loops are not covered here.
@MainActor
@Suite("Workspace status list store", .serialized)
struct WorkspaceStatusListStoreTests {
    private typealias Entry = WorkspaceStatusEntry
    private typealias Problem = WorkspaceStatusListProblem

    private static let hisText = """
    {
      // his list, with a comment the stripper takes out
      "workspaceStatuses": [
        { "id": "dogfood", "name": "Dogfood", "extends": "review", "color": "2: DOGFOOD" },
        { "id": "done",    "name": "Done",                         "color": "1: DONE" },
        { "id": "parked",  "name": "Parked",  "extends": "todo",   "color": "5: PARKED" }
      ]
    }
    """
    private let hisEntries = [
        Entry(id: "dogfood", name: "Dogfood", extends: .review, color: "2: DOGFOOD"),
        Entry(id: "done", name: "Done", color: "1: DONE"),
        Entry(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED"),
    ]
    private static let otherText = """
    { "workspaceStatuses": [ { "id": "next", "name": "Next", "extends": "todo", "color": "4: NEXT" } ] }
    """
    private let otherEntries = [Entry(id: "next", name: "Next", extends: .todo, color: "4: NEXT")]

    // MARK: - Nothing loaded

    @Test func makingTheStoreReadsNothingAndWritesNothing() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        #expect(store.list == .cmuxFive)
        #expect(store.list.source == .cmux)
        #expect(store.problems.isEmpty)
        #expect(store.revision == 0)
        #expect(rig.probe.resolveCalls == 0)
        #expect(rig.defaults.writes.isEmpty)
        #expect(rig.storedCopy == nil)
    }

    /// An app that never loaded a list: a missing file reports nothing and schedules nothing.
    @Test func anAppThatNeverLoadedAListHasCmuxsFiveAndNothingToTellHim() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.load()
        #expect(store.list == .cmuxFive)
        #expect(store.problems.isEmpty)
        #expect(store.pendingSecondLoad == nil)
        #expect(rig.storedCopy == nil)
    }

    // MARK: - A load that worked

    @Test func aLoadThatWorkedPutsHisListInUseKeepsACopyAndResolvesHisColors() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        #expect(store.list == WorkspaceStatusList(entries: hisEntries, source: .file))
        #expect(store.problems.isEmpty)
        #expect(store.colorHexes == [
            "dogfood": Probe.hex(for: "2: DOGFOOD"), "done": Probe.hex(for: "1: DONE"), "parked": Probe.hex(for: "5: PARKED"),
        ])
        #expect(store.revision == 1)
        #expect(rig.storedCopy != nil)
        #expect(rig.copyWrites == 1)
    }

    @Test func aRestartReadsTheStoredCopyWhenTheFileIsBroken() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        rig.makeStore().load()
        rig.write("{ \"workspaceStatuses\": [ ")
        let restarted = rig.makeStore()
        restarted.load()
        #expect(restarted.list == WorkspaceStatusList(entries: hisEntries, source: .stored))
        #expect(restarted.problems.count == 1)
        guard case .fileNotRead(let missing, let detail)? = restarted.problems.first else {
            Issue.record("expected a file problem, got \(restarted.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
    }

    // MARK: - A load that did not work

    @Test func aBrokenFileKeepsTheListAndTheCopyAndShowsOneProblemAtOnce() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        let copy = rig.storedCopy
        rig.write("{ \"workspaceStatuses\": [ { \"id\": ")
        store.load()
        #expect(store.list == WorkspaceStatusList(entries: hisEntries, source: .file))
        #expect(rig.storedCopy == copy)
        #expect(rig.copyRemovals == 0)
        guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
            Issue.record("expected a file problem, got \(store.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
        #expect(store.problems.count == 1)
    }

    @Test func aMissingFileKeepsTheListAndTheCopyAndSaysNothingUntilTheSecondLoadFindsItMissingToo() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        let copy = rig.storedCopy
        rig.removeFile()
        store.load()
        #expect(store.list.entries == hisEntries)
        #expect(store.problems.isEmpty)
        #expect(store.pendingSecondLoad != nil)
        await rig.letTheSecondLoadRun(store)
        #expect(store.list.entries == hisEntries)
        #expect(store.problems == [.fileNotRead(missing: true, detail: "")])
        #expect(rig.storedCopy == copy)
        #expect(rig.copyRemovals == 0)
    }

    @Test func anUnreadableFileDoesTheSame() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.fileURL.path)
        store.load()
        #expect(store.problems.isEmpty)
        #expect(store.pendingSecondLoad != nil)
        await rig.letTheSecondLoadRun(store)
        #expect(store.list.entries == hisEntries)
        #expect(store.problems == [.fileNotRead(missing: false, detail: "")])
        #expect(rig.copyRemovals == 0)
    }

    @Test func anEmptyFileOfZeroBytesDoesTheSame() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.write("")
        store.load()
        #expect(store.problems.isEmpty)
        await rig.letTheSecondLoadRun(store)
        #expect(store.list.entries == hisEntries)
        #expect(store.problems == [.fileNotRead(missing: false, detail: "")])
    }

    /// A file of only spaces or comments is not empty: it does not parse, and shows at once.
    @Test func aFileOfOnlyACommentDoesNotParseAndShowsAtOnce() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("// nothing here yet\n")
        let store = rig.makeStore()
        store.load()
        #expect(store.list == .cmuxFive)
        guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
            Issue.record("expected a file problem, got \(store.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
        #expect(store.pendingSecondLoad == nil)
    }

    @Test func aTopLevelThatIsNotAnObjectIsTheFixedSentence() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("[ 1, 2 ]")
        let store = rig.makeStore()
        store.load()
        #expect(store.problems == [.fileNotRead(missing: false, detail: "The top level is not an object.")])
        for text in ["5", "\"text\"", "null", "true"] {
            rig.write(text)
            store.load()
            #expect(
                store.problems == [.fileNotRead(missing: false, detail: "The top level is not an object.")], "\(text)"
            )
        }
    }

    /// `JSONSerialization` names a position, but only the mistake in a file with no block comment is where it says.
    @Test func aBrokenFileGivesFoundationsPositionUnlessItHasABlockComment() throws {
        let mistake = "{ \"workspaceStatuses\": [ { \"id\": "
        let cases: [(text: String, hasDetail: Bool)] = [
            (mistake, true),
            ("// a note\n// another\n" + mistake, true),
            ("/* a note\nover two lines */\n" + mistake, false),
            ("{ /* inline */ \"workspaceStatuses\": [ { \"id\": ", false),
            // The rule is the text containing `/*` anywhere, a string value included.
            ("{ \"note\": \"**/*.md\", \"workspaceStatuses\": [ { \"id\": ", false),
        ]
        for (text, hasDetail) in cases {
            let rig = try StoreRig()
            defer { rig.cleanUp() }
            rig.write(text)
            let store = rig.makeStore()
            store.load()
            guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
                Issue.record("expected a file problem, got \(store.problems)")
                continue
            }
            #expect(!missing, "\(text)")
            #expect(detail.isEmpty != hasDetail, "\(text) gave \(detail)")
            if !hasDetail { #expect(store.problems == [.fileNotRead(missing: false, detail: "")], "\(text)") }
        }
    }

    @Test func aCommentThatNeverEndsIsAFileProblemWithAnErrorDetail() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("{ /* never closed \n \"workspaceStatuses\": [] }")
        let store = rig.makeStore()
        store.load()
        guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
            Issue.record("expected a file problem, got \(store.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
    }

    /// A file missing at one read and back at the second load: the second load is an ordinary load, and nothing
    /// was ever reported.
    @Test func aFileMissingForAnInstantReportsNothing() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.removeFile()
        store.load()
        #expect(store.problems.isEmpty)
        rig.write(Self.otherText)
        await rig.letTheSecondLoadRun(store)
        #expect(store.list == WorkspaceStatusList(entries: otherEntries, source: .file))
        #expect(store.problems.isEmpty)
    }

    /// A file written again with a typo inside the second look gets the typo's line, not a line saying it is missing.
    @Test func aTypoInTheSecondLoadIsTheTyposLine() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.removeFile()
        store.load()
        rig.write("{ \"workspaceStatuses\": [ ")
        await rig.letTheSecondLoadRun(store)
        guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
            Issue.record("expected a file problem, got \(store.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
        #expect(store.list.entries == hisEntries)
    }

    @Test func aNewLoadTakesThePlaceOfASecondLookThatIsStillWaiting() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.removeFile()
        store.load()
        guard await rig.waitForTheSecondLookToSleep(store) else { return }
        let waiting = store.pendingSecondLoad
        rig.write(Self.otherText)
        store.load()
        #expect(store.pendingSecondLoad == nil)
        #expect(waiting?.isCancelled == true)
        #expect(store.list.entries == otherEntries)
        // The file goes again, and a second look that had not been replaced would find it missing.
        rig.removeFile()
        rig.clock.advance(by: .seconds(2))
        await rig.settle()
        #expect(store.problems.isEmpty, "a replaced second look still reported")
        #expect(store.list.entries == otherEntries)
    }

    // MARK: - The key

    /// The file parses and the key is misspelt or gone: his list is taken out, with its copy.
    @Test func aFileThatParsesWithoutTheKeyRemovesTheCopyAndPutsCmuxsFiveInUse() throws {
        for text in ["{ \"workspaceStatus\": [] }", "{}"] {
            let rig = try StoreRig()
            defer { rig.cleanUp() }
            rig.write(Self.hisText)
            let store = rig.makeStore()
            store.load()
            #expect(rig.storedCopy != nil)
            rig.write(text)
            store.load()
            #expect(store.list == .cmuxFive, "\(text)")
            #expect(store.problems.isEmpty, "\(text)")
            #expect(store.colorHexes.isEmpty, "\(text)")
            #expect(rig.storedCopy == nil, "\(text)")
        }
    }

    /// A key that holds an object and not a list is a load that did not work: the list and the copy stay.
    @Test func aKeyThatIsNotAListKeepsTheListAndTheCopyAndSaysNotAList() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        let copy = rig.storedCopy
        rig.write("{ \"workspaceStatuses\": { \"id\": \"x\" } }")
        store.load()
        #expect(store.list.entries == hisEntries)
        #expect(store.problems == [.notAList])
        #expect(rig.storedCopy == copy)
        #expect(rig.copyRemovals == 0)
    }

    @Test func aParserProblemIsKeptBesideTheEntriesThatPass() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("""
        { "workspaceStatuses": [ { "id": "a", "name": "A" }, { "id": "b", "name": "B", "extends": "todo" } ] }
        """)
        let store = rig.makeStore()
        store.load()
        #expect(store.list.entries == [Entry(id: "b", name: "B", extends: .todo)])
        #expect(store.problems == [.noExtends(entry: 1, id: "a")])
    }

    // MARK: - The stored copy

    @Test func theStoredCopyIsNotWrittenWhenTheListIsUnchanged() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        store.load()
        store.load()
        #expect(rig.copyWrites == 1)
        rig.write(Self.otherText)
        store.load()
        #expect(rig.copyWrites == 2)
    }

    @Test func aBrokenFileNeverRemovesTheCopy() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        for broken in ["", "{", "[]", "{ \"workspaceStatuses\": 3 }", "// c"] {
            rig.write(broken)
            store.load()
        }
        rig.removeFile()
        store.load()
        #expect(rig.copyRemovals == 0)
        #expect(rig.storedCopy != nil)
    }

    /// A copy that is not a list counts as no copy, and is left where it is by a load that did not work.
    @Test func aStoredCopyThatIsNotAListIsNoCopyAndIsLeftInPlace() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        let bad = Data(#"{"id":"x","name":"X"}"#.utf8)
        rig.defaults.set(bad, forKey: WorkspaceStatusListStore.storedCopyKey)
        rig.write("{ \"workspaceStatuses\": [ ")
        let store = rig.makeStore()
        store.load()
        #expect(store.list == .cmuxFive)
        #expect(rig.storedCopy == bad)
    }

    /// A copy that gives a problem is not drawn either, not even the entries of it that pass.
    @Test func aStoredCopyThatGivesAProblemIsNoCopyAndIsLeftInPlace() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        let bad = Data(#"[{"id":"a","name":"A","extends":"todo"},{"id":"x"}]"#.utf8)
        rig.defaults.set(bad, forKey: WorkspaceStatusListStore.storedCopyKey)
        rig.write("{ \"workspaceStatuses\": [ ")
        let store = rig.makeStore()
        store.load()
        #expect(store.list == .cmuxFive)
        #expect(rig.storedCopy == bad)
    }

    /// The next load that works replaces a bad copy.
    @Test func aLoadThatWorksReplacesABadCopy() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.defaults.set(Data("[1]".utf8), forKey: WorkspaceStatusListStore.storedCopyKey)
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        let again = rig.makeStore()
        rig.write("{")
        again.load()
        #expect(again.list == WorkspaceStatusList(entries: hisEntries, source: .stored))
    }

    /// cm-109.3: the stored copy keeps `icon` the way it keeps `color`, and an icon the parser did not know is written
    /// as no icon: the store refuses a copy that reads back with a problem, so the typed text must never reach it.
    @Test func theStoredCopyKeepsTheIconsTheParserFoundAndNeverATypedBadOne() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("""
        { "workspaceStatuses": [
          { "id": "done", "name": "Done", "icon": "check", "color": "1: DONE" },
          { "id": "paused", "name": "Paused", "extends": "todo", "icon": "ring" },
          { "id": "odd", "name": "Odd", "extends": "working", "icon": "bogus" }
        ] }
        """)
        let store = rig.makeStore()
        store.load()
        let expected = [
            Entry(id: "done", name: "Done", color: "1: DONE", icon: .check),
            Entry(id: "paused", name: "Paused", extends: .todo, icon: .ring),
            Entry(id: "odd", name: "Odd", extends: .working),
        ]
        #expect(store.list == WorkspaceStatusList(entries: expected, source: .file))
        #expect(store.problems == [.unknownIcon(entry: 3, id: "odd", value: "bogus")])
        let copy = try #require(rig.storedCopy)
        let written = try #require(try JSONSerialization.jsonObject(with: copy) as? [[String: Any]])
        #expect(written.map { $0["icon"] as? String } == ["check", "ring", nil])

        let restarted = rig.makeStore()
        rig.write("{")
        restarted.load()
        #expect(restarted.list == WorkspaceStatusList(entries: expected, source: .stored))
        #expect(!restarted.problems.contains { $0.code == "unknown_icon" })
    }

    // MARK: - Reviewed: a problem goes when its cause goes

    /// Nothing but cmux's five in use and the file gone: the problem of the broken file goes with it.
    @Test func aProblemGoesWhenTheFileIsGoneAndCmuxsFiveAreInUse() throws {
        for broken in ["{", "{ \"workspaceStatuses\": 3 }"] {
            for emptied in [false, true] {
                let rig = try StoreRig()
                defer { rig.cleanUp() }
                rig.write(broken)
                let store = rig.makeStore()
                store.load()
                #expect(store.problems.count == 1, "\(broken)")
                if emptied { rig.write("") } else { rig.removeFile() }
                store.load()
                #expect(store.list == .cmuxFive, "\(broken) \(emptied)")
                #expect(store.problems.isEmpty, "\(broken) \(emptied): \(store.problems)")
                #expect(store.pendingSecondLoad == nil, "\(broken) \(emptied)")
            }
        }
    }

    @Test func aProblemGoesWhenTheFileIsFixed() throws {
        for fixed in [Self.hisText, "{}"] {
            let rig = try StoreRig()
            defer { rig.cleanUp() }
            rig.write("{")
            let store = rig.makeStore()
            store.load()
            #expect(store.problems.count == 1)
            rig.write(fixed)
            store.load()
            #expect(store.problems.isEmpty, "\(fixed): \(store.problems)")
        }
    }

    /// The template file has no key: a save of it removes a copy that is not there, and so writes no default.
    @Test func aFileWithNoKeyLoadedThreeTimesRemovesNothingWhenThereIsNoCopy() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("{}")
        let store = rig.makeStore()
        store.load()
        store.load()
        store.load()
        #expect(rig.copyRemovals == 0)
        #expect(rig.defaults.removals.isEmpty)
        #expect(store.list == .cmuxFive)
    }

    /// A second look that was replaced after its sleep ended, before it ran, does not run.
    @Test func aSecondLookReplacedAfterItsSleepEndedDoesNotRun() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.removeFile()
        store.load()
        guard await rig.waitForTheSecondLookToSleep(store) else { return }
        // The look's sleep ends; the look resumes on the main actor only when this test next suspends.
        rig.clock.advance(by: .seconds(1))
        store.load()
        await rig.settle()
        #expect(store.problems.isEmpty, "the replaced look reported at once: \(store.problems)")
        await rig.letTheSecondLoadRun(store)
        #expect(store.problems == [.fileNotRead(missing: true, detail: "")])
    }

    // MARK: - Reviewed: restart, the copy's name and format

    /// A restart with a stored copy and no file: the copy's list stays, nothing is told until the second look.
    @Test func aRestartWithACopyAndNoFileKeepsTheCopyAndSaysNothingUntilTheSecondLook() async throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        rig.makeStore().load()
        rig.removeFile()
        let restarted = rig.makeStore()
        restarted.load()
        #expect(restarted.list == WorkspaceStatusList(entries: hisEntries, source: .stored))
        #expect(restarted.problems.isEmpty)
        #expect(restarted.pendingSecondLoad != nil)
        await rig.letTheSecondLoadRun(restarted)
        #expect(restarted.list.source == .stored)
        #expect(restarted.problems == [.fileNotRead(missing: true, detail: "")])
        #expect(rig.copyRemovals == 0)
    }

    /// The design's launch test: a second store on the same defaults, handed a file with no key.
    @Test func aSecondStoreOnTheSameDefaultsRemovesTheCopyForAFileWithNoKey() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        rig.makeStore().load()
        #expect(rig.storedCopy != nil)
        rig.write("{}")
        let second = rig.makeStore()
        second.load()
        #expect(rig.storedCopy == nil)
        #expect(rig.copyRemovals == 1)
        #expect(second.list == .cmuxFive)
        #expect(second.problems.isEmpty)
    }

    @Test func theCopysKeyIsFixedText() {
        #expect(WorkspaceStatusListStore.storedCopyKey == "workspaceStatuses.lastListThatWorked.v1")
    }

    /// A copy written here as literal JSON, not through the store, is read as the list.
    @Test func aCopyWrittenByHandIsReadAsTheList() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        let json = #"[{"id":"a","name":"A","extends":"todo","color":"1: A"},{"id":"b","name":"B","extends":"done"}]"#
        rig.defaults.set(Data(json.utf8), forKey: "workspaceStatuses.lastListThatWorked.v1")
        rig.write("{")
        let store = rig.makeStore()
        store.load()
        #expect(store.list == WorkspaceStatusList(
            entries: [Entry(id: "a", name: "A", extends: .todo, color: "1: A"), Entry(id: "b", name: "B", extends: .done)],
            source: .stored
        ))
    }

    // MARK: - Reviewed: more through the store

    @Test func anEmptyListIsAListAndNotCmuxsFiveAfterARestartToo() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("{ \"workspaceStatuses\": [] }")
        let store = rig.makeStore()
        store.load()
        #expect(store.list == WorkspaceStatusList(entries: [], source: .file))
        #expect(store.problems.isEmpty)
        #expect(rig.copyWrites == 1)
        rig.write("{")
        let restarted = rig.makeStore()
        restarted.load()
        #expect(restarted.list == WorkspaceStatusList(entries: [], source: .stored))
    }

    /// A file of only spaces is not empty: it does not parse, and shows at once.
    @Test func aFileOfOnlySpacesDoesNotParseAndShowsAtOnce() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("   \n  ")
        let store = rig.makeStore()
        store.load()
        guard case .fileNotRead(let missing, let detail)? = store.problems.first else {
            Issue.record("expected a file problem, got \(store.problems)")
            return
        }
        #expect(!missing)
        #expect(!detail.isEmpty)
        #expect(store.pendingSecondLoad == nil)
    }

    @Test func nullUnderTheKeyIsNotAListAndKeepsTheListAndTheCopy() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        let copy = rig.storedCopy
        rig.write("{ \"workspaceStatuses\": null }")
        store.load()
        #expect(store.list.entries == hisEntries)
        #expect(store.problems == [.notAList])
        #expect(rig.storedCopy == copy)
        #expect(rig.copyRemovals == 0)
    }

    /// A list from the stored copy, then a good load: the list is from the file again, and the copy is not rewritten.
    @Test func aGoodLoadAfterAListFromTheCopyIsFromTheFileAndWritesNoSecondCopy() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        rig.makeStore().load()
        #expect(rig.copyWrites == 1)
        rig.write("{")
        let restarted = rig.makeStore()
        restarted.load()
        #expect(restarted.list.source == .stored)
        rig.write(Self.hisText)
        restarted.load()
        #expect(restarted.list == WorkspaceStatusList(entries: hisEntries, source: .file))
        #expect(restarted.problems.isEmpty)
        #expect(rig.copyWrites == 1)
    }

    /// The store reads the file and never writes it.
    @Test func aLoadLeavesTheFilesBytesAlone() throws {
        for text in [Self.hisText, "{", "{}", "[1]", "{ \"workspaceStatuses\": 3 }"] {
            let rig = try StoreRig()
            defer { rig.cleanUp() }
            rig.write(text)
            let before = rig.fileBytes
            let store = rig.makeStore()
            store.load()
            store.load()
            #expect(before != nil)
            #expect(rig.fileBytes == before, "\(text)")
        }
    }

    /// A file that is not UTF-8 gives no position: the search for `/*` cannot be trusted on its bytes.
    @Test func aFileThatIsNotUTF8GivesNoPosition() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        let data = try #require("{ \"workspaceStatuses\": [ { \"id\": ".data(using: .utf16))
        rig.writeData(data)
        let store = rig.makeStore()
        store.load()
        #expect(store.problems == [.fileNotRead(missing: false, detail: "")])
    }

    // MARK: - Colors and the number

    @Test func eachColorIsResolvedOncePerEntryThatHasOneOnEveryLoad() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("""
        { "workspaceStatuses": [
          { "id": "a", "name": "A", "extends": "todo", "color": "1: A" },
          { "id": "b", "name": "B", "extends": "todo" },
          { "id": "c", "name": "C", "extends": "todo", "color": "3: C" }
        ] }
        """)
        let store = rig.makeStore()
        store.load()
        #expect(rig.probe.resolveCalls == 2)
        #expect(store.colorHexes == ["a": Probe.hex(for: "1: A"), "c": Probe.hex(for: "3: C")])
        store.load()
        #expect(rig.probe.resolveCalls == 4)
    }

    @Test func aColorThisAppCannotResolveIsAProblemAfterWhatTheLoadFound() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("""
        { "workspaceStatuses": [
          { "id": "a", "name": "A", "extends": "todo", "color": "x1" },
          { "id": "b", "name": "B" },
          { "id": "c", "name": "C", "extends": "todo", "color": "x3" },
          { "id": "d", "name": "D", "extends": "todo" }
        ] }
        """)
        let store = rig.makeStore()
        store.load()
        // `b` has no `extends`, so the parser drops it; `d` stays in the list with no color and so is never resolved.
        #expect(store.problems == [
            .noExtends(entry: 2, id: "b"),
            .colorNotInThisApp(id: "a", color: "x1"),
            .colorNotInThisApp(id: "c", color: "x3"),
        ])
        #expect(store.colorHexes.isEmpty)
    }

    /// After a file that was not read the kept list's color problems still follow, because they are still true.
    @Test func theKeptListsColorProblemsFollowTheFileProblem() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write("""
        { "workspaceStatuses": [ { "id": "a", "name": "A", "extends": "todo", "color": "x1" } ] }
        """)
        let store = rig.makeStore()
        store.load()
        rig.write("{ \"workspaceStatuses\": 3 }")
        store.load()
        #expect(store.problems == [.notAList, .colorNotInThisApp(id: "a", color: "x1")])
        rig.write("{")
        store.load()
        #expect(store.problems.count == 2)
        #expect(store.problems.last == .colorNotInThisApp(id: "a", color: "x1"))
    }

    @Test func theColorsAreWorkedOutAgainWhenThePaletteChangesAndNotOtherwise() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        #expect(rig.probe.resolveCalls == 3)
        // The notice fires for any key, and the fingerprint has not moved.
        store.paletteMayHaveChanged()
        store.paletteMayHaveChanged()
        #expect(rig.probe.resolveCalls == 3)
        #expect(store.revision == 1)
        // A label was renamed: the fingerprint moves and the answer for one color changes.
        rig.probe.fingerprint = "palette-2"
        rig.probe.resolves = { $0 != "5: PARKED" }
        store.paletteMayHaveChanged()
        #expect(rig.probe.resolveCalls == 6)
        #expect(store.problems == [.colorNotInThisApp(id: "parked", color: "5: PARKED")])
        #expect(store.colorHexes == ["dogfood": Probe.hex(for: "2: DOGFOOD"), "done": Probe.hex(for: "1: DONE")])
        #expect(store.revision == 2)
        store.paletteMayHaveChanged()
        #expect(rig.probe.resolveCalls == 6)
    }

    /// A default written while the colors are being worked out moves the fingerprint. The store took the fingerprint
    /// before the colors, so the next notice sees it moved and works the colors out again.
    @Test func aPaletteChangeDuringAColorPassIsSeenByTheNextNotice() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let probe = rig.probe
        probe.whileResolving = {
            probe.fingerprint = "palette-2"
            probe.whileResolving = nil
        }
        let store = rig.makeStore()
        store.load()
        let calls = probe.resolveCalls
        store.paletteMayHaveChanged()
        #expect(probe.resolveCalls == calls + 3, "the next notice did not work the colors out again")
    }

    /// The notice never starts a load of the file, even when the palette moved.
    @Test func theDefaultsNoticeNeverStartsALoadOfTheFile() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.write(Self.otherText)
        rig.probe.fingerprint = "palette-2"
        store.paletteMayHaveChanged()
        #expect(store.list.entries == hisEntries)
        rig.removeFile()
        store.paletteMayHaveChanged()
        #expect(store.pendingSecondLoad == nil)
        #expect(store.problems.isEmpty)
    }

    /// The notice's body called by hand with a fingerprint that has not moved, as the copy's own write leaves it:
    /// nothing happens. No test here shows that a real defaults write reaches the method.
    @Test func theNoticesBodyCalledWithAnUnmovedFingerprintDoesNothing() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        #expect(rig.copyWrites == 1)
        let calls = rig.probe.resolveCalls
        let revision = store.revision
        store.paletteMayHaveChanged()
        #expect(rig.probe.resolveCalls == calls)
        #expect(store.revision == revision)
        #expect(rig.copyWrites == 1)
    }

    @Test func theNumberGoesUpWhenSomethingChangedAndNotWhenNothingDid() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        #expect(store.revision == 1)
        store.load()
        store.load()
        #expect(store.revision == 1)
        rig.write(Self.otherText)
        store.load()
        #expect(store.revision == 2)
        rig.write("{")
        store.load()
        #expect(store.revision == 3)
        store.load()
        #expect(store.revision == 3)
    }

    /// The palette moved but every answer is the same: the colors are worked out again and the number stays.
    @Test func aPaletteMoveThatChangesNoAnswerLeavesTheNumberAlone() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        #expect(store.revision == 1)
        rig.probe.fingerprint = "palette-2"
        store.paletteMayHaveChanged()
        #expect(rig.probe.resolveCalls == 6)
        #expect(store.revision == 1)
    }

    @Test func theNumberGoesUpWhenOnlyAColorChanged() throws {
        let rig = try StoreRig()
        defer { rig.cleanUp() }
        rig.write(Self.hisText)
        let store = rig.makeStore()
        store.load()
        rig.probe.fingerprint = "palette-2"
        rig.probe.resolves = { _ in false }
        store.paletteMayHaveChanged()
        #expect(store.revision == 2)
        #expect(store.colorHexes.isEmpty)
    }
}
