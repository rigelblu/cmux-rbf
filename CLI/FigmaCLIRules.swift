import CmuxSettings
import Foundation

/// Which browser pane `cmux figma goto` moves, as a pure function of what the
/// socket said about each pane, so a test can hold it with no socket.
enum FigmaGotoPicker {

    /// One browser pane in the workspace.
    struct Pane: Equatable {
        /// The id the socket takes in `surface_id`.
        let id: String
        /// The short name a person can paste back, `surface:8`.
        let handle: String
        /// The Figma file the pane shows, if it shows one.
        let document: URL?
        /// `show_omnibar` from `browser.url.get`. `nil` when the reply had no
        /// such key, which counts as an ordinary pane: an older app never has a
        /// pane taken.
        let showsAddressBar: Bool?
    }

    enum Outcome: Equatable {
        case move(Pane)
        case refuse(String)
    }

    /// A pane counts when it shows a Figma file and has no address bar: the
    /// pane `cmux figma open` makes, and the rule the app already uses to
    /// collapse the editor's panels. A Figma file in an ordinary browser pane
    /// is left alone, `--surface` aside.
    static func pick(_ panes: [Pane]) -> Outcome {
        let showingFigma = panes.filter { $0.document != nil }
        let counted = showingFigma.filter { $0.showsAddressBar == false }
        switch counted.count {
        case 0:
            if showingFigma.isEmpty {
                return .refuse("no Figma pane is open — run `cmux figma open <url>` first")
            }
            let handles = showingFigma.map(\.handle).joined(separator: ", ")
            return .refuse(
                "no Figma pane is open — browser panes showing a Figma file: \(handles). "
                    + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first"
            )
        case 1:
            return .move(counted[0])
        default:
            let handles = counted.map(\.handle).joined(separator: ", ")
            return .refuse("more than one Figma pane is open (\(handles)) — pass --surface <handle>")
        }
    }
}

/// What follows `cmux figma open`, `goto` or `fit`, split into the one word the verb
/// takes and the one option it takes, so a test can hold it with no socket.
///
/// **A verb refuses what it does not know.** `goto 12-2 --surfce surface:8`
/// would otherwise skip the typo and move whichever pane `goto` picks by
/// itself, and `--surface` on `open` would be dropped. The wording follows
/// `browser goto`: `does not support <flag>`.
enum FigmaArguments {

    struct Parsed: Equatable {
        /// The link for `open`, the node for `goto` or `fit --node`.
        let word: String?
        /// The value of `--workspace` for `open`, of `--surface` for `goto`.
        let option: String?
        let motion: Bool
        let play: Bool

        init(word: String?, option: String?, motion: Bool = false, play: Bool = false) {
            self.word = word
            self.option = option
            self.motion = motion
            self.play = play
        }
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// `open` takes `--workspace`; `goto` and `fit` take `--surface`. `fit` takes an optional `--node`, no positional word.
    static func parse(verb: String, args: [String]) throws -> Parsed {
        let flag = verb == "open" ? "--workspace" : "--surface"
        var word: String?
        var option: String?
        var motion = false
        var play = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                if verb == "fit", arg == "--node" {
                    guard word == nil else {
                        throw Failure(message: "cmux figma fit accepts --node only once")
                    }
                    guard index + 1 < args.count else {
                        throw Failure(message: "--node requires a value")
                    }
                    guard FigmaFit.normalizedNode(args[index + 1]) != nil else {
                        throw Failure(message: "--node requires digits, ':' or '-', then digits")
                    }
                    word = args[index + 1]
                    index += 2
                    continue
                }
                if verb == "goto" && (arg == "--motion" || arg == "--play") {
                    if arg == "--motion" {
                        motion = true
                    } else if arg == "--play" {
                        play = true
                        motion = true
                    }
                    index += 1
                    continue
                }
                guard arg == flag else {
                    throw Failure(message: "cmux figma \(verb) does not support \(arg)")
                }
                guard option == nil else {
                    throw Failure(message: "cmux figma \(verb) accepts \(flag) only once")
                }
                guard index + 1 < args.count,
                      !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw Failure(message: "\(flag) requires a value")
                }
                option = args[index + 1]
                index += 2
                continue
            }
            guard word == nil, verb != "fit" else {
                throw Failure(message: "cmux figma \(verb) does not take an extra argument: \(arg)")
            }
            word = arg
            index += 1
        }
        return Parsed(word: word, option: option, motion: motion, play: play)
    }
}

/// What follows `cmux figma folder`: the read, `set <folder-url>`, `clear` or `list`,
/// split out so a test can hold the refusals with no socket and no file.
///
/// **A form refuses what it does not take**, in the words `open` and `goto`
/// use (`does not support <option>`, `does not take an extra argument: <word>`),
/// where `<form>` is `cmux figma folder`, `cmux figma folder set` or
/// `cmux figma folder clear`. `--json` is taken off before this sees the words.
enum FigmaFolderArguments {

    enum Action: Equatable {
        case read
        /// The text after `set`, as typed. It is checked by `FigmaFolderLink`. Sets the default.
        case set(String)
        /// Removes the default.
        case clear
        /// `set <folder-url> --dir <path>`: the folder for one directory and everything inside it.
        case setIn(String, directory: String)
        /// `clear --dir <path>`: that directory's own entry.
        case clearIn(directory: String)
        /// Every directory's folder, then the default.
        case list
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    static let dirRequired = "--dir requires a directory"

    /// Splits `args` into the one word a form takes and its `--dir` value.
    /// `acceptsDir` is false for `list`, which refuses `--dir` by name.
    private static func words(
        _ args: [String],
        form: String,
        acceptsDir: Bool
    ) throws -> (word: String?, directory: String?) {
        var word: String?
        var directory: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if acceptsDir, arg == "--dir" {
                guard directory == nil else { throw Failure(message: "\(form) accepts --dir only once") }
                guard index + 1 < args.count,
                      !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw Failure(message: dirRequired) }
                directory = args[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--") { throw Failure(message: "\(form) does not support \(arg)") }
            guard word == nil else {
                throw Failure(message: "\(form) does not take an extra argument: \(arg)")
            }
            word = arg
            index += 1
        }
        return (word, directory)
    }

    static func parse(_ args: [String]) throws -> Action {
        guard let first = args.first else { return .read }
        if first.hasPrefix("--") {
            throw Failure(message: "cmux figma folder does not support \(first)")
        }
        let rest = Array(args.dropFirst())
        switch first.lowercased() {
        case "set":
            let form = "cmux figma folder set"
            let parsed = try words(rest, form: form, acceptsDir: true)
            guard let word = parsed.word, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "\(form) requires a Figma folder URL")
            }
            if let directory = parsed.directory { return .setIn(word, directory: directory) }
            return .set(word)
        case "clear":
            let form = "cmux figma folder clear"
            let parsed = try words(rest, form: form, acceptsDir: true)
            if let extra = parsed.word {
                throw Failure(message: "\(form) does not take an extra argument: \(extra)")
            }
            if let directory = parsed.directory { return .clearIn(directory: directory) }
            return .clear
        case "list":
            let form = "cmux figma folder list"
            let parsed = try words(rest, form: form, acceptsDir: false)
            if let extra = parsed.word {
                throw Failure(message: "\(form) does not take an extra argument: \(extra)")
            }
            return .list
        default:
            throw Failure(
                message: "unknown cmux figma folder subcommand '\(first)' (expected set, clear, list)"
            )
        }
    }
}

/// What the three `folder` forms print, apart from the file and the exit code.
/// Drawn in `05-folder-*.txt` of the `cm-73` renders; every line here is exact.
enum FigmaFolderText {

    static let notSet = """
    No default Figma folder. New designs go to your Figma Drafts.
    Set one:  cmux figma folder set <folder-url>
    Or for this directory only:  cmux figma folder set <folder-url> --dir .
    """

    static let cleared = "Default Figma folder cleared. New designs go to your Figma Drafts."

    static let fixIt = "Fix it:  cmux figma folder set <folder-url>"

    /// `cmux figma folder` with a folder that answers. The names are the ones
    /// `create_new_file` takes; the value starts in column 12. `directory` is the key
    /// that answered, or `default`.
    static func read(projectId: String, planKey: String, url: String, directory: String) -> String {
        """
        projectId  \(projectId)
        planKey    \(planKey)
        url        \(url)
        directory  \(directory)
        """
    }

    /// `set --dir`: the directory is the resolved path that was written as the key.
    static func setDirectory(directory: String, projectId: String, planKey: String) -> String {
        """
        Figma folder set for this directory and every directory inside it.
          directory  \(directory)
          projectId  \(projectId)
          planKey    \(planKey)
        """
    }

    /// What new designs in a directory go to once its own entry is gone.
    enum Now: Equatable {
        case defaultFolder
        case folderSetFor(String)
        case drafts
        /// The default answers and cannot be used.
        case defaultUnusable
        /// A parent's entry answers and cannot be used.
        case folderUnusable(String)
    }

    /// `clear --dir` that removed an entry.
    static func clearedDirectory(directory: String, now: Now) -> String {
        let last: String
        switch now {
        case .defaultFolder: last = "New designs there now go to the default Figma folder."
        case .folderSetFor(let path): last = "New designs there now go to the folder set for \(path)."
        case .drafts: last = "New designs there now go to your Figma Drafts."
        case .defaultUnusable:
            last = "New designs there now fail: the default Figma folder can't be used.\nSee why:  cmux figma folder list"
        case .folderUnusable(let path):
            last = "New designs there now fail: the folder set for \(path) can't be used.\nSee why:  cmux figma folder list"
        }
        return """
        Figma folder cleared.
          directory  \(directory)
        \(last)
        """
    }

    /// `clear --dir` with no entry of its own there.
    static func notClearedDirectory(directory: String) -> String {
        """
        No Figma folder was set for this directory. Nothing changed.
          directory  \(directory)
        """
    }

    /// `list`, for a key that cannot match any directory.
    static let keyNotAFullPath = "this is not a full path, so it matches no directory."

    /// `set --dir` for a directory no folder is set for.
    static func cannotSetFor(_ path: String) -> String {
        """
        cmux doesn't set a Figma folder for \(path).
               Set it for a directory inside it.
        """
    }

    static func notADirectory(_ path: String) -> String { "not a directory: \(path)" }

    static let foldersNotObject = """
    figma.folders in cmux.json is not an object.
           Fix it:  cmux figma folder set <folder-url> --dir <directory>
    """

    /// `list` with no entry and no default.
    static let noFolders = """
    No Figma folders set. New designs go to your Figma Drafts.
    Set one:  cmux figma folder set <folder-url>
    Or for this directory only:  cmux figma folder set <folder-url> --dir .
    """

    /// `cmux figma folder` when the entry that answers cannot be used. `key` is the key as written, `~` expanded.
    static func unusableEntry(reason: String, key: String) -> String {
        """
        this directory's Figma folder in cmux.json is not a URL cmux can use:
               \(reason)
               Set for:  \(key)
               Fix it:   cmux figma folder set <folder-url> --dir \(key)
        """
    }

    /// `cmux figma folder set <folder-url>`: the URL is not printed, the person just typed it.
    static func set(projectId: String, planKey: String) -> String {
        """
        Default Figma folder set.
          projectId  \(projectId)
          planKey    \(planKey)
        """
    }

    /// The reason a link is refused, as one line, for the line after `Error: ` in `read`.
    static func reason(_ refusal: FigmaFolderLink.Refusal) -> String {
        switch refusal {
        case .noTeam: return "this Figma folder URL has no team in it."
        case .notAFolderLink: return "not a Figma folder URL."
        }
    }

    /// `set` of a link that does not pass. Following lines are indented under the
    /// first word after `Error: `, as the CLI's other multi-line errors are.
    static func refusedSet(_ refusal: FigmaFolderLink.Refusal) -> String {
        switch refusal {
        case .noTeam:
            return """
            this Figma folder URL has no team in it, and Figma needs the team
                   to create a file.

                   Open it in a browser signed in to Figma. The address bar then shows
                   the full URL:
                     https://www.figma.com/files/team/<team-id>/folder/<folder-id>
            """
        case .notAFolderLink:
            return """
            not a Figma folder URL. Expected:
                     https://www.figma.com/files/team/<team-id>/folder/<folder-id>
            """
        }
    }

    /// `cmux figma folder` when the stored value cannot be used. `reason` is
    /// `reason(_:)` for a link that does not pass, and `it is not text.` otherwise.
    static func unusable(reason: String) -> String {
        """
        the default Figma folder in cmux.json is not a URL cmux can use:
               \(reason)
               \(fixIt)
        """
    }
}

/// The text `cmux figma --help` prints. Kept apart from the command so a test
/// can read it with no socket and no `CMUXCLI`.
enum FigmaUsage {
    static let text = """
    Usage: cmux figma <open|goto|fit|folder> [args]

    Open a Figma design in a pane with no browser around it, and steer it.

    Subcommands:
      open <file-url>   Open the design to the right of this pane. The link must be https.
                        Put the link in quotes: the shell reads the ? and & in it.
                        --workspace <handle> opens it in that workspace instead of this one.
                        A link to a whole file opens Figma's editor with its side panels collapsed.
                        The link Figma's Share button copies with nothing selected carries node-id=0-1 and opens the editor too.
                        A link to one frame opens the read view on that frame.
      goto <node-id>    Move the open Figma pane to that frame, in the read view. Accepts 12-2 or 12:2.
                        --motion opens the player frozen on its first state, with play/pause and still controls.
                        --play marks it and plays its Figma Motion loop once loaded.
                        goto counts a browser pane that shows a Figma file and has no address bar.
                        A Figma file in a browser pane with its address bar showing is left alone.
                        --surface <handle> also moves a browser pane that goto does not count,
                        and picks one when more than one Figma pane is open.
      fit               Center the open Figma pane on all its boards, as Figma's own zoom to fit does.
                        In the editor it presses ! (Figma's Shift+1); in the read view it has Figma redraw the board it shows, in place, with no reload of the pane.
                        --node <id> shows that node in the read view without reloading the pane; accepts 12-2 or 12:2.
                        The editor ignores --node.
                        Run it after you draw or move boards. It works on Figma design files only.
                        It moves nothing on Figma's Log in page.
                        It sends no key to a pane that is not showing, or while a text field in the pane has focus.
                        Counts the same pane goto does. --surface <handle> picks one.
      folder            Print the Figma folder for this directory as projectId,
                        planKey, url and directory: the folder set for the nearest
                        directory that holds this one, else the default.
                        Pass projectId and planKey to Figma's create_new_file.
                        Works with no app running.
      folder set <folder-url> [--dir <path>]
                        Set the default, or with --dir the folder for that
                        directory and every directory inside it. Use the link from
                        Figma's address bar on the folder's page. Put the link in
                        quotes: the shell reads the ? in it.
      folder clear [--dir <path>]
                        Remove the default, or with --dir that directory's folder.
      folder list       Print every directory's folder, then the default.

    Move the view with goto. Do not use cmux browser click or type commands on a Figma pane:
    in the editor they can change the file.
    """
}
