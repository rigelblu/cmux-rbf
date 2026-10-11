import Foundation

/// A link to a Figma team folder, checked once for Settings, the
/// `cmux figma folder` command and a hand-edited `cmux.json`.
///
/// Figma's `create_new_file` takes a `planKey` and a `projectId`. The link
/// carries both: `/files/team/<team>/folder/<folder>`, or `project` where the
/// older links say so. ``check(_:)`` is one ordered rule and the first step
/// that answers is the answer, so every text has exactly one answer:
///
/// 1. Strip spaces, tabs and line breaks from both ends.
/// 2. The text starts `https://` and the text up to the next `/`, `?` or `#`
///    is `figma.com` or `www.figma.com`, both without regard to case. Else
///    ``Refusal/notAFolderLink``. `CLI/FigmaFileLink.swift` holds the same host
///    rule for file links and a test holds the two together.
/// 3. The path is what lies between the first `/` after the host and a `?` or
///    `#`. It is compared as written, case included.
/// 4. `/files/team/<digits>/folder/<digits>` or `.../project/<digits>`, with
///    nothing or a `/` and anything after it, passes. `<digits>` is ASCII only.
/// 5. A path that starts `/files/team/` and did not pass is ``Refusal/notAFolderLink``.
///    No line of code answers this step. A path that starts `/files/team/` matches
///    none of step 6's shapes (their first segment after `/files/` is `folder`,
///    `project` or digits, never `team`), so step 7 gives the same answer.
/// 6. `/files/folder/<digits>`, `/files/project/<digits>`,
///    `/files/<digits>/folder/<digits>` and `/files/<digits>/project/<digits>`,
///    with the same tail, are ``Refusal/noTeam``. The last two are not read as
///    an organization: Figma opened such a link as a team folder.
/// 7. Anything else is ``Refusal/notAFolderLink``.
public struct FigmaFolderLink: Equatable, Sendable {
    /// The folder id: the `projectId` that `create_new_file` takes.
    public let projectId: String
    /// `team::<team id>`: the `planKey` that `create_new_file` takes.
    public let planKey: String
    /// The link as it is stored: `https`, the host in lower case, and the path
    /// up to and including the folder id. The query, the `#` part and whatever
    /// follows the folder id are dropped. A stored link checks to itself.
    public let url: String

    /// Only ``check(_:)`` and this module build a link; nothing outside it can make one that
    /// did not pass the check.
    init(projectId: String, planKey: String, url: String) {
        self.projectId = projectId
        self.planKey = planKey
        self.url = url
    }

    /// Why a text is not a usable folder link.
    public enum Refusal: Error, Equatable, Sendable {
        /// A folder link with no team in it. Figma needs the team to create a file.
        case noTeam
        /// Anything else that is not a link to a Figma team folder.
        case notAFolderLink
    }

    private static let hosts: Set<String> = ["figma.com", "www.figma.com"]
    static let blanks: CharacterSet = [" ", "\t", "\n", "\r"]

    /// Checks `text` and returns the link it holds, or the one reason it is refused.
    ///
    /// - Parameter text: A link as pasted, typed, or read from `cmux.json`.
    /// - Returns: `.success` with the folder id, the plan key and the trimmed link, or
    ///   `.failure` with the one reason the text is not a usable folder link.
    public static func check(_ text: String) -> Result<FigmaFolderLink, Refusal> {
        // 1
        let trimmed = text.trimmingCharacters(in: blanks)
        let scalars = Array(trimmed.unicodeScalars)

        // 2
        let scheme = Array("https://".unicodeScalars)
        guard scalars.count >= scheme.count,
              zip(scalars, scheme).allSatisfy({ asciiLowercased($0) == $1 })
        else { return .failure(.notAFolderLink) }
        var cursor = scheme.count
        var host = String.UnicodeScalarView()
        while cursor < scalars.count, !"/?#".unicodeScalars.contains(scalars[cursor]) {
            host.append(asciiLowercased(scalars[cursor]))
            cursor += 1
        }
        let hostText = String(host)
        guard hosts.contains(hostText) else { return .failure(.notAFolderLink) }

        // 3
        var path: [Unicode.Scalar] = []
        if cursor < scalars.count, scalars[cursor] == "/" {
            while cursor < scalars.count, scalars[cursor] != "?", scalars[cursor] != "#" {
                path.append(scalars[cursor])
                cursor += 1
            }
        }

        // 4
        if let team = matchTeamForm(path) {
            let stored = "https://\(hostText)/files/team/\(team.team)/\(team.word)/\(team.folder)"
            return .success(FigmaFolderLink(
                projectId: team.folder,
                planKey: "team::\(team.team)",
                url: stored
            ))
        }

        // 5 to 7: not the team form, so step 6's four shapes are "no team" and everything else,
        // a `/files/team/` path included, is "not a folder link".
        return isNoTeamShape(path) ? .failure(.noTeam) : .failure(.notAFolderLink)
    }

    // MARK: - Matching

    private static func matchTeamForm(
        _ path: [Unicode.Scalar]
    ) -> (team: String, word: String, folder: String)? {
        var reader = PathReader(path)
        guard reader.take("/files/team/"),
              let team = reader.digits(),
              reader.take("/"),
              let word = reader.takeOneOf(["folder", "project"]),
              reader.take("/"),
              let folder = reader.digits(),
              reader.atEndOrSlash
        else { return nil }
        return (team, word, folder)
    }

    private static func isNoTeamShape(_ path: [Unicode.Scalar]) -> Bool {
        var reader = PathReader(path)
        guard reader.take("/files/") else { return false }
        _ = reader.digitsThen("/")
        guard reader.takeOneOf(["folder", "project"]) != nil,
              reader.take("/"),
              reader.digits() != nil,
              reader.atEndOrSlash
        else { return false }
        return true
    }

    /// Lower-cases `A` to `Z` and nothing else, so no Unicode case mapping can
    /// turn a look-alike into `figma.com`.
    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A else { return scalar }
        return Unicode.Scalar(scalar.value + 0x20) ?? scalar
    }

    private struct PathReader {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEndOrSlash: Bool { index == scalars.count || scalars[index] == "/" }

        mutating func take(_ literal: String) -> Bool {
            let wanted = Array(literal.unicodeScalars)
            guard index + wanted.count <= scalars.count,
                  Array(scalars[index..<index + wanted.count]) == wanted
            else { return false }
            index += wanted.count
            return true
        }

        mutating func takeOneOf(_ literals: [String]) -> String? {
            for literal in literals where take(literal) { return literal }
            return nil
        }

        /// One or more ASCII digits, `0` to `9`. Never `isNumber`, which takes
        /// the digits of other scripts.
        mutating func digits() -> String? {
            var run = String.UnicodeScalarView()
            while index < scalars.count, scalars[index].value >= 0x30, scalars[index].value <= 0x39 {
                run.append(scalars[index])
                index += 1
            }
            return run.isEmpty ? nil : String(run)
        }

        /// Optional leading `<digits>/`: the bare-id shapes. Leaves the reader
        /// where it was when the digits are not followed by `literal`.
        mutating func digitsThen(_ literal: String) -> Bool {
            let start = index
            if digits() != nil, take(literal) { return true }
            index = start
            return false
        }
    }
}
