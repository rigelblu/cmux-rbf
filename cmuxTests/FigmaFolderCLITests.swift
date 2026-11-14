import Darwin
import Foundation
import Testing

private final class FigmaFolderCLIBundleToken {}

/// `cmux figma folder`, `folder set <folder-url>` and `folder clear`, read from
/// the real CLI binary with no app running.
///
/// **Every child gets a throwaway home, and a test cannot write until it has
/// proved so.** `HOME` and `CFFIXED_USER_HOME` both point at a folder of the
/// test's own: `HOME` alone does not move the home folder Foundation reports
/// (`CmuxConfigLocation` uses `homeDirectoryForCurrentUser`), so a child told
/// only `HOME` reads and writes Tom's real `~/.config/cmux/cmux.json`. The
/// guard is a sentinel the child reads back: `withGuardedHome` seeds the
/// sentinel link in the throwaway file and runs `cmux figma folder --json`; the
/// test goes on only when the child answers with the sentinel's ids, which it
/// can do only by reading the file this test seeded. A test that needs a
/// different file replaces it after the guard has passed, in the same home.
@Suite("FigmaFolderCLI", .serialized)
struct FigmaFolderCLITests {

    // MARK: - Fixtures

    private static let team = "764866853003674551"
    private static let folder = "643299150"
    private static let good = "https://www.figma.com/files/team/\(team)/folder/\(folder)"
    private static let addressBar = "\(good)?fuid=764866775710094844"
    private static let sentinel = "https://www.figma.com/files/team/1/folder/2"
    private static let noTeamLink = "https://www.figma.com/files/folder/\(folder)"
    private static let otherGood = "https://www.figma.com/files/team/1/folder/2"
    private static let designLink = "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73"

    private static let notSetOutput = """
    No default Figma folder. New designs go to your Figma Drafts.
    Set one:  cmux figma folder set <folder-url>
    Or for this directory only:  cmux figma folder set <folder-url> --dir .

    """
    private static let setOutput = """
    Default Figma folder set.
      projectId  \(folder)
      planKey    team::\(team)

    """
    private static let readOutput = """
    projectId  \(folder)
    planKey    team::\(team)
    url        \(good)
    directory  default

    """
    private static let clearedOutput = "Default Figma folder cleared. New designs go to your Figma Drafts.\n"
    private static let fixIt = "Fix it:  cmux figma folder set <folder-url>"

    /// The file the tests that write start from: other keys the command must leave alone.
    private static let base = #"{"app": {"devWindowDisplay": "Test Display"}, "zz_keep": {"b": 2, "a": 1}}"#

    // MARK: - Throwaway home

    private struct Home {
        let root: URL
        var configFile: URL { root.appendingPathComponent(".config/cmux/cmux.json") }
        var configFolder: URL { configFile.deletingLastPathComponent() }

        /// `nil` removes the file; `mode` is set after the write.
        func seed(_ contents: String?, mode: Int = 0o600) throws {
            let fileManager = FileManager.default
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configFolder.path)
            try? fileManager.removeItem(at: configFile)
            guard let contents else { return }
            try fileManager.createDirectory(at: configFolder, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: configFile)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: configFile.path)
        }

        var exists: Bool { FileManager.default.fileExists(atPath: configFile.path) }
        var bytes: Data? { try? Data(contentsOf: configFile) }
        var modified: Date? {
            (try? FileManager.default.attributesOfItem(atPath: configFile.path))?[.modificationDate] as? Date
        }
        var mode: Int? {
            ((try? FileManager.default.attributesOfItem(atPath: configFile.path))?[.posixPermissions] as? NSNumber)?.intValue
        }
        var object: [String: Any]? {
            guard let bytes else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
    }

    /// The guard refused to go on: the child did not read the file the test seeded.
    private struct GuardFailed: Error, CustomStringConvertible {
        let description: String
    }

    private struct ProcessTimeout: Error, CustomStringConvertible {
        let arguments: [String]
        let stillRunning: Bool
        var description: String {
            "cmux \(arguments.joined(separator: " ")) did not exit within 30 s; after SIGTERM and a 2 s grace it was "
                + (stillRunning ? "still running" : "gone")
        }
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        /// Connections plus request lines the stand-in socket saw. 0 when nothing listened.
        let socketTraffic: Int
    }

    /// A Unix socket that counts what reaches it and answers nothing useful.
    private final class StandInSocket: @unchecked Sendable {
        let path: String
        private let listenerFD: Int32
        private let lock = NSLock()
        private var traffic = 0

        init(path: String) throws {
            self.path = path
            unlink(path)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else {
                Darwin.close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    for index in 0..<bytes.count { buffer[index] = CChar(bitPattern: bytes[index]) }
                    buffer[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                Darwin.close(fd)
                throw POSIXError(code)
            }
            listenerFD = fd
            CLIMockAcceptLoopRegistry.shared.start(listenerFD: fd, onConnection: { [self] clientFD in
                defer { Darwin.close(clientFD) }
                self.count()
                cliMockServeLineFramedConnection(clientFD: clientFD) { _ in
                    self.count()
                    return #"{"id":null,"ok":false,"error":{"code":"unexpected","message":"no socket expected"}}"#
                }
            }, onListenerClosed: {})
        }

        private func count() {
            lock.lock()
            traffic += 1
            lock.unlock()
        }

        var seen: Int {
            lock.lock()
            defer { lock.unlock() }
            return traffic
        }

        func stop() {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(path)
        }
    }

    private static func runWithBoundedWait(_ process: Process, arguments: [String]) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw ProcessTimeout(arguments: arguments, stillRunning: process.isRunning)
        }
    }

    /// Runs `cmux <arguments>` in `home`. `socket` listens on the path the child is told;
    /// without it the path is set and nothing listens.
    private func run(
        _ arguments: [String],
        in home: Home,
        directory: String? = nil,
        pwd: String? = nil,
        socket: StandInSocket? = nil
    ) throws -> Run {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: FigmaFolderCLIBundleToken.self)
        )
        process.arguments = arguments
        var environment = [
            "HOME": home.root.path,
            "TMPDIR": home.root.path + "/",
            "PATH": "/usr/bin:/bin",
            "CMUX_SOCKET_PATH": socket?.path ?? home.root.appendingPathComponent("none.sock").path,
            "CMUX_CLI_SENTRY_DISABLED": "1"
        ]
        environment["CFFIXED_USER_HOME"] = home.root.path
        if let pwd { environment["PWD"] = pwd }
        process.environment = environment
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try Self.runWithBoundedWait(process, arguments: arguments)
        return Run(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            socketTraffic: socket?.seen ?? 0
        )
    }

    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Makes a throwaway home, seeds the sentinel, and goes on only when the child
    /// reads it back. The body gets the home with the sentinel still in place.
    private func withGuardedHome<T>(_ body: (Home) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-figma-folder-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = Home(root: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.configFolder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try home.seed(#"{"figma": {"defaultFolder": "\#(Self.sentinel)"}}"#)
        let read = try run(["figma", "folder", "--json"], in: home)
        let folder = (json(read.stdout)?["default_folder"] as? [String: Any])
        guard read.status == 0,
              folder?["project_id"] as? String == "2",
              folder?["plan_key"] as? String == "team::1"
        else {
            let found = "status \(read.status), stdout \(read.stdout.debugDescription), stderr \(read.stderr.debugDescription)"
            Issue.record("the guard stopped the test: the child did not read the sentinel this test seeded (\(found))")
            throw GuardFailed(description: found)
        }
        return try body(home)
    }

    private func fails(_ run: Run, with message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run.status == 1, "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stderr == "Error: \(message)\n", sourceLocation: sourceLocation)
        #expect(run.stdout.isEmpty, "\(run.stdout)", sourceLocation: sourceLocation)
    }

    // MARK: - The guard

    @Test("the guard passes when the child reads the file the test seeded")
    func guardPasses() throws {
        try withGuardedHome { home in
            #expect(home.exists)
        }
    }

    // MARK: - Nothing set (Scenario 5)

    private struct NotSetCase: Sendable, CustomTestStringConvertible {
        let name: String
        /// `nil` means no `cmux.json` at all.
        let contents: String?
        var testDescription: String { name }
    }

    private static let notSetFiles: [NotSetCase] = [
        NotSetCase(name: "no cmux.json", contents: nil),
        NotSetCase(name: "other keys, no figma key", contents: base),
        NotSetCase(name: "{}", contents: "{}"),
        NotSetCase(name: #""figma": {}"#, contents: #"{"figma": {}}"#),
        NotSetCase(name: #""figma": null"#, contents: #"{"figma": null}"#),
        NotSetCase(name: "defaultFolder null", contents: #"{"figma": {"defaultFolder": null}}"#),
        NotSetCase(name: "defaultFolder empty", contents: #"{"figma": {"defaultFolder": ""}}"#),
        NotSetCase(name: "defaultFolder spaces only", contents: #"{"figma": {"defaultFolder": "   "}}"#)
    ]

    @Test("nothing set prints its two lines and exits 0, with nothing on stderr", arguments: notSetFiles)
    private func notSetPrintsTwoLines(_ file: NotSetCase) throws {
        try withGuardedHome { home in
            try home.seed(file.contents)
            let before = home.bytes
            let stamp = home.modified
            let plain = try run(["figma", "folder"], in: home)
            #expect(plain.status == 0, "\(plain.stderr)")
            #expect(plain.stdout == Self.notSetOutput, "\(plain.stdout.debugDescription)")
            #expect(plain.stderr.isEmpty, "\(plain.stderr)")

            let asJSON = try run(["figma", "folder", "--json"], in: home)
            #expect(asJSON.status == 0, "\(asJSON.stderr)")
            let object = json(asJSON.stdout)
            #expect(object?.count == 2, "\(asJSON.stdout)")
            #expect(object?["default_folder"] is NSNull, "\(asJSON.stdout)")
            #expect(object?["folder"] is NSNull, "\(asJSON.stdout)")

            #expect(home.bytes == before, "a read changed the file")
            #expect(home.modified == stamp, "a read rewrote the file")
            if file.contents == nil { #expect(!home.exists, "a read created the file") }
        }
    }

    // MARK: - Broken reads (Scenario 5)

    private struct BrokenCase: Sendable, CustomTestStringConvertible {
        let name: String
        let contents: String
        var mode: Int = 0o600
        /// The whole stderr line(s) after `Error: `, with `{path}` for the config file.
        let message: String
        /// Only the start of the message is pinned: the system words the rest.
        var prefixOnly = false
        var testDescription: String { name }
    }

    private static func notUsable(_ reason: String) -> String {
        "the default Figma folder in cmux.json is not a URL cmux can use:\n       \(reason)\n       \(fixIt)"
    }

    private static let brokenFiles: [BrokenCase] = [
        BrokenCase(name: "not valid JSON", contents: #"{ "figma": "#,
                   message: "could not read {path}: it is not valid JSON."),
        BrokenCase(name: "top level array", contents: "[1]",
                   message: "could not read {path}: it is not valid JSON."),
        BrokenCase(name: "spaces and a line break only", contents: "  \n",
                   message: "could not read {path}: it is not valid JSON."),
        BrokenCase(name: "mode 000", contents: "{}", mode: 0o000,
                   message: "could not read {path}: ", prefixOnly: true),
        BrokenCase(name: #""figma": "x""#, contents: #"{"figma": "x"}"#, message: notUsable("it is not text.")),
        BrokenCase(name: "defaultFolder 5", contents: #"{"figma": {"defaultFolder": 5}}"#,
                   message: notUsable("it is not text.")),
        BrokenCase(name: "defaultFolder true", contents: #"{"figma": {"defaultFolder": true}}"#,
                   message: notUsable("it is not text.")),
        BrokenCase(name: "defaultFolder []", contents: #"{"figma": {"defaultFolder": []}}"#,
                   message: notUsable("it is not text.")),
        BrokenCase(name: "defaultFolder {}", contents: #"{"figma": {"defaultFolder": {}}}"#,
                   message: notUsable("it is not text.")),
        BrokenCase(name: "stored link with no team", contents: #"{"figma": {"defaultFolder": "\#(noTeamLink)"}}"#,
                   message: notUsable("this Figma folder URL has no team in it.")),
        BrokenCase(name: "stored design link", contents: #"{"figma": {"defaultFolder": "\#(designLink)"}}"#,
                   message: notUsable("not a Figma folder URL."))
    ]

    @Test("a setting an agent cannot use exits 1 with the reason, and the file is not touched",
          arguments: brokenFiles)
    private func brokenReadsExitOne(_ file: BrokenCase) throws {
        try withGuardedHome { home in
            try home.seed(file.contents, mode: file.mode)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.configFile.path) }
            let before = file.mode == 0 ? nil : home.bytes
            let stamp = file.mode == 0 ? nil : home.modified
            let expected = file.message.replacingOccurrences(of: "{path}", with: home.configFile.path)
            for arguments in [["figma", "folder"], ["figma", "folder", "--json"]] {
                let read = try run(arguments, in: home)
                #expect(read.status == 1, "\(arguments): \(read.stderr)")
                #expect(read.stdout.isEmpty, "\(arguments): \(read.stdout)")
                if file.prefixOnly {
                    #expect(read.stderr.hasPrefix("Error: \(expected)"), "\(arguments): \(read.stderr.debugDescription)")
                } else {
                    #expect(read.stderr == "Error: \(expected)\n", "\(arguments): \(read.stderr.debugDescription)")
                }
            }
            if file.mode != 0 {
                #expect(home.bytes == before, "a read changed the file")
                #expect(home.modified == stamp, "a read rewrote the file")
            }
        }
    }

    // MARK: - set, read, clear (Scenario 5c)

    @Test("set stores the trimmed link, prints the two values, and leaves every other key and the mode alone")
    func setStoresTheTrimmedLink() throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let set = try run(["figma", "folder", "set", Self.addressBar], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout == Self.setOutput, "\(set.stdout.debugDescription)")
            #expect(set.stderr.isEmpty, "\(set.stderr)")

            let root = try #require(home.object)
            #expect((root["figma"] as? [String: Any])?["defaultFolder"] as? String == Self.good)
            #expect(((root["app"] as? [String: Any])?["devWindowDisplay"]) as? String == "Test Display")
            let keep = try #require(root["zz_keep"] as? [String: Int])
            #expect(keep == ["a": 1, "b": 2])
            #expect(home.mode == 0o600, "mode after set: \(String(describing: home.mode))")
        }
    }

    @Test("read prints the three lines; --json prints one key, and set --json and clear --json agree")
    func readAndJSON() throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let setJSON = try run(["figma", "folder", "set", "--json", Self.addressBar], in: home)
            #expect(setJSON.status == 0, "\(setJSON.stderr)")
            let document: [String: Any] = [
                "default_folder": [
                    "project_id": Self.folder,
                    "plan_key": "team::\(Self.team)",
                    "url": Self.good
                ]
            ]
            #expect(NSDictionary(dictionary: json(setJSON.stdout) ?? [:]).isEqual(to: document), "\(setJSON.stdout)")

            let read = try run(["figma", "folder"], in: home)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == Self.readOutput, "\(read.stdout.debugDescription)")
            #expect(read.stderr.isEmpty, "\(read.stderr)")

            let readDocument: [String: Any] = [
                "default_folder": document["default_folder"] as Any,
                "folder": [
                    "project_id": Self.folder,
                    "plan_key": "team::\(Self.team)",
                    "url": Self.good,
                    "directory": NSNull()
                ]
            ]
            let readJSON = try run(["figma", "folder", "--json"], in: home)
            #expect(NSDictionary(dictionary: json(readJSON.stdout) ?? [:]).isEqual(to: readDocument), "\(readJSON.stdout)")

            let clearJSON = try run(["figma", "folder", "clear", "--json"], in: home)
            #expect(clearJSON.status == 0, "\(clearJSON.stderr)")
            let cleared = json(clearJSON.stdout)
            #expect(cleared?.count == 1, "\(clearJSON.stdout)")
            #expect(cleared?["default_folder"] is NSNull, "\(clearJSON.stdout)")
        }
    }

    @Test("set of the value already stored writes nothing")
    func setOfTheStoredValueWritesNothing() throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            _ = try run(["figma", "folder", "set", Self.good], in: home)
            let bytes = home.bytes
            let stamp = home.modified
            let again = try run(["figma", "folder", "set", Self.addressBar], in: home)
            #expect(again.status == 0, "\(again.stderr)")
            #expect(again.stdout == Self.setOutput, "\(again.stdout.debugDescription)")
            #expect(home.bytes == bytes)
            #expect(home.modified == stamp, "the same value was written again")
        }
    }

    private static let noTeamError = """
    this Figma folder URL has no team in it, and Figma needs the team
           to create a file.

           Open it in a browser signed in to Figma. The address bar then shows
           the full URL:
             https://www.figma.com/files/team/<team-id>/folder/<folder-id>
    """
    private static let notAFolderError = """
    not a Figma folder URL. Expected:
             https://www.figma.com/files/team/<team-id>/folder/<folder-id>
    """

    @Test("a link that is refused exits 1 with the drawn lines, and the file is left as it was",
          arguments: [
              (noTeamLink, true), ("https://www.figma.com/files/764866853003674551/project/643299150", true),
              (designLink, false)
          ])
    func refusedSetLeavesTheFile(link: String, noTeam: Bool) throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let before = home.bytes
            let stamp = home.modified
            let set = try run(["figma", "folder", "set", link], in: home)
            fails(set, with: noTeam ? Self.noTeamError : Self.notAFolderError)
            #expect(home.bytes == before)
            #expect(home.modified == stamp)
            let asJSON = try run(["figma", "folder", "set", "--json", link], in: home)
            fails(asJSON, with: noTeam ? Self.noTeamError : Self.notAFolderError)
            #expect(home.bytes == before)
        }
    }

    @Test("set with no URL, an empty one or only spaces is refused with one line", arguments: [[], [""], ["   "]])
    func setWithoutURL(extra: [String]) throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let before = home.bytes
            let set = try run(["figma", "folder", "set"] + extra, in: home)
            fails(set, with: "cmux figma folder set requires a Figma folder URL")
            #expect(home.bytes == before)
        }
    }

    @Test("an unknown word after folder, a URL with no set included, is refused and names the word",
          arguments: ["bogus", "https://www.figma.com/files/team/764866853003674551/folder/643299150"])
    func unknownWord(word: String) throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let before = home.bytes
            let result = try run(["figma", "folder", word], in: home)
            fails(result, with: "unknown cmux figma folder subcommand '\(word)' (expected set, clear, list)")
            #expect(home.bytes == before)
        }
    }

    @Test("clear removes the key and prunes figma, keeps every other key and the mode, and prints one line")
    func clearRemovesTheKey() throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            _ = try run(["figma", "folder", "set", Self.good], in: home)
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == Self.clearedOutput, "\(clear.stdout.debugDescription)")
            #expect(clear.stderr.isEmpty, "\(clear.stderr)")

            let root = try #require(home.object)
            #expect(root["figma"] == nil, "an empty figma object was left: \(root)")
            #expect(((root["app"] as? [String: Any])?["devWindowDisplay"]) as? String == "Test Display")
            #expect(root["zz_keep"] as? [String: Int] == ["a": 1, "b": 2])
            #expect(home.mode == 0o600, "mode after clear: \(String(describing: home.mode))")

            // Nothing set now: the same line, exit 0, and nothing written.
            let bytes = home.bytes
            let stamp = home.modified
            let again = try run(["figma", "folder", "clear"], in: home)
            #expect(again.status == 0, "\(again.stderr)")
            #expect(again.stdout == Self.clearedOutput)
            #expect(home.bytes == bytes)
            #expect(home.modified == stamp, "a clear with nothing set rewrote the file")
        }
    }

    @Test("clear with no cmux.json creates none, and leaves a file with comments and no figma key as it was")
    func clearWritesNothingWhenNothingIsSet() throws {
        try withGuardedHome { home in
            try home.seed(nil)
            let none = try run(["figma", "folder", "clear"], in: home)
            #expect(none.status == 0, "\(none.stderr)")
            #expect(none.stdout == Self.clearedOutput)
            #expect(!home.exists, "clear created the file")

            let commented = "// my settings\n{\n  /* keep */ \"zz_keep\": 1\n}\n"
            try home.seed(commented)
            let stamp = home.modified
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(home.bytes == Data(commented.utf8), "clear rewrote a file that had no figma key")
            #expect(home.modified == stamp)
        }
    }

    @Test("clear removes a key whose value is broken or empty, because the key is there")
    func clearRemovesAnyValueAtTheKey() throws {
        for value in ["5", "\"\"", "null", "\"\(Self.noTeamLink)\"", "[]"] {
            try withGuardedHome { home in
                try home.seed(#"{"figma": {"defaultFolder": \#(value)}, "zz_keep": 1}"#)
                let clear = try run(["figma", "folder", "clear"], in: home)
                #expect(clear.status == 0, "\(value): \(clear.stderr)")
                let root = try #require(home.object, "\(value)")
                #expect(root["figma"] == nil, "\(value): \(root)")
                #expect(root["zz_keep"] as? Int == 1, "\(value)")
            }
        }
    }

    @Test("clear removes a figma that is not an object, then the read prints the not-set lines",
          arguments: [#""x""#, "7", "[1]", "true"])
    func clearRemovesANonObjectFigma(value: String) throws {
        try withGuardedHome { home in
            try home.seed(#"{"app": {"devWindowDisplay": "Test Display"}, "figma": \#(value), "zz_keep": 1}"#)
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(value): \(clear.stderr)")
            #expect(clear.stdout == Self.clearedOutput, "\(value)")
            #expect(clear.stderr.isEmpty, "\(value): \(clear.stderr)")
            let root = try #require(home.object, "\(value)")
            #expect(root["figma"] == nil, "\(value): \(root)")
            #expect(root["zz_keep"] as? Int == 1, "\(value)")
            #expect(((root["app"] as? [String: Any])?["devWindowDisplay"]) as? String == "Test Display", "\(value)")
            #expect(home.mode == 0o600, "\(value): mode \(String(describing: home.mode))")
            let read = try run(["figma", "folder"], in: home)
            #expect(read.status == 0, "\(value): \(read.stderr)")
            #expect(read.stdout == Self.notSetOutput, "\(value)")
        }
    }

    @Test("clear beside a sibling key keeps the sibling and the figma object")
    func clearKeepsASibling() throws {
        try withGuardedHome { home in
            try home.seed(#"{"figma": {"defaultFolder": 5, "profile": "p"}, "zz_keep": 1}"#)
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == Self.clearedOutput)
            let figma = try #require(home.object?["figma"] as? [String: Any], "the figma object was removed")
            #expect(figma["profile"] as? String == "p")
            #expect(figma["defaultFolder"] == nil, "\(figma)")
            #expect(home.object?["zz_keep"] as? Int == 1)
            let read = try run(["figma", "folder"], in: home)
            #expect(read.stdout == Self.notSetOutput, "\(read.stdout.debugDescription)")
        }
    }

    @Test("clear with figma null writes nothing, and set writes the link over it")
    func figmaNull() throws {
        try withGuardedHome { home in
            let commented = "// keep\n{\"figma\": null, \"zz_keep\": 1}\n"
            try home.seed(commented)
            let stamp = home.modified
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == Self.clearedOutput)
            #expect(home.bytes == Data(commented.utf8), "clear rewrote the file")
            #expect(home.modified == stamp)
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            let figma = try #require(home.object?["figma"] as? [String: Any])
            #expect(figma["defaultFolder"] as? String == Self.good)
        }
    }

    @Test("a stored link with a query reads back trimmed, in the text and in --json")
    func storedLinkReadsTrimmed() throws {
        try withGuardedHome { home in
            try home.seed(#"{"figma": {"defaultFolder": "https://www.figma.com/files/team/1/folder/2?fuid=9"}}"#)
            let read = try run(["figma", "folder"], in: home)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == "projectId  2\nplanKey    team::1\nurl        https://www.figma.com/files/team/1/folder/2\ndirectory  default\n",
                    "\(read.stdout.debugDescription)")
            let asJSON = try run(["figma", "folder", "--json"], in: home)
            let found = json(asJSON.stdout)?["default_folder"] as? [String: Any]
            #expect(found?["url"] as? String == "https://www.figma.com/files/team/1/folder/2", "\(asJSON.stdout)")
        }
    }

    @Test("set with no cmux.json creates it holding only the key, and records its mode")
    func setCreatesTheFile() throws {
        try withGuardedHome { home in
            try home.seed(nil)
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout == Self.setOutput)
            let root = try #require(home.object)
            #expect(root.count == 1, "\(root)")
            #expect((root["figma"] as? [String: Any])?["defaultFolder"] as? String == Self.good)
            // Recorded, not asserted: the store's mode for a file it creates is whatever it is.
            print("FIGMA-FOLDER-RECORDED set-with-no-file mode=\(String(describing: home.mode.map { String($0, radix: 8) }))")
        }
    }

    @Test("set writes over a broken value at the key, and keeps the other keys",
          arguments: [
              #"{"app": {"devWindowDisplay": "Test Display"}, "figma": {"defaultFolder": "https://www.figma.com/files/folder/643299150"}, "zz_keep": 1}"#,
              #"{"app": {"devWindowDisplay": "Test Display"}, "figma": {"defaultFolder": 5}, "zz_keep": 1}"#,
              #"{"app": {"devWindowDisplay": "Test Display"}, "figma": "x", "zz_keep": 1}"#,
              #"{"app": {"devWindowDisplay": "Test Display"}, "figma": null, "zz_keep": 1}"#
          ])
    func setWritesOverABrokenValue(contents: String) throws {
        try withGuardedHome { home in
            try home.seed(contents)
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout == Self.setOutput)
            let root = try #require(home.object)
            #expect((root["figma"] as? [String: Any])?["defaultFolder"] as? String == Self.good, "\(root)")
            #expect(root["zz_keep"] as? Int == 1)
            #expect(((root["app"] as? [String: Any])?["devWindowDisplay"]) as? String == "Test Display")
        }
    }

    @Test("set and clear on a file that is not valid JSON stop with exit 1 and change nothing",
          arguments: [#"{ "figma": "#, "[1]", "  \n"])
    func writesRefuseABrokenFile(contents: String) throws {
        try withGuardedHome { home in
            try home.seed(contents)
            let before = home.bytes
            let stamp = home.modified
            let message = "could not read \(home.configFile.path): it is not valid JSON."
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            fails(set, with: message)
            let clear = try run(["figma", "folder", "clear"], in: home)
            fails(clear, with: message)
            #expect(home.bytes == before)
            #expect(home.modified == stamp)
        }
    }

    @Test("a write that fails says where, with the system's reason, and leaves the file")
    func failedWrite() throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let before = home.bytes
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.configFolder.path)
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            #expect(set.status == 1, "\(set.stderr)")
            #expect(set.stderr.hasPrefix("Error: could not save to \(home.configFile.path): "), "\(set.stderr.debugDescription)")
            #expect(set.stdout.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.configFolder.path)
            #expect(home.bytes == before)
        }
    }

    @Test("a clear whose write fails says where, with the system's reason, and leaves the file")
    func failedClear() throws {
        try withGuardedHome { home in
            try home.seed(#"{"figma": {"defaultFolder": "\#(Self.good)"}, "zz_keep": 1}"#)
            let before = home.bytes
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.configFolder.path)
            let clear = try run(["figma", "folder", "clear"], in: home)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.configFolder.path)
            #expect(clear.status == 1, "\(clear.stderr)")
            #expect(clear.stderr.hasPrefix("Error: could not save to \(home.configFile.path): "), "\(clear.stderr.debugDescription)")
            #expect(clear.stdout.isEmpty)
            #expect(home.bytes == before)
        }
    }

    // MARK: - Options and extra words

    @Test("each form refuses, by name, an option it does not take and an extra word",
          arguments: [
              (["folder", "--bogus"], "cmux figma folder does not support --bogus"),
              (["folder", "set", "--bogus", FigmaFolderCLITests.good], "cmux figma folder set does not support --bogus"),
              (["folder", "set", FigmaFolderCLITests.good, "extra"],
               "cmux figma folder set does not take an extra argument: extra"),
              (["folder", "clear", "--bogus"], "cmux figma folder clear does not support --bogus"),
              (["folder", "clear", "extra"], "cmux figma folder clear does not take an extra argument: extra")
          ])
    func refusesWhatItDoesNotTake(arguments: [String], message: String) throws {
        try withGuardedHome { home in
            try home.seed(Self.base)
            let before = home.bytes
            let result = try run(["figma"] + arguments, in: home)
            fails(result, with: message)
            #expect(home.bytes == before)
        }
    }

    // MARK: - No app

    @Test("none of the three opens a socket, and each works with nothing listening")
    func noSocket() throws {
        let socketPath = "/tmp/cmux-figfld-\(UUID().uuidString.prefix(8)).sock"
        let standIn = try StandInSocket(path: socketPath)
        defer { standIn.stop() }
        try withGuardedHome { home in
            try home.seed(Self.base)
            let commands: [[String]] = [
                ["figma", "folder"], ["figma", "folder", "set", Self.good], ["figma", "folder"],
                ["figma", "folder", "clear"], ["figma", "folder", "--json"]
            ]
            for command in commands {
                let listening = try run(command, in: home, socket: standIn)
                #expect(listening.status == 0, "\(command): \(listening.stderr)")
                #expect(listening.socketTraffic == 0, "\(command) reached the socket")
            }
            // Nothing listens: the same answers.
            try home.seed(nil)
            let read = try run(["figma", "folder"], in: home)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == Self.notSetOutput)
            let set = try run(["figma", "folder", "set", Self.good], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout == Self.setOutput)
            let clear = try run(["figma", "folder", "clear"], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == Self.clearedOutput)
        }
    }

    @Test("the stand-in socket counts a connection, so a count of zero means something")
    func standInCountsAConnection() throws {
        let socketPath = "/tmp/cmux-figfld-\(UUID().uuidString.prefix(8)).sock"
        let standIn = try StandInSocket(path: socketPath)
        defer { standIn.stop() }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for (index, byte) in socketPath.utf8.enumerated() { buffer[index] = CChar(bitPattern: byte) }
                buffer[socketPath.utf8.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        var waited = 0
        while standIn.seen == 0, waited < 200 {
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
        #expect(standIn.seen > 0, "a connection made by the test was not counted")
    }

    @Test("refusals and broken reads open no socket either, and cmux figma FOLDER takes the same early path")
    func errorsOpenNoSocket() throws {
        let socketPath = "/tmp/cmux-figfld-\(UUID().uuidString.prefix(8)).sock"
        let standIn = try StandInSocket(path: socketPath)
        defer { standIn.stop() }
        try withGuardedHome { home in
            // Each group runs against a file that reaches its own code: a file that does not
            // parse stops every command at the read, so the link refusals and the stored-value
            // errors need a valid one.
            let groups: [(seed: String, commands: [[String]])] = [
                (#"{ "figma": "#, [
                    ["figma", "folder"], ["figma", "folder", "set", Self.good], ["figma", "folder", "clear"]
                ]),
                (Self.base, [
                    ["figma", "folder", "set", Self.noTeamLink], ["figma", "folder", "set", Self.designLink],
                    ["figma", "folder", "set"], ["figma", "folder", "bogus"], ["figma", "folder", "--bogus"],
                    ["figma", "folder", "set", Self.good, "extra"], ["figma", "folder", "clear", "extra"]
                ]),
                (#"{"figma": {"defaultFolder": "\#(Self.noTeamLink)"}}"#, [["figma", "folder"]]),
                (#"{"figma": {"defaultFolder": 5}}"#, [["figma", "folder"]]),
                (#"{"figma": "x"}"#, [["figma", "folder"]])
            ]
            for group in groups {
                try home.seed(group.seed)
                for command in group.commands {
                    let result = try run(command, in: home, socket: standIn)
                    #expect(result.status == 1, "\(command) on \(group.seed): \(result.stderr)")
                    #expect(result.socketTraffic == 0, "\(command) on \(group.seed) reached the socket")
                }
            }
            try home.seed(nil)
            let upper = try run(["figma", "FOLDER"], in: home, socket: standIn)
            #expect(upper.status == 0, "\(upper.stderr)")
            #expect(upper.stdout == Self.notSetOutput, "\(upper.stdout.debugDescription)")
            #expect(upper.socketTraffic == 0)
            let withoutListener = try run(["figma", "FOLDER"], in: home)
            #expect(withoutListener.status == 0, "\(withoutListener.stderr)")
            #expect(withoutListener.stdout == Self.notSetOutput)
        }
    }

    @Test("under --json every kind of error is the same line on stderr as without it, nothing on stdout, exit 1",
          arguments: [
              ("invalid", ["figma", "folder", "--json"]),
              ("refusedStored", ["figma", "folder", "--json"]),
              ("notText", ["figma", "folder", "--json"]),
              ("figmaNotObject", ["figma", "folder", "--json"]),
              ("unreadable", ["figma", "folder", "--json"]),
              ("noTeam", ["figma", "folder", "set", "--json", FigmaFolderCLITests.noTeamLink]),
              ("design", ["figma", "folder", "set", "--json", FigmaFolderCLITests.designLink]),
              ("noURL", ["figma", "folder", "set", "--json"]),
              ("unknown", ["figma", "folder", "bogus", "--json"]),
              ("option", ["figma", "folder", "--bogus", "--json"]),
              ("extra", ["figma", "folder", "clear", "extra", "--json"]),
              ("invalidSet", ["figma", "folder", "set", "--json", FigmaFolderCLITests.good]),
              ("invalidClear", ["figma", "folder", "clear", "--json"]),
              ("setWriteFails", ["figma", "folder", "set", "--json", FigmaFolderCLITests.good]),
              ("clearWriteFails", ["figma", "folder", "clear", "--json"])
          ])
    func jsonErrors(kind: String, command: [String]) throws {
        try withGuardedHome { home in
            func seed() throws {
                switch kind {
                case "invalid", "invalidSet", "invalidClear": try home.seed(#"{ "figma": "#)
                case "refusedStored": try home.seed(#"{"figma": {"defaultFolder": "\#(Self.noTeamLink)"}}"#)
                case "notText": try home.seed(#"{"figma": {"defaultFolder": 5}}"#)
                case "figmaNotObject": try home.seed(#"{"figma": "x"}"#)
                case "unreadable": try home.seed("{}", mode: 0o000)
                case "setWriteFails", "clearWriteFails":
                    try home.seed(#"{"figma": {"defaultFolder": "\#(Self.otherGood)"}, "zz_keep": 1}"#)
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.configFolder.path)
                default: try home.seed(Self.base)
                }
            }
            func settle() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.configFolder.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.configFile.path)
            }
            try seed()
            let asJSON = try run(command, in: home)
            settle()
            try seed()
            let plain = try run(command.filter { $0 != "--json" }, in: home)
            settle()
            #expect(asJSON.status == 1, "\(kind): \(asJSON.stderr)")
            #expect(plain.status == 1, "\(kind): \(plain.stderr)")
            #expect(asJSON.stdout.isEmpty, "\(kind): \(asJSON.stdout)")
            #expect(plain.stdout.isEmpty, "\(kind): \(plain.stdout)")
            #expect(asJSON.stderr.hasPrefix("Error: "), "\(kind): \(asJSON.stderr.debugDescription)")
            #expect(asJSON.stderr == plain.stderr, "\(kind): --json changed the error line")
        }
    }

    // MARK: - The help and the parser (no binary)

    /// State 14 of `15_design-experience.md`, Interaction `#16`: the `folder` lines of `cmux figma --help`.
    private static let folderHelpLines = [
        "  folder            Print the Figma folder for this directory as projectId,",
        "                    planKey, url and directory: the folder set for the nearest",
        "                    directory that holds this one, else the default.",
        "                    Pass projectId and planKey to Figma's create_new_file.",
        "                    Works with no app running.",
        "  folder set <folder-url> [--dir <path>]",
        "                    Set the default, or with --dir the folder for that",
        "                    directory and every directory inside it. Use the link from",
        "                    Figma's address bar on the folder's page. Put the link in",
        "                    quotes: the shell reads the ? in it.",
        "  folder clear [--dir <path>]",
        "                    Remove the default, or with --dir that directory's folder.",
        "  folder list       Print every directory's folder, then the default."
    ]

    @Test("the help lists the three folder forms in the lines the brief gives")
    func helpListsTheFolderForms() {
        let lines = FigmaUsage.text.components(separatedBy: "\n")
        let expected = Self.folderHelpLines
        for line in expected { #expect(lines.contains(line), "missing help line: \(line)") }
        let start = lines.firstIndex(of: expected[0])
        #expect(start != nil)
        if let start, start + expected.count <= lines.count {
            #expect(Array(lines[start..<start + expected.count]) == expected, "the folder lines are not one run in order")
        }
    }

    @Test("the binary prints the folder help lines as one run, in order, with no app")
    func binaryPrintsTheFolderHelp() throws {
        try withGuardedHome { home in
            let result = try run(["figma", "--help"], in: home)
            #expect(result.status == 0, "\(result.stderr)")
            let lines = result.stdout.components(separatedBy: "\n")
            let expected = Self.folderHelpLines
            let start = try #require(lines.firstIndex(of: expected[0]), "\(result.stdout)")
            #expect(Array(lines[start..<min(start + expected.count, lines.count)]) == expected)
            #expect(result.stdout.hasPrefix("cmux figma\n\nUsage: cmux figma <open|goto|fit|folder> [args]\n"))
        }
    }

    @Test("the folder parser takes the three forms", arguments: [
        ([String](), FigmaFolderArguments.Action.read),
        (["set", "https://x"], .set("https://x")),
        (["SET", "https://x"], .set("https://x")),
        (["clear"], .clear)
    ])
    func parserTakesTheForms(args: [String], expected: FigmaFolderArguments.Action) throws {
        #expect(try FigmaFolderArguments.parse(args) == expected)
    }

    @Test("the folder parser refuses by name", arguments: [
        (["--bogus"], "cmux figma folder does not support --bogus"),
        (["bogus"], "unknown cmux figma folder subcommand 'bogus' (expected set, clear, list)"),
        (["https://www.figma.com/files/team/1/folder/2"],
         "unknown cmux figma folder subcommand 'https://www.figma.com/files/team/1/folder/2' (expected set, clear, list)"),
        (["set"], "cmux figma folder set requires a Figma folder URL"),
        (["set", ""], "cmux figma folder set requires a Figma folder URL"),
        (["set", "   "], "cmux figma folder set requires a Figma folder URL"),
        (["set", "--bogus", "u"], "cmux figma folder set does not support --bogus"),
        (["set", "u", "extra"], "cmux figma folder set does not take an extra argument: extra"),
        (["clear", "--bogus"], "cmux figma folder clear does not support --bogus"),
        (["clear", "extra"], "cmux figma folder clear does not take an extra argument: extra")
    ])
    func parserRefuses(args: [String], message: String) {
        #expect(throws: FigmaFolderArguments.Failure(message: message)) {
            _ = try FigmaFolderArguments.parse(args)
        }
    }
}

// MARK: - A folder per directory (cm-73.42, Scenario 372)

/// `cmux figma folder` for a directory: the fourteen states of `15_design-experience.md`,
/// Interaction `#16`, through the real binary in a throwaway home. The throwaway home holds
/// the directories the states run in; its path is resolved first (`/var` is a link to
/// `/private/var`), because the `directory` line prints the resolved path.
extension FigmaFolderCLITests {

    private static let xTeam = "764866853003674551"
    private static let xFolder = "1029384756"
    private static let linkX = "https://www.figma.com/files/team/\(xTeam)/folder/\(xFolder)"
    private static let linkXWithQuery = "\(linkX)?fuid=764866775710094844"
    private static let linkY = "https://www.figma.com/files/team/1/folder/2"

    /// The directories the states run in, all under the throwaway home, all resolved.
    private struct Stage {
        let root: String
        var a: String { root + "/a" }
        var aInner: String { root + "/a/inner" }
        var b: String { root + "/b" }
        var bInner: String { root + "/b/inner" }
        var lnA: String { root + "/ln-a" }
        var plain: String { root + "/plain" }

        init(home: FigmaFolderCLITests.Home) throws {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard realpath(home.root.path, &buffer) != nil else { throw POSIXError(.ENOENT) }
            root = String(cString: buffer)
            let fileManager = FileManager.default
            for path in [aInner, bInner, plain] {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            try fileManager.createSymbolicLink(atPath: lnA, withDestinationPath: a)
            try fileManager.createSymbolicLink(atPath: a + "/out", withDestinationPath: "../b")
        }
    }

    private func staged<T>(_ body: (Home, Stage) throws -> T) throws -> T {
        try withGuardedHome { home in try body(home, try Stage(home: home)) }
    }

    /// Writes `cmux.json` holding the default and the folders given.
    private func seedFolders(_ home: Home, default defaultLink: String? = nil, folders: Any? = nil, extra: String = "") throws {
        var figma: [String: Any] = [:]
        if let defaultLink { figma["defaultFolder"] = defaultLink }
        if let folders { figma["folders"] = folders }
        var root: [String: Any] = ["zz_keep": ["b": 2, "a": 1]]
        if !figma.isEmpty { root["figma"] = figma }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try home.seed(String(decoding: data, as: UTF8.self) + extra)
    }

    private func readText(_ link: String = linkX, projectId: String = xFolder, team: String = xTeam, directory: String) -> String {
        "projectId  \(projectId)\nplanKey    team::\(team)\nurl        \(link)\ndirectory  \(directory)\n"
    }

    private func unchanged(_ home: Home, _ before: Data?, _ stamp: Date?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(home.bytes == before, "the file's bytes changed", sourceLocation: sourceLocation)
        #expect(home.modified == stamp, "the file was rewritten", sourceLocation: sourceLocation)
    }

    // MARK: States 1 to 3: the read

    @Test("state 1: a directory's entry answers, and the directory line names its key")
    func state1EntryAnswers() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.a: Self.linkX])
            let read = try run(["figma", "folder"], in: home, directory: stage.aInner)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == readText(directory: stage.a), "\(read.stdout.debugDescription)")
            #expect(read.stderr.isEmpty, "\(read.stderr)")
        }
    }

    @Test("state 2: with no entry the default answers, and the directory line says default")
    func state2DefaultAnswers() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.a: Self.linkX])
            let read = try run(["figma", "folder"], in: home, directory: stage.bInner)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == readText(Self.good, projectId: Self.folder, team: Self.team, directory: "default"),
                    "\(read.stdout.debugDescription)")
        }
    }

    @Test("state 3: nothing answers, so three lines and exit 0")
    func state3NothingAnswers() throws {
        try staged { home, stage in
            try seedFolders(home)
            let read = try run(["figma", "folder"], in: home, directory: stage.aInner)
            #expect(read.status == 0, "\(read.stderr)")
            #expect(read.stdout == Self.notSetOutput, "\(read.stdout.debugDescription)")
            #expect(read.stderr.isEmpty)
        }
    }

    // MARK: States 4 to 6: set --dir and clear --dir

    @Test("state 4: set --dir binds the resolved directory, prints the lines, and keeps every other key and the mode")
    func state4SetDir() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            let set = try run(["figma", "folder", "set", Self.linkXWithQuery, "--dir", ".."], in: home, directory: stage.aInner)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout == """
            Figma folder set for this directory and every directory inside it.
              directory  \(stage.a)
              projectId  \(Self.xFolder)
              planKey    team::\(Self.xTeam)

            """, "\(set.stdout.debugDescription)")
            #expect(set.stderr.isEmpty)
            let root = try #require(home.object)
            let figma = try #require(root["figma"] as? [String: Any])
            #expect(figma["folders"] as? [String: String] == [stage.a: Self.linkX], "\(figma)")
            #expect(figma["defaultFolder"] as? String == Self.good)
            #expect(root["zz_keep"] as? [String: Int] == ["a": 1, "b": 2])
            #expect(home.mode == 0o600, "mode \(String(describing: home.mode))")
        }
    }

    @Test("state 4: --dir before the link, and a path through a symlink, write the same resolved key")
    func state4SetDirSpellings() throws {
        try staged { home, stage in
            try seedFolders(home)
            let first = try run(["figma", "folder", "set", "--dir", stage.lnA, Self.linkX], in: home)
            #expect(first.status == 0, "\(first.stderr)")
            #expect(first.stdout.contains("  directory  \(stage.a)\n"), "\(first.stdout.debugDescription)")
            let figma = try #require(home.object?["figma"] as? [String: Any])
            #expect(figma["folders"] as? [String: String] == [stage.a: Self.linkX])
        }
    }

    @Test("state 4: set --dir replaces a hand-written symlink key so one directory has one entry")
    func state4SetReplacesOtherSpelling() throws {
        try staged { home, stage in
            try seedFolders(home, folders: [stage.lnA: Self.linkY, stage.b: Self.linkY])
            let set = try run(["figma", "folder", "set", Self.linkX, "--dir", stage.a], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            let folders = try #require((home.object?["figma"] as? [String: Any])?["folders"] as? [String: String])
            #expect(folders == [stage.a: Self.linkX, stage.b: Self.linkY], "\(folders)")
        }
    }

    private static func bannedMessage(_ path: String) -> String {
        "cmux doesn't set a Figma folder for \(path).\n       Set it for a directory inside it."
    }

    @Test("set --dir refuses /, /Volumes and /Users: exit 1, the path, nothing written", arguments: ["/", "/Volumes", "/Users"])
    func setDirRefusesABannedDirectory(path: String) throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.a: Self.linkX])
            let before = home.bytes
            let stamp = home.modified
            fails(try run(["figma", "folder", "set", Self.linkX, "--dir", path], in: home), with: Self.bannedMessage(path))
            fails(try run(["figma", "folder", "set", "--json", Self.linkX, "--dir", path], in: home), with: Self.bannedMessage(path))
            unchanged(home, before, stamp)
        }
    }

    @Test("set --dir checks the resolved key: a symlink to /Volumes is refused, naming /Volumes")
    func setDirRefusesASymlinkToABannedDirectory() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            try FileManager.default.createSymbolicLink(atPath: stage.root + "/ln-volumes", withDestinationPath: "/Volumes")
            let before = home.bytes
            let stamp = home.modified
            fails(try run(["figma", "folder", "set", Self.linkX, "--dir", stage.root + "/ln-volumes"], in: home),
                  with: Self.bannedMessage("/Volumes"))
            unchanged(home, before, stamp)
        }
    }

    @Test("clear --dir still removes a hand-written entry for /, /Volumes or /Users", arguments: ["/", "/Volumes", "/Users"])
    func clearDirStillWorksOnABannedDirectory(path: String) throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [path: Self.linkX, stage.a: Self.linkY])
            let clear = try run(["figma", "folder", "clear", "--dir", path], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            let folders = try #require((home.object?["figma"] as? [String: Any])?["folders"] as? [String: String])
            #expect(folders == [stage.a: Self.linkY], "\(folders)")
        }
    }

    @Test("state 5: clear --dir removes that entry only and says the default now answers")
    func state5ClearDefault() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.a: Self.linkX, stage.b: Self.linkY])
            let clear = try run(["figma", "folder", "clear", "--dir", ".."], in: home, directory: stage.aInner)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == """
            Figma folder cleared.
              directory  \(stage.a)
            New designs there now go to the default Figma folder.

            """, "\(clear.stdout.debugDescription)")
            let folders = try #require((home.object?["figma"] as? [String: Any])?["folders"] as? [String: String])
            #expect(folders == [stage.b: Self.linkY], "\(folders)")
        }
    }

    @Test("state 5: clear --dir says a parent's entry answers there now")
    func state5ClearParentAnswers() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.root: Self.linkY, stage.a: Self.linkX])
            let clear = try run(["figma", "folder", "clear", "--dir", "."], in: home, directory: stage.aInner + "/..")
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout.hasSuffix("New designs there now go to the folder set for \(stage.root).\n"), "\(clear.stdout.debugDescription)")
        }
    }

    @Test("state 5: clear --dir with no default and no parent says Drafts, and the last key removes figma.folders")
    func state5ClearToDrafts() throws {
        try staged { home, stage in
            try seedFolders(home, folders: [stage.a: Self.linkX])
            let clear = try run(["figma", "folder", "clear", "--dir", stage.a], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout.hasSuffix("New designs there now go to your Figma Drafts.\n"), "\(clear.stdout.debugDescription)")
            let root = try #require(home.object)
            #expect(root["figma"] == nil, "\(root)")
            #expect(root["zz_keep"] as? [String: Int] == ["a": 1, "b": 2])
        }
    }

    @Test("state 5: clear --dir says the default now fails when a broken default is what answers")
    func state5ClearToABrokenDefault() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.noTeamLink, folders: [stage.a: Self.linkX])
            let clear = try run(["figma", "folder", "clear", "--dir", stage.a], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == """
            Figma folder cleared.
              directory  \(stage.a)
            New designs there now fail: the default Figma folder can't be used.
            See why:  cmux figma folder list

            """, "\(clear.stdout.debugDescription)")
        }
    }

    @Test("state 5: clear --dir names the parent when a broken parent entry is what answers",
          arguments: ["\"\(noTeamLink)\"", "7"])
    func state5ClearToABrokenParent(value: String) throws {
        try staged { home, stage in
            try home.seed(#"{"figma": {"defaultFolder": "\#(Self.good)", "folders": {"\#(stage.root)": \#(value), "\#(stage.a)": "\#(Self.linkX)"}}}"#)
            let clear = try run(["figma", "folder", "clear", "--dir", stage.a], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == """
            Figma folder cleared.
              directory  \(stage.a)
            New designs there now fail: the folder set for \(stage.root) can't be used.
            See why:  cmux figma folder list

            """, "\(clear.stdout.debugDescription)")
            let list = try run(["figma", "folder", "list"], in: home)
            #expect(list.stdout.hasPrefix("\(stage.root)\n  error: "), "\(list.stdout.debugDescription)")
        }
    }

    @Test("state 6: clear --dir with no entry there writes nothing")
    func state6ClearNothing() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.b: Self.linkY])
            let before = home.bytes
            let stamp = home.modified
            let clear = try run(["figma", "folder", "clear", "--dir", "."], in: home, directory: stage.aInner)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(clear.stdout == """
            No Figma folder was set for this directory. Nothing changed.
              directory  \(stage.aInner)

            """, "\(clear.stdout.debugDescription)")
            unchanged(home, before, stamp)
        }
    }

    // MARK: State 7 and 8: what answers cannot be used

    private struct BrokenEntry: Sendable, CustomTestStringConvertible {
        let name: String
        let value: String
        let reason: String
        var testDescription: String { name }
    }

    private static let brokenEntries = [
        BrokenEntry(name: "no team", value: #""\#(noTeamLink)""#, reason: "this Figma folder URL has no team in it."),
        BrokenEntry(name: "design link", value: #""\#(designLink)""#, reason: "not a Figma folder URL."),
        BrokenEntry(name: "not text", value: "7", reason: "it is not text."),
        BrokenEntry(name: "null", value: "null", reason: "it is not text.")
    ]

    @Test("state 7: the entry that answers cannot be used: exit 1, the reason, the key, the fix, and nothing skipped",
          arguments: brokenEntries)
    private func state7BrokenEntry(_ entry: BrokenEntry) throws {
        try staged { home, stage in
            // A usable parent and a usable default sit behind the broken entry and must not be used.
            try home.seed(#"{"figma": {"defaultFolder": "\#(Self.good)", "folders": {"\#(stage.root)": "\#(Self.linkY)", "\#(stage.a)": \#(entry.value)}}}"#)
            let before = home.bytes
            let stamp = home.modified
            for arguments in [["figma", "folder"], ["figma", "folder", "--json"]] {
                let read = try run(arguments, in: home, directory: stage.aInner)
                fails(read, with: """
                this directory's Figma folder in cmux.json is not a URL cmux can use:
                       \(entry.reason)
                       Set for:  \(stage.a)
                       Fix it:   cmux figma folder set <folder-url> --dir \(stage.a)
                """)
            }
            unchanged(home, before, stamp)
        }
    }

    @Test("state 8: figma.folders that is not an object: exit 1 and the fix", arguments: ["5", #""text""#, "[1]", "true"])
    func state8FoldersNotObject(value: String) throws {
        try staged { home, stage in
            try home.seed(#"{"figma": {"defaultFolder": "\#(Self.good)", "folders": \#(value)}}"#)
            let before = home.bytes
            let stamp = home.modified
            let read = try run(["figma", "folder"], in: home, directory: stage.aInner)
            fails(read, with: """
            figma.folders in cmux.json is not an object.
                   Fix it:  cmux figma folder set <folder-url> --dir <directory>
            """)
            unchanged(home, before, stamp)
        }
    }

    @Test("state 8: set --dir writes over a figma.folders that is not an object")
    func state8SetOverNonObject() throws {
        try staged { home, stage in
            try home.seed(#"{"figma": {"defaultFolder": "\#(Self.good)", "folders": 5}}"#)
            let set = try run(["figma", "folder", "set", Self.linkX, "--dir", stage.a], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            let figma = try #require(home.object?["figma"] as? [String: Any])
            #expect(figma["folders"] as? [String: String] == [stage.a: Self.linkX])
        }
    }

    // MARK: States 9 and 10: list

    @Test("state 9: list prints every entry sorted, a bad one as its error, then the default")
    func state9List() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.b: Self.linkX, stage.a: Self.noTeamLink, stage.plain: 7] as [String: Any])
            let list = try run(["figma", "folder", "list"], in: home, directory: stage.aInner)
            #expect(list.status == 0, "\(list.stderr)")
            #expect(list.stdout == """
            \(stage.a)
              error: this Figma folder URL has no team in it.
            \(stage.b)
              \(Self.linkX)
            \(stage.plain)
              error: it is not text.
            default
              \(Self.good)

            """, "\(list.stdout.debugDescription)")
        }
    }

    @Test("state 9: list under default shows not set, or the default's error")
    func state9ListDefaultLines() throws {
        try staged { home, stage in
            try seedFolders(home, folders: [stage.a: Self.linkX])
            let notSet = try run(["figma", "folder", "list"], in: home)
            #expect(notSet.stdout == "\(stage.a)\n  \(Self.linkX)\ndefault\n  not set\n", "\(notSet.stdout.debugDescription)")
            try seedFolders(home, default: Self.noTeamLink, folders: [stage.a: Self.linkX])
            let broken = try run(["figma", "folder", "list"], in: home)
            #expect(broken.status == 0, "\(broken.stderr)")
            #expect(broken.stdout == "\(stage.a)\n  \(Self.linkX)\ndefault\n  error: this Figma folder URL has no team in it.\n",
                    "\(broken.stdout.debugDescription)")
        }
    }

    private static let notAFullPath = "this is not a full path, so it matches no directory."

    @Test("list marks a key that is not a full path as matching nothing, plain and --json", arguments: ["relative/x", "$HOME/x", "~other/x", "./x"])
    func listMarksAKeyThatCanNeverMatch(key: String) throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [key: Self.linkX, stage.a: Self.linkX] as [String: Any])
            let list = try run(["figma", "folder", "list"], in: home)
            #expect(list.status == 0, "\(list.stderr)")
            let lines = list.stdout.components(separatedBy: "\n")
            let at = try #require(lines.firstIndex(of: key), "\(list.stdout.debugDescription)")
            #expect(lines[at + 1] == "  error: \(Self.notAFullPath)", "\(list.stdout.debugDescription)")
            #expect(list.stdout.contains("\(stage.a)\n  \(Self.linkX)\n"), "a full path still lists its link")

            let asJSON = try run(["figma", "folder", "list", "--json"], in: home)
            #expect(asJSON.status == 0, "\(asJSON.stderr)")
            let folders = try #require(json(asJSON.stdout)?["folders"] as? [[String: Any]])
            let row = try #require(folders.first { $0["directory"] as? String == key })
            #expect(NSDictionary(dictionary: row).isEqual(to: ["directory": key, "error": Self.notAFullPath]), "\(row)")
        }
    }

    @Test("list does not mark ~ or ~/x or an absolute key as not a full path")
    func listKeepsFullPathKeys() throws {
        try staged { home, stage in
            try seedFolders(home, folders: ["~": Self.linkX, "~/proj": Self.linkX, stage.a: Self.linkX] as [String: Any])
            let list = try run(["figma", "folder", "list"], in: home)
            #expect(!list.stdout.contains(Self.notAFullPath), "\(list.stdout.debugDescription)")
        }
    }

    @Test("state 10: list with nothing set")
    func state10ListNothing() throws {
        try staged { home, stage in
            try seedFolders(home)
            let list = try run(["figma", "folder", "list"], in: home)
            #expect(list.status == 0, "\(list.stderr)")
            #expect(list.stdout == """
            No Figma folders set. New designs go to your Figma Drafts.
            Set one:  cmux figma folder set <folder-url>
            Or for this directory only:  cmux figma folder set <folder-url> --dir .

            """, "\(list.stdout.debugDescription)")
        }
    }

    // MARK: States 11 to 13: refusals leave the file alone

    @Test("state 11: --dir names no existing directory: exit 1, the absolute path, nothing written")
    func state11NotADirectory() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            let before = home.bytes
            let stamp = home.modified
            let set = try run(["figma", "folder", "set", Self.linkX, "--dir", "./nope"], in: home, directory: stage.aInner)
            fails(set, with: "not a directory: \(stage.aInner)/nope")
            let clear = try run(["figma", "folder", "clear", "--dir", "./nope"], in: home, directory: stage.aInner)
            fails(clear, with: "not a directory: \(stage.aInner)/nope")
            // A file is not a directory either.
            try Data("x".utf8).write(to: URL(fileURLWithPath: stage.root + "/afile"))
            let file = try run(["figma", "folder", "set", Self.linkX, "--dir", stage.root + "/afile"], in: home)
            fails(file, with: "not a directory: \(stage.root)/afile")
            unchanged(home, before, stamp)
        }
    }

    @Test("state 12: --dir with no path: exit 1")
    func state12DirNeedsAPath() throws {
        try staged { home, stage in
            try seedFolders(home)
            let before = home.bytes
            for arguments in [["set", Self.linkX, "--dir"], ["clear", "--dir"]] {
                let result = try run(["figma", "folder"] + arguments, in: home)
                fails(result, with: "--dir requires a directory")
            }
            unchanged(home, before, home.modified)
        }
    }

    @Test("state 13: an unknown word names set, clear and list")
    func state13UnknownWord() throws {
        try staged { home, stage in
            try seedFolders(home)
            let result = try run(["figma", "folder", "bogus"], in: home)
            fails(result, with: "unknown cmux figma folder subcommand 'bogus' (expected set, clear, list)")
        }
    }

    @Test("--dir on the read or on list, and an extra word on list, are refused by name")
    func dirRefusals() throws {
        try staged { home, stage in
            try seedFolders(home)
            fails(try run(["figma", "folder", "--dir", "."], in: home), with: "cmux figma folder does not support --dir")
            fails(try run(["figma", "folder", "list", "--dir", "."], in: home), with: "cmux figma folder list does not support --dir")
            fails(try run(["figma", "folder", "list", "extra"], in: home), with: "cmux figma folder list does not take an extra argument: extra")
        }
    }

    // MARK: --json

    @Test("--json: the read, set --dir, clear --dir and list print the documents Interaction #16 gives")
    func jsonDocuments() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            let set = try run(["figma", "folder", "set", Self.linkX, "--dir", stage.a, "--json"], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            let setDocument: [String: Any] = [
                "folder": ["project_id": Self.xFolder, "plan_key": "team::\(Self.xTeam)", "url": Self.linkX, "directory": stage.a]
            ]
            #expect(NSDictionary(dictionary: json(set.stdout) ?? [:]).isEqual(to: setDocument), "\(set.stdout)")

            let read = try run(["figma", "folder", "--json"], in: home, directory: stage.aInner)
            let readDocument: [String: Any] = [
                "default_folder": ["project_id": Self.folder, "plan_key": "team::\(Self.team)", "url": Self.good],
                "folder": ["project_id": Self.xFolder, "plan_key": "team::\(Self.xTeam)", "url": Self.linkX, "directory": stage.a]
            ]
            #expect(NSDictionary(dictionary: json(read.stdout) ?? [:]).isEqual(to: readDocument), "\(read.stdout)")

            let list = try run(["figma", "folder", "list", "--json"], in: home)
            let listDocument: [String: Any] = [
                "folders": [["directory": stage.a, "project_id": Self.xFolder, "plan_key": "team::\(Self.xTeam)", "url": Self.linkX]],
                "default_folder": ["project_id": Self.folder, "plan_key": "team::\(Self.team)", "url": Self.good]
            ]
            #expect(NSDictionary(dictionary: json(list.stdout) ?? [:]).isEqual(to: listDocument), "\(list.stdout)")

            let clear = try run(["figma", "folder", "clear", "--dir", stage.a, "--json"], in: home)
            let clearDocument: [String: Any] = ["folder": NSNull(), "directory": stage.a]
            #expect(NSDictionary(dictionary: json(clear.stdout) ?? [:]).isEqual(to: clearDocument), "\(clear.stdout)")
        }
    }

    @Test("--json: the default answers with directory null; an entry answers even when the default is broken")
    func jsonDefaultAndBrokenDefault() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            let defaultAnswers = try run(["figma", "folder", "--json"], in: home, directory: stage.bInner)
            let folder = json(defaultAnswers.stdout)?["folder"] as? [String: Any]
            #expect(folder?["directory"] is NSNull, "\(defaultAnswers.stdout)")
            #expect(folder?["project_id"] as? String == Self.folder)

            try seedFolders(home, default: Self.noTeamLink, folders: [stage.a: Self.linkX])
            let entryAnswers = try run(["figma", "folder", "--json"], in: home, directory: stage.aInner)
            #expect(entryAnswers.status == 0, "\(entryAnswers.stderr)")
            let document = json(entryAnswers.stdout)
            #expect((document?["default_folder"] as? [String: Any])?["error"] as? String == "this Figma folder URL has no team in it.",
                    "\(entryAnswers.stdout)")
            #expect((document?["folder"] as? [String: Any])?["directory"] as? String == stage.a)

            let defaultBroken = try run(["figma", "folder", "--json"], in: home, directory: stage.bInner)
            #expect(defaultBroken.status == 1)
            #expect(defaultBroken.stdout.isEmpty, "\(defaultBroken.stdout)")
        }
    }

    @Test("--json: list with nothing set, and a read that nothing answers")
    func jsonNothingSet() throws {
        try staged { home, stage in
            try seedFolders(home)
            let list = try run(["figma", "folder", "list", "--json"], in: home)
            let document = json(list.stdout)
            #expect((document?["folders"] as? [Any])?.isEmpty == true, "\(list.stdout)")
            #expect(document?["default_folder"] is NSNull, "\(list.stdout)")
        }
    }

    // MARK: Symlinks, $PWD and /tmp

    @Test("a read from inside a symlink answers the target's entry, naming the resolved path")
    func readThroughSymlink() throws {
        try staged { home, stage in
            try seedFolders(home, folders: [stage.a: Self.linkX])
            let read = try run(["figma", "folder"], in: home, directory: stage.lnA + "/inner")
            #expect(read.stdout == readText(directory: stage.a), "\(read.stdout.debugDescription)")
        }
    }

    @Test("the shell form: with $PWD through a symlink the entry answers; without it, or with a $PWD that resolves elsewhere, the default does")
    func shellForm() throws {
        try staged { home, stage in
            try seedFolders(home, default: Self.good, folders: [stage.a: Self.linkX])
            let through = stage.a + "/out/inner"
            let withPwd = try run(["figma", "folder"], in: home, directory: through, pwd: through)
            #expect(withPwd.stdout == readText(directory: stage.a), "\(withPwd.stdout.debugDescription)")
            for pwd in [nil, stage.plain, "relative", stage.root + "/gone"] as [String?] {
                let read = try run(["figma", "folder"], in: home, directory: through, pwd: pwd)
                #expect(read.stdout.hasSuffix("directory  default\n"), "pwd \(String(describing: pwd)): \(read.stdout.debugDescription)")
            }
        }
    }

    @Test("a directory under /tmp is keyed /private/tmp/..., and the directory line prints that key byte for byte")
    func tmpDirectoryKeyEqualsPrintedDirectory() throws {
        let name = "cm-73.42-cli-\(UUID().uuidString.prefix(8))"
        let spelled = "/tmp/\(name)"
        try FileManager.default.createDirectory(atPath: spelled + "/inner", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: spelled) }
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            let set = try run(["figma", "folder", "set", Self.linkX, "--dir", spelled], in: home)
            #expect(set.status == 0, "\(set.stderr)")
            #expect(set.stdout.contains("  directory  /private/tmp/\(name)\n"), "\(set.stdout.debugDescription)")
            let stored = try #require((home.object?["figma"] as? [String: Any])?["folders"] as? [String: String])
            #expect(Array(stored.keys) == ["/private/tmp/\(name)"], "\(stored)")

            // The shell form is /tmp/..., the resolved form is /private/tmp/...: both read the stored key.
            for pwd in [nil, spelled + "/inner"] as [String?] {
                let read = try run(["figma", "folder"], in: home, directory: spelled + "/inner", pwd: pwd)
                #expect(read.stdout.hasSuffix("directory  \(try #require(stored.keys.first))\n"), "pwd \(String(describing: pwd)): \(read.stdout.debugDescription)")
            }
            let list = try run(["figma", "folder", "list"], in: home)
            #expect(list.stdout.hasPrefix("\(try #require(stored.keys.first))\n"), "\(list.stdout.debugDescription)")
            let clear = try run(["figma", "folder", "clear", "--dir", spelled], in: home)
            #expect(clear.status == 0, "\(clear.stderr)")
            #expect(home.object?["figma"] as? [String: Any] != nil)
            #expect(((home.object?["figma"] as? [String: Any])?["folders"]) == nil)
        }
    }

    @Test("the three folder forms for a directory open no socket")
    func perDirectoryFormsOpenNoSocket() throws {
        let socketPath = "/tmp/cmux-figfld-\(UUID().uuidString.prefix(8)).sock"
        let standIn = try StandInSocket(path: socketPath)
        defer { standIn.stop() }
        try staged { home, stage in
            try seedFolders(home, default: Self.good)
            for command in [
                ["figma", "folder", "set", Self.linkX, "--dir", stage.a], ["figma", "folder", "list"],
                ["figma", "folder"], ["figma", "folder", "clear", "--dir", stage.a]
            ] {
                let result = try run(command, in: home, directory: stage.aInner, socket: standIn)
                #expect(result.status == 0, "\(command): \(result.stderr)")
                #expect(result.socketTraffic == 0, "\(command) reached the socket")
            }
        }
    }
}
