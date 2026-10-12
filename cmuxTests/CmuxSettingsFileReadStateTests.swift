import Foundation
import Testing
import CmuxSettings
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf (#cm-119.2): what `cmux reload-config` says when the global cmux.json
// could not be read. Every test builds its own CmuxSettingsFileStore on its own
// temp directory, its own UserDefaults suite and its own notification centre, so
// nothing here opens the real ~/.config/cmux/cmux.json.
@Suite(.serialized)
struct CmuxSettingsFileReadStateTests {
    // MARK: Fixtures

    static let valid4 = """
    {
      "sidebar": {},
      "computerUse": {
        "showInMenuBar": false
      }
    }

    """
    /// VALID4 with the colon on line 4 taken out.
    static let broken4 = """
    {
      "sidebar": {},
      "computerUse": {
        "showInMenuBar" false
      }
    }

    """
    static let broken7 = "{\n\n\n\n  \"sidebar\": {},\n  \"computerUse\": {\n    \"showInMenuBar\" false\n  }\n}\n"
    /// An object cut off partway: it ends on line 6, inside an array.
    static let cutOff6 = "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": 2,\n    \"d\": [\n      3"
    static let lineComment5 = "// a note\n" + broken4
    static let comment7 = "/* one\n   two\n   three */\n" + broken4
    static let string4 = """
    {
      "sidebar": { "note": "/* not a comment" },
      "computerUse": {
        "showInMenuBar" false
      }
    }

    """
    static let commaAbove = """
    {
      "sidebar": { "a": 1, },
      "computerUse": {
        "showInMenuBar" false
      }
    }

    """
    /// The system's general sentence for a JSON error that has no description of its own, as
    /// the words would show it: the failure cuts the full stop, so a test that compared the
    /// sentence with its full stop could never find it.
    static var generalSentence: String {
        var sentence = NSError(domain: NSCocoaErrorDomain, code: 3840).localizedDescription
        if sentence.hasSuffix(".") { sentence.removeLast() }
        return sentence
    }

    /// What the JSON reader says for these bytes after the comment stripper, with its
    /// position cut off the end. Nil when the reader accepts the bytes or says nothing.
    static func readerWordsWithoutPosition(_ text: String) -> String? {
        guard let data = try? JSONCParser.preprocess(data: Data(text.utf8)) else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return nil
        } catch {
            guard let description = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String,
                  let range = description.range(of: " around line ") else { return nil }
            return String(description[..<range.lowerBound])
        }
    }

    // MARK: Harness

    final class Home {
        let directory: URL
        let configURL: URL
        let fallbackURL: URL
        let suiteName: String
        let defaults: UserDefaults
        let store: CmuxSettingsFileStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-readstate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configURL = directory.appendingPathComponent("cmux.json")
            fallbackURL = directory.appendingPathComponent("settings.json")
            suiteName = "cmux-readstate-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            store = CmuxSettingsFileStore(
                primaryPath: configURL.path,
                fallbackPath: fallbackURL.path,
                additionalFallbackPaths: [],
                notificationCenter: NotificationCenter(),
                userDefaults: defaults,
                startWatching: false
            )
        }

        deinit {
            // A mode-000 row must not leave a directory nobody can delete.
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        /// The store writes a template cmux.json when it is created with no file, so a
        /// row puts its file in place (or removes it) after the store exists.
        func put(_ contents: Data?) throws {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: configURL.path) {
                _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
                try fileManager.removeItem(at: configURL)
            }
            if let contents { try contents.write(to: configURL) }
        }

        func put(_ text: String?) throws { try put(text.map { Data($0.utf8) }) }

        @discardableResult
        func reloadAndRead() -> CmuxSettingsFileReadState {
            store.reload()
            return store.lastRead
        }
    }

    // MARK: Scenario 34

    // @unchecked: every stored property is an immutable value type (String, Data?, Int?, and Expect's
    // payloads); the compiler cannot see through Expect's `String??`.
    struct KindRow: CustomTestStringConvertible, @unchecked Sendable {
        enum Expect {
            case read
            case empty
            case failure(CmuxSettingsFileReadFailure.Reason, hasLine: Bool, words: String??)
        }
        let name: String
        let contents: Data?
        let mode: Int?
        let expect: Expect
        var testDescription: String { name }

        init(_ name: String, text: String?, mode: Int? = nil, _ expect: Expect) {
            self.name = name
            self.contents = text.map { Data($0.utf8) }
            self.mode = mode
            self.expect = expect
        }
        init(_ name: String, data: Data, _ expect: Expect) {
            self.name = name
            self.contents = data
            self.mode = nil
            self.expect = expect
        }
    }

    static let kindRows: [KindRow] = [
        KindRow("no file", text: nil, .read),
        KindRow("VALID4", text: valid4, .read),
        KindRow("a valid object with // and /* */ comments and a trailing comma",
                text: "// c\n{\n  /* b */\n  \"sidebar\": {},\n}\n", .read),
        KindRow("a wrong shape inside an object", text: #"{"shortcuts": 5}"#, .read),
        KindRow("zero bytes", text: "", .empty),
        KindRow("two spaces and a line break", text: "  \n", .failure(.doesNotParse, hasLine: true, words: .some(nil))),
        KindRow("BROKEN4", text: broken4,
                .failure(.doesNotParse, hasLine: true, words: .some(readerWordsWithoutPosition(broken4)))),
        KindRow("cut off after a key", text: "{ \"sidebar\": ", .failure(.doesNotParse, hasLine: true, words: .some(nil))),
        KindRow("an array", text: "[1, 2]",
                .failure(.notAnObject, hasLine: false, words: .some("The top level is not an object"))),
        KindRow("a string at the top level", text: "\"text\"",
                .failure(.notAnObject, hasLine: false, words: .some("The top level is not an object"))),
        KindRow("a number at the top level", text: "5",
                .failure(.notAnObject, hasLine: false, words: .some("The top level is not an object"))),
        KindRow("a comment never closed", text: "/* never closed",
                .failure(.doesNotParse, hasLine: false, words: .some("unterminated block comment"))),
        KindRow("a comma with nothing before it", text: "{ \"sidebar\": [,] }",
                .failure(.doesNotParse, hasLine: false, words: .some("invalid trailing comma"))),
        KindRow("mode 000", text: valid4, mode: 0o000,
                .failure(.cannotOpen, hasLine: false, words: .some("The file could not be opened"))),
    ]

    @Test(arguments: kindRows)
    func eachKindOfFileGivesItsValue(row: KindRow) throws {
        let home = try Home()
        try home.put(row.contents)
        if let mode = row.mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: home.configURL.path)
        }
        let state = home.reloadAndRead()
        print("S34 [\(row.name)] -> \(state)")

        switch row.expect {
        case .read:
            #expect(state == .read)
        case .empty:
            guard case .notRead(let failure) = state else {
                Issue.record("zero bytes must be recorded as not read, got \(state)")
                return
            }
            #expect(failure.reason == .empty)
            #expect(failure.line == nil)
            #expect(failure.words == nil)
            #expect(failure.path == home.configURL.path)
        case .failure(let reason, let hasLine, let words):
            guard case .notRead(let failure) = state else {
                Issue.record("expected not read (\(reason)), got \(state)")
                return
            }
            #expect(failure.reason == reason)
            #expect(failure.path == home.configURL.path)
            #expect((failure.line != nil) == hasLine)
            if let line = failure.line { #expect(line >= 1) }
            if let words, let expected = words {
                #expect(failure.words == expected)
            } else if words != nil {
                // "written down as found": it must be a sentence of the reader's own,
                // never the system's general one.
                #expect(failure.words != Self.generalSentence)
            }
            if let shown = failure.words {
                #expect(!shown.hasSuffix("."))
                #expect(!shown.contains("\n"))
            }
        }
    }

    @Test func aDirectoryAtThePathCannotBeOpened() throws {
        let home = try Home()
        try home.put(nil as Data?)
        try FileManager.default.createDirectory(at: home.configURL, withIntermediateDirectories: false)
        guard case .notRead(let failure) = home.reloadAndRead() else {
            Issue.record("a directory at the path must be not read")
            return
        }
        #expect(failure.reason == .cannotOpen)
        #expect(failure.line == nil)
    }

    @Test func aBrokenFallbackFileDoesNotMakeAGoodPrimaryNotRead() throws {
        let home = try Home()
        try home.put(Self.valid4)
        try Data(Self.broken4.utf8).write(to: home.fallbackURL)
        #expect(home.reloadAndRead() == .read)
    }

    @Test func aBrokenFallbackFileDoesNotMakeAMissingPrimaryNotRead() throws {
        let home = try Home()
        try home.put(nil as Data?)
        try Data(Self.broken4.utf8).write(to: home.fallbackURL)
        #expect(home.reloadAndRead() == .read)
    }

    @Test func theWordsAreTheReadersOwnWithThePositionCut() throws {
        let home = try Home()
        try home.put(Self.broken4)
        guard case .notRead(let failure) = home.reloadAndRead() else {
            Issue.record("BROKEN4 must be not read")
            return
        }
        let expected = try #require(Self.readerWordsWithoutPosition(Self.broken4))
        #expect(failure.words == expected)
        #expect(failure.words?.contains("around line") == false)
        #expect(failure.words != Self.generalSentence)
    }

    // The reader's words, built from errors the system's JSON reader does not give for a real file.

    @Test func theSystemsGeneralSentenceIsNeverShown() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 3840)
        #expect(error.userInfo[NSDebugDescriptionErrorKey] == nil)
        let failure = CmuxSettingsFileReadFailure(error: error, data: Data("{".utf8), path: Self.path)
        #expect(failure.reason == .doesNotParse)
        #expect(failure.words == nil)
        #expect(failure.line == nil)
        let answer = CmuxSettingsFileReadState.notRead(failure).reloadConfigAnswer
        #expect(answer == "ERROR: cmux.json can't be read: /tmp/x/cmux.json." + Self.tail)
        #expect(!answer.contains(Self.generalSentence))
    }

    struct StopRow: CustomTestStringConvertible, Sendable {
        let name: String
        let error: NSError
        let line: Int?
        let words: String
        var testDescription: String { name }
    }

    static let stopRows: [StopRow] = [
        StopRow(
            name: "reader words ending in a full stop, with a position",
            error: NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [
                NSDebugDescriptionErrorKey: "Something ended. around line 3, column 4.",
            ]),
            line: 3, words: "Something ended"
        ),
        StopRow(
            name: "reader words ending in a full stop, no position",
            error: NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [
                NSDebugDescriptionErrorKey: "Something ended.",
            ]),
            line: nil, words: "Something ended"
        ),
        StopRow(
            name: "another error's description ending in a full stop",
            error: NSError(domain: "other", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk on fire."]),
            line: nil, words: "Disk on fire"
        ),
    ]

    @Test(arguments: stopRows)
    func theFullStopIsCutFromTheWords(row: StopRow) {
        let failure = CmuxSettingsFileReadFailure(error: row.error, data: Data("{".utf8), path: Self.path)
        #expect(failure.words == row.words)
        #expect(failure.line == row.line)
    }

    @Test func theValueFollowsTheFileInBothDirections() throws {
        let home = try Home()
        try home.put(Self.broken4)
        #expect(home.reloadAndRead() != .read)
        try home.put(Self.valid4)
        #expect(home.reloadAndRead() == .read)
        try home.put(Self.broken4)
        #expect(home.reloadAndRead() != .read)
        try home.put(nil as Data?)
        #expect(home.reloadAndRead() == .read)
    }

    // MARK: Scenario 35

    struct LineRow: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        let line: Int?
        var testDescription: String { name }
    }

    static let lineRows: [LineRow] = [
        LineRow(name: "BROKEN4", text: broken4, line: 4),
        LineRow(name: "BROKEN7", text: broken7, line: 7),
        LineRow(name: "LINECOMMENT5", text: lineComment5, line: 5),
        LineRow(name: "a trailing comma removed above the mistake", text: commaAbove, line: 4),
        LineRow(name: "COMMENT7 (a /* in the file)", text: comment7, line: nil),
        LineRow(name: "STRING4 (a /* inside a string)", text: string4, line: nil),
        LineRow(name: "BROKEN4 with \\r\\n", text: broken4.replacingOccurrences(of: "\n", with: "\r\n"), line: 4),
        LineRow(name: "BROKEN4 with lone \\r", text: broken4.replacingOccurrences(of: "\n", with: "\r"), line: 4),
        // The line is where the reader ran out of bytes: one past the last line with text when
        // the file ends in a line break. Measured through the system's reader.
        LineRow(name: "cut off on line 6, with a final line break", text: cutOff6 + "\n", line: 7),
        LineRow(name: "cut off on line 6, no final line break", text: cutOff6, line: 6),
    ]

    @Test(arguments: lineRows)
    func lineIsTheFilesLineOrNone(row: LineRow) throws {
        let home = try Home()
        try home.put(row.text)
        guard case .notRead(let failure) = home.reloadAndRead() else {
            Issue.record("\(row.name) must be not read")
            return
        }
        print("S35 [\(row.name)] -> line=\(String(describing: failure.line)) words=\(String(describing: failure.words))")
        #expect(failure.reason == .doesNotParse)
        #expect(failure.line == row.line)
    }

    // MARK: Scenario 36

    struct AnswerRow: CustomTestStringConvertible, Sendable {
        let name: String
        let state: CmuxSettingsFileReadState
        let answer: String
        var testDescription: String { name }
    }

    static let path = "/tmp/x/cmux.json"
    static let tail = " cmux.json was not applied; the terminal config was reloaded."
    static func failure(
        _ reason: CmuxSettingsFileReadFailure.Reason,
        line: Int? = nil,
        words: String? = nil
    ) -> CmuxSettingsFileReadState {
        .notRead(CmuxSettingsFileReadFailure(path: path, reason: reason, line: line, words: words))
    }

    static let answerRows: [AnswerRow] = [
        AnswerRow(name: "read", state: .read, answer: "OK Reloaded config"),
        AnswerRow(name: "not read, empty", state: failure(.empty), answer: "OK Reloaded config"),
        AnswerRow(
            name: "words and a line",
            state: failure(.doesNotParse, line: 4, words: "No value for key in object"),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json:4: No value for key in object." + tail
        ),
        AnswerRow(
            name: "words and no line",
            state: failure(.doesNotParse, words: "unterminated block comment"),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json: unterminated block comment." + tail
        ),
        AnswerRow(
            name: "not an object",
            state: failure(.notAnObject, words: "The top level is not an object"),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json: The top level is not an object." + tail
        ),
        AnswerRow(
            name: "cannot open",
            state: failure(.cannotOpen, words: "The file could not be opened"),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json: The file could not be opened." + tail
        ),
        AnswerRow(
            name: "no words",
            state: failure(.doesNotParse),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json." + tail
        ),
        AnswerRow(
            name: "words that already end in a full stop",
            state: failure(.doesNotParse, line: 2, words: "Something ended."),
            answer: "ERROR: cmux.json can't be read: /tmp/x/cmux.json:2: Something ended." + tail
        ),
    ]

    @Test(arguments: answerRows)
    func reloadConfigAnswer(row: AnswerRow) {
        let answer = row.state.reloadConfigAnswer
        #expect(answer == row.answer)
        #expect(!answer.contains("\n"))
        #expect(!answer.contains("default settings"))
        #expect(!answer.contains(", line"))
    }

    // MARK: R38: what the reader resolves does not change

    struct ResolveRow: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String?
        let sourcePathIsSet: Bool
        var testDescription: String { name }
    }

    static let resolveRows: [ResolveRow] = [
        ResolveRow(name: "no file", text: nil, sourcePathIsSet: false),
        ResolveRow(name: "zero bytes", text: "", sourcePathIsSet: true),
        ResolveRow(name: "BROKEN4", text: broken4, sourcePathIsSet: true),
        ResolveRow(name: "an array", text: "[1, 2]", sourcePathIsSet: true),
        ResolveRow(name: "an unclosed comment", text: "/* never closed", sourcePathIsSet: true),
        ResolveRow(name: "VALID4", text: valid4, sourcePathIsSet: true),
    ]

    @Test(arguments: resolveRows)
    func whatTheReaderResolvesIsUnchanged(row: ResolveRow) throws {
        let home = try Home()
        try home.put(row.text)
        home.store.reload()
        // Printed so the unchanged tree's log and the changed tree's log can be compared.
        print("R38 [\(row.name)] activeSourcePath=\(String(describing: home.store.activeSourcePath)) "
              + "socketMode=\(String(describing: home.defaults.string(forKey: SocketControlSettings.appStorageKey)))")
        if row.sourcePathIsSet {
            #expect(home.store.activeSourcePath == home.configURL.path)
        } else {
            #expect(home.store.activeSourcePath == nil)
        }
    }
}
