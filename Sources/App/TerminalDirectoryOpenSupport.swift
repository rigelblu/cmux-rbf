import CmuxFoundation
import CmuxCore
import AppKit
import CmuxCommandPalette
import CmuxWorkspaces
import Darwin
import Foundation

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    private static func normalizedComparisonURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSameOrDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let urlPathComponents = normalizedComparisonURL(url).pathComponents
        let rootPathComponents = normalizedComparisonURL(rootURL).pathComponents
        guard urlPathComponents.count >= rootPathComponents.count else { return false }
        return Array(urlPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    private static func resolvedDirectoryURL(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.hasDirectoryPath {
            return standardized
        }
        if let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            return standardized
        }
        return standardized.deletingLastPathComponent()
    }

    static func orderedUniqueDirectories(
        from pathURLs: [URL],
        excludingDescendantsOf excludedRootURLs: [URL] = []
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let directoryURL = resolvedDirectoryURL(from: url)
            guard !excludedRootURLs.contains(where: { isSameOrDescendant(directoryURL, of: $0) }) else {
                continue
            }
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            let dedupePath = canonicalDirectoryPath(
                normalizedComparisonURL(directoryURL).path(percentEncoded: false)
            )
            guard !path.isEmpty, !dedupePath.isEmpty else { continue }
            if seen.insert(dedupePath).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case androidStudio
    case antigravity
    case cursor
    case devin
    case finder
    case ghostty
    case intellij
    case iterm2
    case terminal
    case tower
    case vscode
    case vscodeInline
    case warp
    case windsurf
    case xcode
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
        let applicationPathForName: (String) -> String?

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationPathForName: { NSWorkspace.shared.fullPath(forApplication: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .androidStudio:
            return String(localized: "menu.openInAndroidStudio", defaultValue: "Open Current Directory in Android Studio")
        case .antigravity:
            return String(localized: "menu.openInAntigravity", defaultValue: "Open Current Directory in Antigravity")
        case .cursor:
            return String(localized: "menu.openInCursor", defaultValue: "Open Current Directory in Cursor")
        case .devin:
            return String(localized: "menu.openInDevin", defaultValue: "Open Current Directory in Devin")
        case .finder:
            return String(localized: "menu.openInFinder", defaultValue: "Open Current Directory in Finder")
        case .ghostty:
            return String(localized: "menu.openInGhostty", defaultValue: "Open Current Directory in Ghostty")
        case .intellij:
            return String(localized: "menu.openInIntelliJ", defaultValue: "Open Current Directory in IntelliJ IDEA")
        case .iterm2:
            return String(localized: "menu.openInITerm2", defaultValue: "Open Current Directory in iTerm2")
        case .terminal:
            return String(localized: "menu.openInTerminal", defaultValue: "Open Current Directory in Terminal")
        case .tower:
            return String(localized: "menu.openInTower", defaultValue: "Open Current Directory in Tower")
        case .vscode:
            return String(localized: "menu.openInVSCodeDesktop", defaultValue: "Open Current Directory in VS Code")
        case .vscodeInline:
            return String(localized: "menu.openInVSCode", defaultValue: "Open Current Directory in VS Code (Inline)")
        case .warp:
            return String(localized: "menu.openInWarp", defaultValue: "Open Current Directory in Warp")
        case .windsurf:
            return String(localized: "menu.openInWindsurf", defaultValue: "Open Current Directory in Windsurf")
        case .xcode:
            return String(localized: "menu.openInXcode", defaultValue: "Open Current Directory in Xcode")
        case .zed:
            return String(localized: "menu.openInZed", defaultValue: "Open Current Directory in Zed")
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
        case .androidStudio:
            return common + ["android", "studio"]
        case .antigravity:
            return common + ["antigravity"]
        case .cursor:
            return common + ["cursor"]
        case .devin:
            return common + ["devin", "cognition"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .intellij:
            return common + ["intellij", "idea", "jetbrains"]
        case .iterm2:
            return common + ["iterm", "iterm2", "terminal", "shell"]
        case .terminal:
            return common + ["terminal", "shell"]
        case .tower:
            return common + ["tower", "git", "client"]
        case .vscode:
            return common + ["vs", "code", "visual", "studio", "desktop", "app"]
        case .vscodeInline:
            return common + ["vs", "code", "visual", "studio", "inline", "browser", "serve-web"]
        case .warp:
            return common + ["warp", "terminal", "shell"]
        case .windsurf:
            return common + ["windsurf"]
        case .xcode:
            return common + ["xcode", "apple"]
        case .zed:
            return common + ["zed"]
        }
    }

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        guard let applicationPath = applicationPath(in: environment) else { return false }
        guard self == .vscodeInline else { return true }
        // Keep menu/palette availability cheap. Cached code-server discovery does
        // disk I/O and belongs to the actual launch path on the launch queue.
        let codeTunnelURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
            .appendingPathComponent("Contents/Resources/app/bin/code-tunnel", isDirectory: false)
        return environment.isExecutableFileAtPath(codeTunnelURL.path)
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }

        // Fall back to LaunchServices so apps outside the standard bundle paths
        // still appear in the command palette.
        for applicationName in applicationSearchNames {
            guard let resolvedPath = environment.applicationPathForName(applicationName),
                  environment.fileExistsAtPath(resolvedPath) else {
                continue
            }
            return resolvedPath
        }

        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private var applicationSearchNames: [String] {
        uniquePreservingOrder(
            applicationBundlePathCandidates.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
        )
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .devin:
            return ["/Applications/Devin.app"]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .intellij:
            return ["/Applications/IntelliJ IDEA.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .tower:
            return ["/Applications/Tower.app"]
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .vscodeInline:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .warp:
            return ["/Applications/Warp.app"]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

enum VSCodeServeWebURLBuilder {
    static func extractWebUIURL(from output: String) -> URL? {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
            return url
        }
        return nil
    }

    static func openFolderURL(baseWebUIURL: URL, directoryPath: String) -> URL? {
        var components = URLComponents(url: baseWebUIURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "folder" }
        queryItems.append(URLQueryItem(name: "folder", value: directoryPath))
        components?.queryItems = queryItems
        return components?.url
    }
}

struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
}

enum VSCodeCLILaunchConfigurationBuilder {
    private struct VSCodeProductMetadata: Decodable {
        let dataFolderName: String?
    }

    static func launchConfiguration(
        vscodeApplicationURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        dataAtURL: (URL) -> Data? = { try? Data(contentsOf: $0) },
        contentsOfDirectoryAtURL: (URL) -> [URL] = { url in
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        },
        contentModificationDateAtURL: (URL) -> Date? = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    ) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let environment = nodeSafeEnvironment(from: baseEnvironment)

        if let codeServerURL = preferredCachedCodeServerURL(
            contentsURL: contentsURL,
            homeDirectoryURL: homeDirectoryURL,
            isExecutableAtPath: isExecutableAtPath,
            dataAtURL: dataAtURL,
            contentsOfDirectoryAtURL: contentsOfDirectoryAtURL,
            contentModificationDateAtURL: contentModificationDateAtURL
        ) {
            var codeServerEnvironment = environment
            codeServerEnvironment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            return VSCodeCLILaunchConfiguration(
                executableURL: codeServerURL,
                argumentsPrefix: [],
                environment: codeServerEnvironment
            )
        }

        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        guard isExecutableAtPath(codeTunnelURL.path) else { return nil }
        var codeTunnelEnvironment = environment
        codeTunnelEnvironment["ELECTRON_RUN_AS_NODE"] = "1"

        return VSCodeCLILaunchConfiguration(
            executableURL: codeTunnelURL,
            argumentsPrefix: ["serve-web"],
            environment: codeTunnelEnvironment
        )
    }

    private static func nodeSafeEnvironment(from baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        environment.removeValue(forKey: "VSCODE_NODE_OPTIONS")
        environment.removeValue(forKey: "VSCODE_NODE_REPL_EXTERNAL_MODULE")
        if let nodeOptions = environment["NODE_OPTIONS"] {
            environment["VSCODE_NODE_OPTIONS"] = nodeOptions
        }
        if let nodeReplExternalModule = environment["NODE_REPL_EXTERNAL_MODULE"] {
            environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = nodeReplExternalModule
        }
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
        return environment
    }

    private static func preferredCachedCodeServerURL(
        contentsURL: URL,
        homeDirectoryURL: URL,
        isExecutableAtPath: (String) -> Bool,
        dataAtURL: (URL) -> Data?,
        contentsOfDirectoryAtURL: (URL) -> [URL],
        contentModificationDateAtURL: (URL) -> Date?
    ) -> URL? {
        let dataFolderName = vscodeDataFolderName(
            contentsURL: contentsURL,
            dataAtURL: dataAtURL
        )
        let serveWebCacheURL = homeDirectoryURL
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("cli/serve-web", isDirectory: true)

        if let orderedCacheIDs = serveWebLRUCacheIDs(
            serveWebCacheURL: serveWebCacheURL,
            dataAtURL: dataAtURL
        ) {
            for cacheID in orderedCacheIDs {
                let codeServerURL = serveWebCacheURL
                    .appendingPathComponent(cacheID, isDirectory: true)
                    .appendingPathComponent("bin/code-server", isDirectory: false)
                if isExecutableAtPath(codeServerURL.path) {
                    return codeServerURL
                }
            }
        }

        let candidates = contentsOfDirectoryAtURL(serveWebCacheURL)
            .map {
                $0.appendingPathComponent("bin/code-server", isDirectory: false)
            }
            .filter {
                isExecutableAtPath($0.path)
            }
            .sorted { lhs, rhs in
                let lhsDate = contentModificationDateAtURL(lhs) ?? .distantPast
                let rhsDate = contentModificationDateAtURL(rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.path > rhs.path
            }

        return candidates.first
    }

    private static func vscodeDataFolderName(
        contentsURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> String {
        let productURL = contentsURL.appendingPathComponent("Resources/app/product.json", isDirectory: false)
        guard let data = dataAtURL(productURL),
              let product = try? JSONDecoder().decode(VSCodeProductMetadata.self, from: data),
              let dataFolderName = product.dataFolderName,
              isSafePathComponent(dataFolderName) else {
            return ".vscode"
        }
        return dataFolderName
    }

    private static func serveWebLRUCacheIDs(
        serveWebCacheURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> [String]? {
        let lruURL = serveWebCacheURL.appendingPathComponent("lru.json", isDirectory: false)
        guard let data = dataAtURL(lruURL),
              let cacheIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return cacheIDs.filter(isSafePathComponent)
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var connectionTokenFilesByProcessID: [ObjectIdentifier: URL] = [:]
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
#if DEBUG
    private var testingTrackedProcesses: [Process] = []
#endif

    private init(launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil) {
        self.launchProcessOverride = launchProcessOverride
    }

#if DEBUG
    static func makeForTesting(
        launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?
    ) -> VSCodeServeWebController {
        VSCodeServeWebController(launchProcessOverride: launchProcessOverride)
    }

    func trackConnectionTokenFileForTesting(
        _ connectionTokenFileURL: URL,
        setAsLaunchingProcess: Bool = false,
        setAsServeWebProcess: Bool = false
    ) {
        let process = Process()
        queue.sync {
            if setAsLaunchingProcess {
                self.launchingProcess = process
            }
            if setAsServeWebProcess {
                self.serveWebProcess = process
            }
            if !setAsLaunchingProcess && !setAsServeWebProcess {
                self.testingTrackedProcesses.append(process)
            }
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
        }
    }
#endif

    func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        queue.async {
            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }

            let completionGeneration = self.lifecycleGeneration
            self.pendingCompletions.append((generation: completionGeneration, completion: completion))
            guard !self.isLaunching else { return }

            self.isLaunching = true
            let launchGeneration = completionGeneration
            self.activeLaunchGeneration = launchGeneration

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync {
                    self.lifecycleGeneration == launchGeneration
                }
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }
                let launchResult = self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: launchGeneration
                )
                self.queue.async {
                    guard self.activeLaunchGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }
                    self.isLaunching = false
                    self.activeLaunchGeneration = nil

                    guard self.lifecycleGeneration == launchGeneration else {
                        if let launchedProcess = launchResult?.process,
                           self.launchingProcess === launchedProcess {
                            self.launchingProcess = nil
                        }
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }

                    if let launchResult {
                        self.launchingProcess = nil
                        self.serveWebProcess = launchResult.process
                        self.serveWebURL = launchResult.url
                    } else {
                        self.launchingProcess = nil
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }

                    var completions: [(URL?) -> Void] = []
                    var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
                    for pending in self.pendingCompletions {
                        if pending.generation == launchGeneration {
                            completions.append(pending.completion)
                        } else {
                            remaining.append(pending)
                        }
                    }
                    self.pendingCompletions = remaining
                    let resolvedURL = self.serveWebURL
                    DispatchQueue.main.async {
                        completions.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    func stop() {
        let (processes, tokenFileURLs, completions): ([Process], [URL], [(URL?) -> Void]) = queue.sync {
            self.lifecycleGeneration &+= 1
            self.isLaunching = false
            self.activeLaunchGeneration = nil
            var processes: [Process] = []
            if let process = self.serveWebProcess {
                processes.append(process)
            }
            if let process = self.launchingProcess,
               !processes.contains(where: { $0 === process }) {
                processes.append(process)
            }
            self.serveWebProcess = nil
            self.launchingProcess = nil
#if DEBUG
            self.testingTrackedProcesses.removeAll()
#endif
            var tokenFileURLs = processes.compactMap {
                self.connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier($0))
            }
            tokenFileURLs.append(contentsOf: self.connectionTokenFilesByProcessID.values)
            self.connectionTokenFilesByProcessID.removeAll()
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            return (processes, tokenFileURLs, completions)
        }

        for tokenFileURL in tokenFileURLs {
            Self.removeConnectionTokenFile(at: tokenFileURL)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(nil) }
            }
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL, completion: completion)
    }

    func isServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL else { return false }
        let serveWebURL = queue.sync {
            self.serveWebURL
        }
        return Self.urlsShareLoopbackOrigin(candidateURL, serveWebURL)
    }

    private func launchServeWebProcess(
        vscodeApplicationURL: URL,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        if let launchProcessOverride {
            return launchProcessOverride(vscodeApplicationURL, expectedGeneration)
        }

        guard let launchConfiguration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        guard let connectionTokenFileURL = Self.makeConnectionTokenFile() else {
            return nil
        }

        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.argumentsPrefix + [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", "0",
            "--connection-token-file", connectionTokenFileURL.path,
        ]
        process.environment = launchConfiguration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: (FileHandle) -> Void = { fileHandle in
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                fileHandle.readabilityHandler = nil
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = outputReader
        stderrPipe.fileHandleForReading.readabilityHandler = outputReader

        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === terminatedProcess {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(terminatedProcess)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(process)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.removeConnectionTokenFile(at: connectionTokenFileURL)
            return nil
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            } else {
                queue.sync {
                    if self.launchingProcess === process {
                        self.launchingProcess = nil
                    }
                    if self.serveWebProcess === process {
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }
                    if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                        forKey: ObjectIdentifier(process)
                    ) {
                        Self.removeConnectionTokenFile(at: tokenFileURL)
                    }
                }
            }
            return nil
        }

        return (process, serveWebURL)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConnectionTokenFile() -> URL? {
        let token = randomConnectionToken()
        let tokenFileName = "cmux-vscode-token-\(UUID().uuidString)"
        let tokenFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(tokenFileName, isDirectory: false)
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            removeConnectionTokenFile(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    private static func removeConnectionTokenFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func urlsShareLoopbackOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        guard lhs.scheme?.lowercased() == "http",
              rhs.scheme?.lowercased() == "http" else {
            return false
        }
        guard lhs.port == rhs.port, lhs.port != nil else { return false }
        guard let lhsHost = BrowserInsecureHTTPSettings.normalizeHost(lhs.host ?? ""),
              let rhsHost = BrowserInsecureHTTPSettings.normalizeHost(rhs.host ?? "") else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(lhsHost)
            && RemoteLoopbackProxyAlias.isLoopbackHost(rhsHost)
    }
}

final class ServeWebOutputCollector {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: line) else {
                continue
            }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }
}

enum WorkspaceShortcutMapper {
    // MARK: - Digit arithmetic (private: it speaks eligible positions, not rows)
    //
    // These two were the whole public API before `#cm-28`, named for *workspace
    // rows* and taking `workspaceCount`. They now range over the **eligible
    // set**, so the same call with `tabs.count` is no longer merely stale — it
    // silently reinstates the bug this slice fixes, and both index spaces are
    // plain `Int`, so nothing catches it. Upstream's six call sites called
    // exactly the old names, which makes an upstream merge the likely way it
    // comes back. Renamed to say which space they speak, and `private` so the
    // eligibility-taking overloads below are the only way in.

    /// The eligible position a digit selects. 1…8 target fixed positions;
    /// 9 always targets the last eligible workspace.
    private static func eligiblePosition(forDigit digit: Int, eligibleCount: Int) -> Int? {
        guard eligibleCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return eligibleCount - 1
        }

        let position = digit - 1
        return position < eligibleCount ? position : nil
    }

    /// The primary digit badge for an eligible position — the lowest digit that
    /// maps to it. `nil` when the position carries no digit, which is every
    /// position between 8 and the last once more than nine are eligible.
    private static func digit(forEligiblePosition position: Int, eligibleCount: Int) -> Int? {
        guard position >= 0 && position < eligibleCount else { return nil }
        for digit in 1...9 {
            if eligiblePosition(forDigit: digit, eligibleCount: eligibleCount) == position {
                return digit
            }
        }
        return nil
    }

    /// The digit badge a workspace row shows, given which workspaces are
    /// eligible. `nil` when the row carries no digit.
    static func digitForWorkspace(
        atFlatIndex flatIndex: Int,
        eligibility: WorkspaceShortcutEligibility
    ) -> Int? {
        guard let position = eligibility.position(forFlatIndex: flatIndex) else { return nil }
        return digit(forEligiblePosition: position, eligibleCount: eligibility.count)
    }

    /// The flat `tabs` index a digit selects, given which workspaces are
    /// eligible. `nil` when the digit selects nothing.
    ///
    /// The exact inverse of ``digitForWorkspace(atFlatIndex:eligibility:)`` over
    /// every flat index that carries a digit — the property the badge telling
    /// the truth depends on.
    static func workspaceFlatIndex(
        forDigit digit: Int,
        eligibility: WorkspaceShortcutEligibility
    ) -> Int? {
        guard let position = eligiblePosition(forDigit: digit, eligibleCount: eligibility.count) else {
            return nil
        }
        return eligibility.flatIndex(forPosition: position)
    }
}

/// The ordered set of workspaces `⌘1…9` ranges over, plus the two conversions
/// between a workspace's flat position in `TabManager.tabs` and its position in
/// that set.
///
/// `#cm-28`. Before this type, ``WorkspaceShortcutMapper``'s two halves both
/// ranged over the flat `tabs` count, which made them exact inverses for free.
/// Once the digits range over a *subset*, that guarantee has to be built rather
/// than inherited — so both directions live here, on one stored array, and the
/// mapper's digit arithmetic sits unchanged on top. Split the two conversions
/// across two types and the badge and the key drift, which shows up as a row
/// wearing a number that selects a different row.
///
/// **Eligible = in play AND ungrouped.**
/// - *In play* reuses ``SidebarWorkspaceRowVisualPalette/suppressesAccentStrip(attentionTaskStatus:)``
///   verbatim, over the lane ``Workspace/attentionTaskStatus(todoControlsEnabled:)``
///   resolves, rather than re-deriving either. The user need is literally "the
///   ones with an Accent Strip", so sharing both halves is what stops
///   "numbered" and "striped" drifting apart later. **That buys one *rule*, not
///   one *sampling instant*:** the strip is drawn from a cached row snapshot
///   whose `presentationKey` excludes task status, so inside a refresh window an
///   unrelated re-render can pair a stale strip with a fresh badge. Bounded and
///   self-healing — and not worth closing by feeding the numbering from those
///   snapshots, which would move the skew onto badge-vs-key, the pair this type
///   exists to keep exact.
/// - *Ungrouped* — **unconditionally; the rule never reads collapse state.** A
///   collapsed group is the case that motivated it: it hides its non-anchor
///   members, so a grouped workspace holding a digit meant a key firing at a
///   row the user could not see. But an *expanded* group's members are visible
///   rows and they get no digit either, because groups leave the numbering
///   entirely rather than leaving it when hidden. `#cm-29` should read this
///   paragraph and not the motivating case alone: it gives groups their own
///   namespace (`⌘⇧1…9`), and until then they carry no digit at all, which is a
///   shipped Known Limitation.
struct WorkspaceShortcutEligibility: Equatable {
    /// One workspace's inputs to the eligibility rule, in flat `tabs` order.
    struct Candidate: Equatable {
        let isGrouped: Bool
        /// The lane the Accent Strip reads — `nil` when the workspace todo
        /// feature is off, which is why an off feature leaves every workspace
        /// eligible and the numbering exactly as it was.
        let attentionTaskStatus: WorkspaceTaskStatus?
    }

    /// Flat `tabs` indices that carry a digit, ascending. The array *is* the
    /// mapping: its element is the flat index, its offset the digit position.
    private let flatIndices: [Int]

    private init(flatIndices: [Int]) {
        self.flatIndices = flatIndices
    }

    /// How many workspaces the digits range over — what the mapper's existing
    /// `workspaceCount` parameter now receives.
    var count: Int { flatIndices.count }

    /// Resolves which workspaces carry a digit, in flat order.
    ///
    /// **The fallback:** when nothing is eligible, the digits range over every
    /// *ungrouped* workspace instead of nothing. The default lane is `.todo`, so
    /// without this a fresh morning would have no keyboard workspace switching
    /// at all, and a dead `⌘1` reads as a broken build rather than a feature.
    /// It widens only the status axis — the group exclusion stays absolute, so
    /// the rule carries no conditional. The leftover case (every workspace
    /// grouped, so the digits are still dead) is deliberately not engineered
    /// for; `#cm-29` gives groups their own keys.
    static func resolve(candidates: [Candidate]) -> WorkspaceShortcutEligibility {
        let ungrouped = candidates.indices.filter { !candidates[$0].isGrouped }
        let inPlay = ungrouped.filter { index in
            !SidebarWorkspaceRowVisualPalette.suppressesAccentStrip(
                attentionTaskStatus: candidates[index].attentionTaskStatus
            )
        }
        return WorkspaceShortcutEligibility(flatIndices: inPlay.isEmpty ? ungrouped : inPlay)
    }

    /// Flat `tabs` index → position among the digit-carrying workspaces.
    /// `nil` when that workspace carries no digit.
    func position(forFlatIndex flatIndex: Int) -> Int? {
        flatIndices.firstIndex(of: flatIndex)
    }

    /// Position among the digit-carrying workspaces → flat `tabs` index.
    /// `nil` when the position is out of range.
    func flatIndex(forPosition position: Int) -> Int? {
        guard flatIndices.indices.contains(position) else { return nil }
        return flatIndices[position]
    }
}

/// The one bridge from live workspaces to the pure rule above.
///
/// Both halves of the feature call this — the sidebar builds it once per render
/// pass and hands it to the badge, the key handlers build it per keystroke from
/// `TabManager.tabs`. A second construction site anywhere would be a second
/// answer to "which workspaces carry a digit", which is the drift this type
/// exists to prevent.
@MainActor
extension WorkspaceShortcutEligibility {
    /// Resolves eligibility from workspaces in flat `tabs` order.
    ///
    /// - Parameter todoControlsEnabled: `WorkspaceTodoFeature.isEnabled`, passed
    ///   in rather than read here for the same reason
    ///   ``SidebarWorkspaceSnapshotFactory`` takes it — the flag reaches
    ///   `UserDefaults` and `CmuxFeatureFlags`, and the callers already sit
    ///   where store access belongs.
    static func resolve(
        workspaces: [Workspace],
        todoControlsEnabled: Bool
    ) -> WorkspaceShortcutEligibility {
        resolve(candidates: workspaces.map { workspace in
            Candidate(
                isGrouped: workspace.groupId != nil,
                // Both fields come from the same place the sidebar reads them,
                // never a local re-derivation: the lane from the palette that
                // owns strip suppression, so "numbered" and "striped" answer to
                // one definition.
                attentionTaskStatus: workspace.attentionTaskStatus(
                    todoControlsEnabled: todoControlsEnabled
                )
            )
        })
    }
}

extension TabManager {
    /// Which of this window's workspaces `⌘1…9` ranges over (`#cm-28`).
    ///
    /// The single live construction site: the sidebar reads it once per render
    /// pass to draw badges, the key handlers read it per keystroke to resolve a
    /// digit. Both must see the same set or a row wears a number that selects a
    /// different row — so the feature flag is read here, once, rather than at
    /// each of the six call sites.
    var workspaceShortcutEligibility: WorkspaceShortcutEligibility {
        WorkspaceShortcutEligibility.resolve(
            workspaces: tabs,
            todoControlsEnabled: WorkspaceTodoFeature.isEnabled
        )
    }
}

extension CommandPaletteContextKeys {
    /// Typed app-side overload over the package's raw-value key builder, so
    /// palette context keys keep the exact `terminal.openTarget.<raw>.available`
    /// format without the package importing the terminal domain.
    static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> CommandPaletteContextKeys {
        terminalOpenTargetAvailable(rawValue: target.rawValue)
    }
}
