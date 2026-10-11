import CmuxSettings
import Foundation
import Testing

/// The default-folder link check (`FigmaFolderLink`) and the strict read of
/// `figma.defaultFolder` (`JSONConfigStore.strictRoot()` and
/// `FigmaDefaultFolder(root:)`), which Settings, `cmux figma folder` and a
/// hand-edited `cmux.json` all go through.
///
/// **One answer per link.** The check is one ordered rule of seven steps and
/// the first step that answers is the answer. The cases are grouped by the step
/// that answers, and a refusal is held to its reason, not only to being a
/// refusal. The inputs are exact; the folder `643299150` and the team
/// `764866853003674551` are measured ones.
@Suite("FigmaDefaultFolder")
struct FigmaDefaultFolderTests {

    // MARK: - Link check

    private static let team = "764866853003674551"
    private static let folder = "643299150"
    private static let addressBar = "\(good)?fuid=764866775710094844"
    private static let noTeamLink = "https://www.figma.com/files/folder/\(folder)"
    private static let designLink = "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73"
    private static let good = "https://www.figma.com/files/team/\(team)/folder/\(folder)"

    private enum Expected: Sendable, Equatable {
        case pass(projectId: String, planKey: String, url: String)
        case noTeam
        case notAFolderLink
    }

    private struct LinkCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let expected: Expected
        var testDescription: String { name }
    }

    /// A pass with Tom's measured ids and the trimmed link `url`.
    private static func passes(_ name: String, _ input: String, url: String = good) -> LinkCase {
        LinkCase(
            name: name,
            input: input,
            expected: .pass(projectId: folder, planKey: "team::\(team)", url: url)
        )
    }

    private static func noTeam(_ input: String) -> LinkCase { LinkCase(name: input, input: input, expected: .noTeam) }
    private static func refused(_ input: String) -> LinkCase {
        LinkCase(name: input, input: input, expected: .notAFolderLink)
    }

    private func verify(_ link: LinkCase) {
        let result = FigmaFolderLink.check(link.input)
        switch (link.expected, result) {
        case (.pass(let projectId, let planKey, let url), .success(let found)):
            #expect(found.projectId == projectId, "projectId of \(link.name)")
            #expect(found.planKey == planKey, "planKey of \(link.name)")
            #expect(found.url == url, "trimmed link of \(link.name)")
        case (.noTeam, .failure(let refusal)):
            #expect(refusal == .noTeam, "\(link.name)")
        case (.notAFolderLink, .failure(let refusal)):
            #expect(refusal == .notAFolderLink, "\(link.name)")
        default:
            Issue.record("\(link.name): expected \(link.expected), got \(result)")
        }
    }

    // Step 4 (and the steps before it that a pass crosses).

    private static let step4Passes: [LinkCase] = [
        passes("address bar link with fuid", "\(good)?fuid=764866775710094844"),
        passes(
            "project word kept",
            "https://www.figma.com/files/team/\(team)/project/\(folder)",
            url: "https://www.figma.com/files/team/\(team)/project/\(folder)"
        ),
        passes("trailing name segment", "\(good)/rb-ephemeral-agents"),
        passes("trailing slash", "\(good)/"),
        passes(
            "no www",
            "https://figma.com/files/team/\(team)/folder/\(folder)",
            url: "https://figma.com/files/team/\(team)/folder/\(folder)"
        ),
        passes("upper-case scheme", "HTTPS://www.figma.com/files/team/\(team)/folder/\(folder)"),
        passes("upper-case host", "https://WWW.FIGMA.COM/files/team/\(team)/folder/\(folder)"),
        passes("upper-case scheme and host", "HTTPS://WWW.FIGMA.COM/files/team/\(team)/folder/\(folder)"),
        passes("hash part", "\(good)#frame"),
        LinkCase(
            name: "guard sentinel",
            input: "https://www.figma.com/files/team/1/folder/2",
            expected: .pass(
                projectId: "2",
                planKey: "team::1",
                url: "https://www.figma.com/files/team/1/folder/2"
            )
        )
    ]

    @Test("step 4: the team form passes", arguments: step4Passes)
    private func step4(_ link: LinkCase) { verify(link) }

    // Step 1.

    private static let step1Passes: [LinkCase] = [
        passes("spaces around", "  \(good)  "),
        passes("tab each side", "\t\(good)\t"),
        passes("line break after only", "\(good)\n"),
        passes("line break before only", "\n\(good)"),
        passes("carriage return and line break around", "\r\n\(good)\r\n")
    ]

    @Test("step 1: spaces, tabs and line breaks are stripped from both ends", arguments: step1Passes)
    private func step1(_ link: LinkCase) { verify(link) }

    // What follows the folder id is not read.

    private static let tailPasses: [LinkCase] = [
        passes("percent-encoded folder name", "\(good)/rb%20-%20ephemeral%20-%20agents"),
        passes("dot-dot after the folder id", "\(good)/../x"),
        passes("backslash after the slash", "\(good)/a\\b"),
        passes("doubled slash after the folder id", "\(good)//x")
    ]

    @Test("step 4: what comes after the folder id is not read", arguments: tailPasses)
    private func tail(_ link: LinkCase) { verify(link) }

    // Step 6.

    private static let step6NoTeam: [LinkCase] = [
        noTeam("https://www.figma.com/files/folder/\(folder)"),
        noTeam("https://www.figma.com/files/folder/\(folder)/rb-ephemeral-agents"),
        noTeam("https://www.figma.com/files/project/\(folder)"),
        noTeam("https://www.figma.com/files/\(team)/project/\(folder)"),
        noTeam("https://www.figma.com/files/1234567890/folder/\(folder)"),
        noTeam("https://www.figma.com/files/folder/\(folder)?fuid=764866775710094844")
    ]

    @Test("step 6: a folder link with no team is refused as no team", arguments: step6NoTeam)
    private func step6(_ link: LinkCase) { verify(link) }

    // Step 5.

    private static let step5Refused: [LinkCase] = [
        refused("https://www.figma.com/files/team/abc/folder/\(folder)"),
        refused("https://www.figma.com/files/team/\(team)//folder/\(folder)"),
        refused("https://www.figma.com/files/team/\(team)/folder/6432x"),
        refused("https://www.figma.com/files/team/\(team)/folder/6432%39150"),
        refused("https://www.figma.com/files/team/\(team)/folder/\(folder)\\x"),
        refused("https://www.figma.com/files/team/\(team)/folder/abc"),
        refused("https://www.figma.com/files/team/\(team)/folder/"),
        refused("https://www.figma.com/files/team/\(team)"),
        refused("https://www.figma.com/files/team/٧٦٤٨٦٦٨٥٣٠٠٣٦٧٤٥٥١/folder/\(folder)"),
        refused("https://www.figma.com/files/team/\(team)/folder/٦٤٣٢٩٩١٥٠"),
        refused("https://www.figma.com/files/team/\(team)/Folder/\(folder)")
    ]

    @Test("step 5: a path that starts /files/team/ and is not the team form is not a folder link",
          arguments: step5Refused)
    private func step5(_ link: LinkCase) { verify(link) }

    // Step 7.

    private static let step7Refused: [LinkCase] = [
        refused("https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73"),
        refused("https://www.figma.com/Files/Team/\(team)/folder/\(folder)"),
        refused("https://www.figma.com/files/folder/6432x"),
        refused("https://www.figma.com/files/folder/٦٤٣٢٩٩١٥٠"),
        refused("https://www.figma.com/files/643folder/5"),
        refused("https://www.figma.com/files/folder/"),
        refused("https://www.figma.com"),
        refused("https://www.figma.com?next=/files/team/\(team)/folder/\(folder)"),
        refused("https://www.figma.com#/files/team/\(team)/folder/\(folder)"),
        refused(""),
        refused("     ")
    ]

    @Test("step 7: anything else is not a folder link", arguments: step7Refused)
    private func step7(_ link: LinkCase) { verify(link) }

    // Step 2: refused whatever the path.

    private static func hostRefused(_ prefix: String) -> LinkCase {
        refused("\(prefix)/files/team/\(team)/folder/\(folder)")
    }

    private static let step2Refused: [LinkCase] = [
        hostRefused("https://example.com"),
        hostRefused("https://evilfigma.com"),
        hostRefused("https://x.figma.com"),
        hostRefused("https://www.figma.com.example.com"),
        hostRefused("https://www.figma.com:8443"),
        hostRefused("https://user@www.figma.com"),
        hostRefused("https://user:pw@www.figma.com"),
        hostRefused("http://www.figma.com"),
        hostRefused("https:/www.figma.com"),
        hostRefused("ftp://www.figma.com"),
        hostRefused("https://embed.figma.com"),
        // A no-team path that would answer "no team" if step 2 did not answer first.
        refused("http://www.figma.com/files/folder/\(folder)"),
        refused("https://example.com/files/folder/\(folder)")
    ]

    @Test("step 2: another scheme or host is not a folder link, whatever the path", arguments: step2Refused)
    private func step2(_ link: LinkCase) { verify(link) }

    // MARK: - Whole-set properties

    @Test("every stored link passes the check and trims to itself")
    func roundTrip() throws {
        let passing = Self.step4Passes + Self.step1Passes + Self.tailPasses
        for link in passing {
            guard case .success(let first) = FigmaFolderLink.check(link.input) else {
                Issue.record("\(link.name) did not pass")
                continue
            }
            guard case .success(let again) = FigmaFolderLink.check(first.url) else {
                Issue.record("the stored link of \(link.name) did not pass: \(first.url)")
                continue
            }
            #expect(again == first, "\(link.name)")
        }
    }

    @Test("a refusal carries no folder id, plan key or trimmed link")
    func refusalCarriesNoIds() {
        let refusals = Self.step6NoTeam + Self.step5Refused + Self.step7Refused + Self.step2Refused
        for link in refusals {
            if case .success(let found) = FigmaFolderLink.check(link.input) {
                Issue.record("\(link.name) passed as \(found)")
            }
        }
    }

    /// `CLI/FigmaFileLink.swift` holds the same rule for file links and warns
    /// that two such lists drifted apart once. Each host goes inside the path
    /// its own check needs; the two must give the same answer.
    @Test("the folder check and FigmaFileLink.isEditorLink agree on every host",
          arguments: [
              ("www.figma.com", true), ("figma.com", true), ("WWW.FIGMA.COM", true),
              ("example.com", false), ("evilfigma.com", false), ("x.figma.com", false),
              ("www.figma.com:8443", false), ("user@www.figma.com", false),
              ("www.figma.com.example.com", false), ("embed.figma.com", false)
          ])
    func hostRuleAgrees(host: String, accepted: Bool) throws {
        let folder: Bool
        if case .success = FigmaFolderLink.check("https://\(host)/files/team/1/folder/2") {
            folder = true
        } else {
            folder = false
        }
        let editor = FigmaFileLink.isEditorLink(try #require(URL(string: "https://\(host)/design/KEY/slug")))
        #expect(folder == editor, "\(host): folder check \(folder), isEditorLink \(editor)")
        #expect(folder == accepted, "\(host): folder check \(folder), expected \(accepted)")
    }

    // MARK: - The strict read (Scenario 5)

    private struct FileCase: Sendable, CustomTestStringConvertible {
        let name: String
        /// `nil` means no `cmux.json` at all.
        let contents: String?
        var testDescription: String { name }
    }

    private static func withHome<T>(_ body: (URL, URL) throws -> T) throws -> T {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("FigmaDefaultFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".config/cmux/cmux.json")
        return try body(home, file)
    }

    private static func seed(_ file: URL, _ contents: String?) throws {
        guard let contents else { return }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
    }

    private static func read(_ file: URL) throws -> FigmaDefaultFolder.State {
        let root = try JSONConfigStore(fileURL: file).strictRoot()
        return FigmaDefaultFolder(root: root).state
    }

    private static let notSetFiles: [FileCase] = [
        FileCase(name: "no cmux.json", contents: nil),
        FileCase(name: "no figma key", contents: #"{"app": {"appearance": "dark"}}"#),
        FileCase(name: "{}", contents: "{}"),
        FileCase(name: "empty file", contents: ""),
        FileCase(name: #""figma": {}"#, contents: #"{"figma": {}}"#),
        FileCase(name: #""figma": null"#, contents: #"{"figma": null}"#),
        FileCase(name: "defaultFolder null", contents: #"{"figma": {"defaultFolder": null}}"#),
        FileCase(name: "defaultFolder empty", contents: #"{"figma": {"defaultFolder": ""}}"#),
        FileCase(name: "defaultFolder spaces only", contents: #"{"figma": {"defaultFolder": "   "}}"#)
    ]

    @Test("the strict read gives not set, and not an error", arguments: notSetFiles)
    private func notSet(_ file: FileCase) throws {
        try Self.withHome { _, url in
            try Self.seed(url, file.contents)
            #expect(try Self.read(url) == .notSet, "\(file.name)")
        }
    }

    @Test("a file with a comment and a good link reads as set, not broken")
    func commentIsNotBroken() throws {
        try Self.withHome { _, url in
            try Self.seed(url, """
            // note
            {
              /* block */
              "figma": { "defaultFolder": "\(Self.good)", },
            }
            """)
            guard case .set(let link) = try Self.read(url) else {
                Issue.record("expected set")
                return
            }
            #expect(link.projectId == Self.folder)
            #expect(link.planKey == "team::\(Self.team)")
        }
    }

    private static let notValidJSONFiles: [FileCase] = [
        FileCase(name: "truncated object", contents: #"{ "figma": "#),
        FileCase(name: "top level array", contents: "[1]"),
        FileCase(name: "top level string", contents: #""x""#),
        FileCase(name: "unterminated block comment", contents: "/* {}"),
        FileCase(name: "spaces and a line break only", contents: "  \n"),
        FileCase(name: "one line break only", contents: "\n")
    ]

    @Test("a file that is not valid JSON, or not an object, is an error and not 'not set'",
          arguments: notValidJSONFiles)
    private func notValidJSON(_ file: FileCase) throws {
        try Self.withHome { _, url in
            try Self.seed(url, file.contents)
            #expect(throws: JSONConfigStoreStrictReadError.notValidJSON, "\(file.name)") {
                _ = try JSONConfigStore(fileURL: url).strictRoot()
            }
        }
    }

    @Test("a file the process cannot open is an error carrying the system's reason")
    func unreadableFile() throws {
        try Self.withHome { _, url in
            try Self.seed(url, "{}")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            do {
                _ = try JSONConfigStore(fileURL: url).strictRoot()
                Issue.record("expected an error")
            } catch let error as JSONConfigStoreStrictReadError {
                guard case .unreadable(let reason) = error else {
                    Issue.record("expected unreadable, got \(error)")
                    return
                }
                #expect(!reason.isEmpty)
            }
        }
    }

    private static let notTextFiles: [FileCase] = [
        FileCase(name: #""figma": "x""#, contents: #"{"figma": "x"}"#),
        FileCase(name: #""figma": []"#, contents: #"{"figma": []}"#),
        FileCase(name: "defaultFolder 5", contents: #"{"figma": {"defaultFolder": 5}}"#),
        FileCase(name: "defaultFolder true", contents: #"{"figma": {"defaultFolder": true}}"#),
        FileCase(name: "defaultFolder []", contents: #"{"figma": {"defaultFolder": []}}"#),
        FileCase(name: "defaultFolder {}", contents: #"{"figma": {"defaultFolder": {}}}"#)
    ]

    @Test("a figma that is not an object, or a value that is not text, reads as not text",
          arguments: notTextFiles)
    private func notText(_ file: FileCase) throws {
        try Self.withHome { _, url in
            try Self.seed(url, file.contents)
            #expect(try Self.read(url) == .notText, "\(file.name)")
        }
    }

    @Test("a stored link that does not pass reads as refused, with its reason")
    func storedLinkRefused() throws {
        try Self.withHome { _, url in
            try Self.seed(url, #"{"figma": {"defaultFolder": "https://www.figma.com/files/folder/643299150"}}"#)
            #expect(try Self.read(url) == .refused(.noTeam))
            try Self.seed(url, #"{"figma": {"defaultFolder": "https://www.figma.com/design/KEY/cm-73"}}"#)
            #expect(try Self.read(url) == .refused(.notAFolderLink))
        }
    }

    @Test("a stored link that passes reads as set, as stored")
    func storedLinkSet() throws {
        try Self.withHome { _, url in
            try Self.seed(url, #"{"figma": {"defaultFolder": "\#(Self.good)"}}"#)
            guard case .set(let link) = try Self.read(url) else {
                Issue.record("expected set")
                return
            }
            #expect(link.url == Self.good)
        }
    }

    @Test("reading creates no file, and changes neither the bytes nor the modified time of one")
    func readingWritesNothing() throws {
        try Self.withHome { home, url in
            _ = try Self.read(url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

            try Self.seed(url, "// keep me\n{\"figma\": {\"defaultFolder\": \"\(Self.good)\"}}")
            let before = try Data(contentsOf: url)
            let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            _ = try Self.read(url)
            #expect(try Data(contentsOf: url) == before)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == stamp)
            _ = home
        }
    }

    @Test("a stored link with a query or a tail reads back trimmed")
    func storedLinkReadsTrimmed() throws {
        try Self.withHome { _, url in
            try Self.seed(url, #"{"figma": {"defaultFolder": "https://www.figma.com/files/team/1/folder/2?fuid=9"}}"#)
            guard case .set(let link) = try Self.read(url) else {
                Issue.record("expected set")
                return
            }
            #expect(link.url == "https://www.figma.com/files/team/1/folder/2")
        }
    }

    // MARK: - What clear writes

    private struct ClearCase: Sendable, CustomTestStringConvertible {
        let json: String
        let state: FigmaDefaultFolder.State
        let action: FigmaDefaultFolder.ClearAction
        var testDescription: String { json }
    }

    /// The link the check makes for `url`; tests never build one by hand.
    private static func link(_ url: String) -> FigmaFolderLink {
        // swiftlint:disable:next force_try
        try! FigmaFolderLink.check(url).get()
    }

    private static let clearCases: [ClearCase] = [
        ClearCase(json: "{}", state: .notSet, action: .nothing),
        ClearCase(json: #"{"figma": null}"#, state: .notSet, action: .nothing),
        ClearCase(json: #"{"figma": {}}"#, state: .notSet, action: .nothing),
        ClearCase(json: #"{"figma": {"other": 1}}"#, state: .notSet, action: .nothing),
        ClearCase(json: #"{"figma": {"defaultFolder": null}}"#, state: .notSet, action: .removeKey),
        ClearCase(json: #"{"figma": {"defaultFolder": ""}}"#, state: .notSet, action: .removeKey),
        ClearCase(json: #"{"figma": {"defaultFolder": "   "}}"#, state: .notSet, action: .removeKey),
        ClearCase(json: #"{"figma": {"defaultFolder": 5}}"#, state: .notText, action: .removeKey),
        ClearCase(json: #"{"figma": {"defaultFolder": "https://www.figma.com/files/folder/1"}}"#,
                  state: .refused(.noTeam), action: .removeKey),
        ClearCase(json: #"{"figma": {"defaultFolder": "https://www.figma.com/files/team/1/folder/2"}}"#,
                  state: .set(link("https://www.figma.com/files/team/1/folder/2")),
                  action: .removeKey),
        ClearCase(json: #"{"figma": "x"}"#, state: .notText, action: .removeFigma),
        ClearCase(json: #"{"figma": 7}"#, state: .notText, action: .removeFigma),
        ClearCase(json: #"{"figma": [1]}"#, state: .notText, action: .removeFigma),
        ClearCase(json: #"{"figma": true}"#, state: .notText, action: .removeFigma)
    ]

    @Test("the state and what clear writes, for every shape of the key", arguments: clearCases)
    private func stateAndClearAction(_ testCase: ClearCase) throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(testCase.json.utf8)) as? [String: Any]
        )
        let folder = FigmaDefaultFolder(root: root)
        #expect(folder.state == testCase.state)
        #expect(folder.clearAction == testCase.action)
    }

    // MARK: - The Settings row's decisions, as sequences

    private typealias Row = FigmaDefaultFolderRowState

    private static func row(stored: String, typed draft: String? = nil) -> Row {
        var row = Row(stored: stored)
        if let draft { row.draft = draft }
        return row
    }

    @Test("Return on a good link asks for a write, and the row turns only when the store confirms")
    func returnWritesThenTurnsOnConfirm() {
        var row = Self.row(stored: "", typed: Self.addressBar)
        #expect(row.commit(stored: "") == .write(Self.good))
        #expect(row.draft == Self.good, "the field shows the trimmed link at once")
        #expect(row.subtitle(stored: "") == .notSet, "still describes what is stored")
        #expect(row.openLink(stored: "") == nil)
        row.storedChanged(to: Self.good, isFocused: true)
        #expect(row.subtitle(stored: Self.good) == .set(folderId: Self.folder))
        #expect(row.openLink(stored: Self.good) == URL(string: Self.good))
        #expect(!row.hasUnsavedDraft)
    }

    @Test("a write that fails never turns the subtitle or shows the link, and Return sends it again")
    func failedWriteStaysOnTheOldValue() {
        var row = Self.row(stored: "", typed: Self.good)
        #expect(row.commit(stored: "") == .write(Self.good))
        // The store never confirms: stored stays "".
        #expect(row.subtitle(stored: "") == .notSet)
        #expect(row.openLink(stored: "") == nil)
        #expect(row.hasUnsavedDraft)
        #expect(row.commit(stored: "") == .write(Self.good), "a second Return sends the write again")
    }

    @Test("emptying the field asks for a remove, and a failed remove never shows Not set")
    func emptyingTheFieldRemoves() {
        var row = Self.row(stored: Self.good, typed: "")
        #expect(row.commit(stored: Self.good) == .remove)
        #expect(row.subtitle(stored: Self.good) == .set(folderId: Self.folder), "stored is unchanged")
        #expect(row.commit(stored: Self.good) == .remove, "the remove is asked for again")
        row.storedChanged(to: "", isFocused: true)
        #expect(row.subtitle(stored: "") == .notSet)
        #expect(row.draft == "")
        #expect(!row.hasUnsavedDraft)
    }

    @Test("an outside clear with the caret in an untouched field shows at once and is never undone")
    func outsideClearWithCaretInUntouchedField() {
        var row = Self.row(stored: Self.good)
        row.storedChanged(to: "", isFocused: true)
        #expect(row.draft == Self.good, "the caret keeps the field")
        #expect(row.subtitle(stored: "") == .notSet)
        #expect(row.openLink(stored: "") == nil, "the link would open a folder that is no longer stored")
        #expect(row.commit(stored: "") == .none, "clicking away must not write the old link back")
        #expect(row.draft == "")
        #expect(!row.hasUnsavedDraft)
    }

    @Test("an outside change while the person is typing keeps the draft, and commit then decides on it")
    func outsideChangeWhileTyping() {
        var row = Self.row(stored: Self.good, typed: "https://www.fig")
        row.storedChanged(to: "", isFocused: true)
        #expect(row.draft == "https://www.fig")
        #expect(row.subtitle(stored: "") == .notSet)
        #expect(row.commit(stored: "") == .none)
        #expect(row.subtitle(stored: "") == .notSavedNotAFolder)
    }

    @Test("a refused link speaks while its text is in the field, and an outside change with no caret ends it")
    func refusalThenOutsideChange() {
        var row = Self.row(stored: Self.good, typed: Self.noTeamLink)
        #expect(row.commit(stored: Self.good) == .none)
        #expect(row.draft == Self.noTeamLink, "the field keeps what was typed")
        #expect(row.subtitle(stored: Self.good) == .notSavedNoTeam)
        #expect(row.openLink(stored: Self.good) == nil)
        row.draft += "x"
        #expect(row.subtitle(stored: Self.good) == .set(folderId: Self.folder), "changing the field ends the refusal")
        row.draft = Self.noTeamLink
        #expect(row.subtitle(stored: Self.good) == .notSavedNoTeam, "the same text speaks again")
        row.storedChanged(to: "", isFocused: false)
        #expect(row.draft == "")
        #expect(row.subtitle(stored: "") == .notSet)
    }

    @Test("a design link is refused as not a folder link")
    func designLinkRefused() {
        var row = Self.row(stored: "", typed: Self.designLink)
        #expect(row.commit(stored: "") == .none)
        #expect(row.subtitle(stored: "") == .notSavedNotAFolder)
    }

    @Test("a stored value of only spaces reads as not set, and emptying the field removes it")
    func storedSpaces() {
        var row = Self.row(stored: "   ", typed: "")
        #expect(row.subtitle(stored: "   ") == .notSet)
        #expect(row.commit(stored: "   ") == .remove)
    }

    @Test("emptying the field with nothing stored writes nothing")
    func emptyWithNothingStored() {
        var row = Self.row(stored: "", typed: "   ")
        #expect(row.commit(stored: "") == .none)
        #expect(row.draft == "")
        #expect(!row.hasUnsavedDraft)
    }

    @Test("the stored link typed in another spelling writes nothing and shows trimmed")
    func sameLinkAnotherSpelling() {
        var row = Self.row(stored: Self.good, typed: Self.addressBar)
        #expect(row.commit(stored: Self.good) == .none)
        #expect(row.draft == Self.good)
        #expect(!row.hasUnsavedDraft)
    }

    @Test("an unchanged field saves nothing")
    func unchangedSavesNothing() {
        var row = Self.row(stored: Self.good)
        #expect(row.commit(stored: Self.good) == .none)
        var empty = Self.row(stored: "")
        #expect(empty.commit(stored: "") == .none)
    }

    private static let otherGood = "https://www.figma.com/files/team/1/folder/2"

    @Test("stored A, typed another good link B, Return writes B")
    func anotherGoodLinkWritesIt() {
        var row = Self.row(stored: Self.good, typed: Self.otherGood)
        #expect(row.commit(stored: Self.good) == .write(Self.otherGood))
        #expect(row.draft == Self.otherGood)
    }

    @Test("typed, an outside change while the caret is in the field, A typed back: Return writes A")
    func retypedBaselineMoves() {
        var row = Self.row(stored: Self.good, typed: "x")
        row.storedChanged(to: Self.otherGood, isFocused: true)
        #expect(row.draft == "x", "a draft being typed is not replaced")
        row.draft = Self.good
        #expect(row.commit(stored: Self.otherGood) == .write(Self.good), "they typed A and pressed Return")
        #expect(row.draft == Self.good)
    }

    @Test("an untouched field keeps its baseline when an outside change arrives under the caret")
    func untouchedBaselineStays() {
        var row = Self.row(stored: Self.good)
        row.storedChanged(to: Self.otherGood, isFocused: true)
        #expect(!row.hasUnsavedDraft)
        #expect(row.commit(stored: Self.otherGood) == .none)
        #expect(row.draft == Self.otherGood, "it catches up without writing")
    }

    @Test("an untouched field over a stored link with a query commits nothing and keeps the draft")
    func untouchedFieldOverAQueryLink() {
        let stored = "https://www.figma.com/files/team/1/folder/2?fuid=9"
        var row = Self.row(stored: stored)
        #expect(row.commit(stored: stored) == .none)
        #expect(row.draft == stored)
        #expect(row.subtitle(stored: stored) == .set(folderId: "2"))
    }

    @Test("an untouched field over a stored link with no team commits nothing and the subtitle stays")
    func untouchedFieldOverANoTeamLink() {
        var row = Self.row(stored: Self.noTeamLink)
        #expect(row.commit(stored: Self.noTeamLink) == .none)
        #expect(row.subtitle(stored: Self.noTeamLink) == .storedNoTeam)
    }

    @Test("an outside change to B in an untouched field, then B typed and Return: nothing to write")
    func typingTheStoredLinkWritesNothing() {
        var row = Self.row(stored: Self.good)
        row.storedChanged(to: Self.otherGood, isFocused: true)
        row.draft = Self.otherGood
        #expect(row.commit(stored: Self.otherGood) == .none)
        #expect(!row.hasUnsavedDraft)
    }

    @Test("an outside clear under the caret, then the field emptied and Return: nothing to remove")
    func emptyingAfterAnOutsideClear() {
        var untouched = Self.row(stored: Self.good)
        untouched.storedChanged(to: "", isFocused: true)
        untouched.draft = ""
        #expect(untouched.commit(stored: "") == .none)
        var typed = Self.row(stored: Self.good, typed: "x")
        typed.storedChanged(to: "", isFocused: true)
        typed.draft = ""
        #expect(typed.commit(stored: "") == .none)
    }

    @Test("a refused link typed with a trailing line break keeps speaking while that text is in the field")
    func refusalHoldsForTheUntrimmedText() {
        var row = Self.row(stored: "", typed: Self.noTeamLink + "\n")
        #expect(row.commit(stored: "") == .none)
        #expect(row.draft == Self.noTeamLink + "\n")
        #expect(row.subtitle(stored: "") == .notSavedNoTeam)
    }

    private struct SubtitleCase: Sendable, CustomTestStringConvertible {
        let name: String
        let stored: String
        let draft: String
        let expected: Row.Subtitle
        var testDescription: String { name }
    }

    private static let subtitleCases: [SubtitleCase] = [
        SubtitleCase(name: "nothing stored", stored: "", draft: "", expected: .notSet),
        SubtitleCase(name: "stored spaces", stored: "   ", draft: "   ", expected: .notSet),
        SubtitleCase(name: "stored link", stored: good, draft: good, expected: .set(folderId: folder)),
        SubtitleCase(name: "stored link with a query", stored: addressBar, draft: addressBar, expected: .set(folderId: folder)),
        SubtitleCase(name: "unsaved text still describes what is stored", stored: good, draft: "https://www.fig",
                     expected: .set(folderId: folder)),
        SubtitleCase(name: "unsaved text over nothing stored", stored: "", draft: good, expected: .notSet),
        SubtitleCase(name: "stored link with no team", stored: noTeamLink, draft: noTeamLink, expected: .storedNoTeam),
        SubtitleCase(name: "stored design link", stored: designLink, draft: designLink, expected: .storedNotAFolder)
    ]

    @Test("the subtitle describes what is stored", arguments: subtitleCases)
    private func subtitle(_ testCase: SubtitleCase) {
        let row = Self.row(stored: testCase.stored, typed: testCase.draft)
        #expect(row.subtitle(stored: testCase.stored) == testCase.expected)
    }

    @Test("Open Folder in Figma shows only when the field holds the stored link and that link passes")
    func openLink() {
        #expect(Self.row(stored: Self.good).openLink(stored: Self.good) == URL(string: Self.good))
        // A stored link with a query opens its trimmed form.
        #expect(Self.row(stored: Self.addressBar).openLink(stored: Self.addressBar) == URL(string: Self.good))
        #expect(Self.row(stored: Self.good, typed: Self.good + "x").openLink(stored: Self.good) == nil, "unsaved text")
        #expect(Self.row(stored: Self.good, typed: Self.designLink).openLink(stored: Self.good) == nil, "refused text")
        #expect(Self.row(stored: "").openLink(stored: "") == nil, "nothing stored")
        #expect(Self.row(stored: Self.noTeamLink).openLink(stored: Self.noTeamLink) == nil, "stored link with no team")
        #expect(Self.row(stored: Self.designLink).openLink(stored: Self.designLink) == nil, "stored design link")
    }
}
