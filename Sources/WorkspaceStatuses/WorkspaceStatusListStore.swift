import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import Observation
import os

/// The app's one status list: reads `workspaceStatuses` from `cmux.json`, holds the list in use, each status's
/// resolved color and the problems, and keeps a stored copy of the last list that worked (#cm-109.2).
///
/// Made once by the app delegate, which does not yet make it. Making it reads no file and writes no default; only
/// `load()` and `start()` do. A load that did not work changes nothing in use and never removes the stored copy.
@MainActor
@Observable
final class WorkspaceStatusListStore {
    /// The defaults key of the stored copy: the checked list as a JSON array with the file's key names.
    static let storedCopyKey = "workspaceStatuses.lastListThatWorked.v1"
    /// The one sentence this file types. A top level that parses but is not an object.
    static let notAnObjectDetail = "The top level is not an object."

    private static let log = Logger(subsystem: "com.cmuxterm.app", category: "WorkspaceStatusListStore")

    /// The list in use. cmux's five until a load leaves another.
    private(set) var list = WorkspaceStatusList.cmuxFive
    /// Each status's color as this app resolves it, by status id. An entry whose color does not resolve has none.
    private(set) var colorHexes: [String: String] = [:]
    /// What the load found, then a `.colorNotInThisApp` for each color this app cannot resolve.
    private(set) var problems: [WorkspaceStatusListProblem] = []
    /// Goes up when the list, the colors or the problems change, and only then.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resolveColor: (String) -> String?
    @ObservationIgnored private let paletteFingerprint: () -> String
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let parser = WorkspaceStatusListParser(
        symbolExists: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    )

    /// What the last load found, without the color problems.
    @ObservationIgnored private var loadProblems: [WorkspaceStatusListProblem] = []
    /// False until a load has put a list in use, so that the first load that did not work reads the stored copy.
    @ObservationIgnored private var hasListInMemory = false
    /// The palette fingerprint seen at the last color pass.
    @ObservationIgnored private var lastFingerprint: String?
    /// The second look at a file that was missing, unreadable or empty. A test awaits it after advancing the clock.
    @ObservationIgnored private(set) var pendingSecondLoad: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsTask: Task<Void, Never>?

    /// Creates the store. Reads no file and writes no default.
    ///
    /// - Parameters:
    ///   - fileURL: The `cmux.json` to read.
    ///   - defaults: Where the stored copy lives, and whose changes the store watches.
    ///   - resolveColor: The hex this app has for a typed color, or `nil`.
    ///   - paletteFingerprint: Changes when the app's color labels or palette change.
    ///   - clock: Times the second load.
    init(
        fileURL: URL,
        defaults: UserDefaults,
        resolveColor: @escaping (String) -> String?,
        paletteFingerprint: @escaping () -> String,
        clock: any Clock<Duration>
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.resolveColor = resolveColor
        self.paletteFingerprint = paletteFingerprint
        self.clock = clock
    }

    /// Starts watching the file and the defaults, then does the first load.
    func start() {
        guard watchTask == nil else { return }
        // The watcher first, so a write between the first read and the watcher's open is not missed.
        let watcher = FileWatcher(path: fileURL.path)
        self.watcher = watcher
        let events = watcher.events
        watchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.load()
            }
        }
        let center = NotificationCenter.default
        let name = UserDefaults.didChangeNotification
        let observed = defaults
        defaultsTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: name, object: observed) {
                guard let self else { break }
                self.paletteMayHaveChanged()
            }
        }
        load()
    }

    // MARK: - One load

    /// One load. A newer load takes the place of a second look that is still waiting.
    func load() {
        pendingSecondLoad?.cancel()
        pendingSecondLoad = nil
        performLoad(isSecond: false)
    }

    private enum FileRead {
        case missing
        case unreadable
        case empty
        case notParsed(detail: String)
        case worked(root: [String: Any])
    }

    private func readFile() -> FileRead {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        if data.isEmpty { return .empty }
        // The comment stripper removes a block comment with its line breaks, so after one the line that
        // `JSONSerialization` names is too small: with a `/*` in the text its detail is empty. The search reads the
        // bytes as UTF-8, so for a file that is not valid UTF-8 (UTF-16, say) it cannot be trusted: no position either.
        let positionIsTrusted = String(data: data, encoding: .utf8).map { !$0.contains("/*") } ?? false
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            return .notParsed(detail: error.localizedDescription)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: sanitized, options: [.fragmentsAllowed])
        } catch {
            let debug = (error as NSError).userInfo["NSDebugDescription"] as? String
            return .notParsed(detail: positionIsTrusted ? (debug ?? error.localizedDescription) : "")
        }
        guard let root = object as? [String: Any] else { return .notParsed(detail: Self.notAnObjectDetail) }
        return .worked(root: root)
    }

    private func performLoad(isSecond: Bool) {
        switch readFile() {
        case .worked(let root):
            // The optional itself: a wrapped missing key would read as "not a list".
            let parsed = parser.parse(root["workspaceStatuses"])
            if let parsedList = parsed.list {
                hasListInMemory = true
                storeCopyIfDifferent(parsedList.entries)
                loadProblems = parsed.problems
                publish(list: parsedList)
            } else if parsed.problems.isEmpty {
                // The file parses and has no key: his list is taken out.
                if defaults.object(forKey: Self.storedCopyKey) != nil {
                    defaults.removeObject(forKey: Self.storedCopyKey)
                }
                hasListInMemory = true
                loadProblems = []
                publish(list: .cmuxFive)
            } else {
                keep(problems: parsed.problems)
            }
        case .notParsed(let detail):
            keep(problems: [.fileNotRead(missing: false, detail: detail)])
        case .missing:
            notRead(missing: true, isSecond: isSecond)
        case .unreadable, .empty:
            notRead(missing: false, isSecond: isSecond)
        }
    }

    /// The list a load that did not work leaves in use: the one in memory, else the stored copy, else cmux's five.
    private func listKept() -> WorkspaceStatusList {
        if hasListInMemory { return list }
        hasListInMemory = true
        return storedCopy() ?? .cmuxFive
    }

    /// A load that did not work and says so at once.
    private func keep(problems newProblems: [WorkspaceStatusListProblem]) {
        let kept = listKept()
        loadProblems = newProblems
        publish(list: kept)
    }

    /// A file that is missing, cannot be read or is empty. It is told only when a list from the file or the stored
    /// copy stays in use because of it, and only when a second load one second later does not work either.
    private func notRead(missing: Bool, isSecond: Bool) {
        let kept = listKept()
        guard kept.source != .cmux else {
            loadProblems = []
            publish(list: kept)
            return
        }
        if isSecond {
            loadProblems = [.fileNotRead(missing: missing, detail: "")]
        } else {
            scheduleSecondLoad()
        }
        publish(list: kept)
    }

    private func scheduleSecondLoad() {
        pendingSecondLoad?.cancel()
        let clock = self.clock
        pendingSecondLoad = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
            // A look that was replaced is cancelled on the main actor, and this resumes on it, so a look that is not
            // cancelled here is the current one.
            guard !Task.isCancelled, let self else { return }
            self.pendingSecondLoad = nil
            self.performLoad(isSecond: true)
        }
    }

    // MARK: - The stored copy

    /// The stored copy, read back through the checks the file goes through. A copy that is not a list, or that gives
    /// any problem, counts as no copy and is left where it is.
    private func storedCopy() -> WorkspaceStatusList? {
        guard let data = defaults.data(forKey: Self.storedCopyKey),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let parsed = parser.parse(value)
        guard let copy = parsed.list, parsed.problems.isEmpty else { return nil }
        return WorkspaceStatusList(entries: copy.entries, source: .stored)
    }

    /// Written only when the entries differ from the copy's, so a save that changes nothing writes no default.
    private func storeCopyIfDifferent(_ entries: [WorkspaceStatusEntry]) {
        if let copy = storedCopy(), copy.entries == entries { return }
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.storedCopyKey)
        } catch {
            Self.log.error("could not write the stored status list: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Colors

    /// The defaults-change notice. It fires for any key, so the colors are worked out again only when the palette's
    /// fingerprint moved since the last color pass. It never starts a load of the file.
    func paletteMayHaveChanged() {
        guard paletteFingerprint() != lastFingerprint else { return }
        publish(list: list)
    }

    /// Resolves each color once, then publishes what changed. The number goes up only when something differs.
    private func publish(list newList: WorkspaceStatusList) {
        // Taken before the colors: a default written meanwhile leaves this fingerprint old, and the next notice works
        // the colors out again.
        let fingerprint = paletteFingerprint()
        var hexes: [String: String] = [:]
        var colorProblems: [WorkspaceStatusListProblem] = []
        for entry in newList.entries {
            guard let color = entry.color else { continue }
            if let hex = resolveColor(color) {
                hexes[entry.id] = hex
            } else {
                colorProblems.append(.colorNotInThisApp(id: entry.id, color: color))
            }
        }
        lastFingerprint = fingerprint
        let newProblems = loadProblems + colorProblems
        guard newList != list || hexes != colorHexes || newProblems != problems else { return }
        list = newList
        colorHexes = hexes
        problems = newProblems
        revision += 1
    }
}
