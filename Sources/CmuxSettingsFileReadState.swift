import Foundation

// cmux-rbf (#cm-119.2): why the settings reader's last read of the global cmux.json
// failed, and the `reload_config` answer made from it. Pure values and functions of
// their input; no UI, no AppKit, no I/O.

/// The settings reader's last read of the global `cmux.json`.
enum CmuxSettingsFileReadState: Equatable, Sendable {
    /// The file parsed to an object, or there is no file.
    case read
    case notRead(CmuxSettingsFileReadFailure)

    static let reloadedAnswer = "OK Reloaded config"
    /// The CLI's `config set <font size>` matches this same prefix (CLI/CMUXCLI+Config.swift).
    static let errorAnswerPrefix = "ERROR: cmux.json can't be read: "

    /// The answer of `reload_config` when the terminal config reloaded.
    /// A file of zero bytes is not an error for the command, as for a save.
    var reloadConfigAnswer: String {
        switch self {
        case .read:
            return Self.reloadedAnswer
        case .notRead(let failure):
            guard failure.reason != .empty else { return Self.reloadedAnswer }
            var answer = Self.errorAnswerPrefix + failure.path
            if let line = failure.line { answer += ":\(line)" }
            if var words = failure.words {
                if words.hasSuffix(".") { words.removeLast() }
                if !words.isEmpty { answer += ": " + words }
            }
            return answer + ". cmux.json was not applied; the terminal config was reloaded."
        }
    }
}

struct CmuxSettingsFileReadFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case doesNotParse
        case notAnObject
        case cannotOpen
        case empty
    }

    let path: String
    let reason: Reason
    /// 1-based, in the file on disk. Nil when not known or not trusted.
    let line: Int?
    /// The reader's own words, without a position. Nil when it gave none.
    let words: String?

    static let notAnObjectWords = "The top level is not an object"
    static let cannotOpenWords = "The file could not be opened"
    private static let nonObjectTopLevelPrefix = "JSON text did not start with array or object"

    init(path: String, reason: Reason, line: Int? = nil, words: String? = nil) {
        self.path = path
        self.reason = reason
        self.line = line
        self.words = words
    }

    static func empty(path: String) -> Self {
        Self(path: path, reason: .empty)
    }

    static func cannotOpen(path: String) -> Self {
        Self(path: path, reason: .cannotOpen, words: cannotOpenWords)
    }

    static func notAnObject(path: String) -> Self {
        Self(path: path, reason: .notAnObject, words: notAnObjectWords)
    }

    /// A failure of the comment stripper or the JSON reader, for the file's `data`.
    init(error: Error, data: Data, path: String) {
        let nsError = error as NSError
        let debugDescription = nsError.userInfo[NSDebugDescriptionErrorKey] as? String

        if let debugDescription, debugDescription.hasPrefix(Self.nonObjectTopLevelPrefix) {
            // A top-level string or number. The reader's sentence names an API option,
            // and its "line 1" is no place to look.
            self = Self.notAnObject(path: path)
            return
        }

        var words: String?
        var position: Int?
        if let debugDescription {
            let (text, line) = Self.splittingPosition(from: debugDescription)
            words = text
            position = line
        } else if nsError.domain == NSCocoaErrorDomain, nsError.code == NSPropertyListReadCorruptError {
            // The system's general sentence says nothing the answer does not already say.
            words = nil
        } else {
            words = error.localizedDescription
        }
        if var trimmed = words {
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            words = trimmed.isEmpty ? nil : trimmed
        }

        // The comment stripper removes a `/* */` comment with its line breaks, so after
        // one the JSON reader counts lines too low. Show no line for such a file.
        let hasNoBlockComment = (try? JSONCParser.source(data: data).text).map { !$0.contains("/*") } ?? false
        let line = hasNoBlockComment ? position : nil
        self.init(path: path, reason: .doesNotParse, line: line, words: words)
    }

    /// `No value for key in object around line 4, column 20.` becomes
    /// (`No value for key in object`, 4). No match: the whole text and no line.
    private static func splittingPosition(from description: String) -> (text: String, line: Int?) {
        let pattern = #" around line (\d+), column \d+\.?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: description, range: NSRange(description.startIndex..., in: description)
              ),
              let whole = Range(match.range, in: description),
              let lineRange = Range(match.range(at: 1), in: description)
        else { return (description, nil) }
        return (String(description[..<whole.lowerBound]), Int(description[lineRange]))
    }
}
