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

/// What follows `cmux figma open` or `goto`, split into the one word the verb
/// takes and the one option it takes, so a test can hold it with no socket.
///
/// **A verb refuses what it does not know.** `goto 12-2 --surfce surface:8`
/// would otherwise skip the typo and move whichever pane `goto` picks by
/// itself, and `--surface` on `open` would be dropped. The wording follows
/// `browser goto`: `does not support <flag>`.
enum FigmaArguments {

    struct Parsed: Equatable {
        /// The link for `open`, the frame id for `goto`.
        let word: String?
        /// The value of `--workspace` for `open`, of `--surface` for `goto`.
        let option: String?
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// `open` takes `--workspace`; `goto` takes `--surface`.
    static func parse(verb: String, args: [String]) throws -> Parsed {
        let flag = verb == "open" ? "--workspace" : "--surface"
        var word: String?
        var option: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
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
            guard word == nil else {
                throw Failure(message: "cmux figma \(verb) does not take an extra argument: \(arg)")
            }
            word = arg
            index += 1
        }
        return Parsed(word: word, option: option)
    }
}

/// The text `cmux figma --help` prints. Kept apart from the command so a test
/// can read it with no socket and no `CMUXCLI`.
enum FigmaUsage {
    static let text = """
    Usage: cmux figma <open|goto> [args]

    Open a Figma design in a pane with no browser around it, and steer it.

    Subcommands:
      open <file-url>   Open the design to the right of this pane. The link must be https.
                        Put the link in quotes: the shell reads the ? and & in it.
                        --workspace <handle> opens it in that workspace instead of this one.
                        A link to a whole file opens Figma's editor with its side panels collapsed.
                        The link Figma's Share button copies with nothing selected carries node-id=0-1 and opens the editor too.
                        A link to one frame opens the read view on that frame.
      goto <node-id>    Move the open Figma pane to that frame, in the read view. Accepts 12-2 or 12:2.
                        goto counts a browser pane that shows a Figma file and has no address bar.
                        A Figma file in a browser pane with its address bar showing is left alone.
                        --surface <handle> also moves a browser pane that goto does not count,
                        and picks one when more than one Figma pane is open.

    Move the view with goto. Do not use cmux browser click or type commands on a Figma pane:
    in the editor they can change the file.
    """
}
