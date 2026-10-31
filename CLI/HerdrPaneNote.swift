import Darwin
import Foundation

// cmux-rbf #cm-73.45: the terminal a `cmux figma open` or `goto` ran in, named from herdr-agent's note.

/// herdr-agent's note for one herdr pane: which cmux terminal its attach client
/// is in, so an agent herdr resumed (no `CMUX_*` ids) can still name its terminal.
///
/// The note is one line, `surface<TAB>workspace<TAB>pid`, in
/// `~/.local/state/herdr-agent/panes/<HERDR_SESSION>.<HERDR_PANE_ID>`. This type
/// only reads it as text. Whether its pid is still that pane's attach client is
/// `HerdrAttachProcess`'s answer, passed in, so a test holds every case with no
/// process and no file.
struct HerdrPaneNote: Equatable {
    let surface: UUID
    let workspace: UUID
    let pid: Int32

    /// The first line of `text`, or `nil` when it is not two UUIDs and a pid.
    static func parse(_ text: String) -> HerdrPaneNote? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let fields = firstLine.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let surface = UUID(uuidString: String(fields[0])),
              let workspace = UUID(uuidString: String(fields[1])),
              let pid = Int32(fields[2].trimmingCharacters(in: .whitespaces)),
              pid > 0 else {
            return nil
        }
        return HerdrPaneNote(surface: surface, workspace: workspace, pid: pid)
    }

    /// `<folder>/<session>.<pane>`, or `nil` when either id is missing, empty,
    /// or holds `/` or `..`, so the read stays inside `folder`.
    static func path(folder: String, session: String?, pane: String?) -> String? {
        guard let session, let pane, isSafeName(session), isSafeName(pane) else { return nil }
        return (folder as NSString).appendingPathComponent("\(session).\(pane)")
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
    }

    /// The surfaces to try for the caller, best first: the note's surface when
    /// its pid is a live attach, then `CMUX_SURFACE_ID`'s. Empty when neither
    /// names one. The second is what the command retries with when the app does
    /// not know the first (the attach moved, the pane closed).
    static func decide(
        note: HerdrPaneNote?,
        isLiveAttach: (HerdrPaneNote) -> Bool,
        environmentSurface: String?
    ) -> [String] {
        var candidates: [String] = []
        if let note, isLiveAttach(note) {
            candidates.append(note.surface.uuidString)
        }
        if let environmentSurface, !environmentSurface.isEmpty,
           !candidates.contains(where: { $0.caseInsensitiveCompare(environmentSurface) == .orderedSame }) {
            candidates.append(environmentSurface)
        }
        return candidates
    }

    /// The note's text, or `nil` when the path is not a regular file. Reads at most 4096 bytes. The open is
    /// non-blocking and the type is checked on the open descriptor, so a FIFO planted at the note path cannot
    /// hang the command and a huge file cannot bloat it.
    static func readNote(atPath path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count >= 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    /// `CMUX_SURFACE_ID` as given, minus surrounding space: the value for a caller that has no socket to normalize against.
    static func trimmed(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole lookup over an environment: build the note's path, read it
    /// through `readNote` (not called when the path is refused), and decide.
    /// `normalizeEnvironmentSurface` turns the raw `CMUX_SURFACE_ID` into what
    /// the socket takes; the CLI passes its own, which may throw on a value that
    /// is no surface at all, as it did before the note existed.
    static func callers(
        environment: [String: String],
        folder: String,
        readNote: (String) -> String?,
        isLiveAttach: (HerdrPaneNote, String) -> Bool,
        normalizeEnvironmentSurface: (String?) throws -> String?
    ) rethrows -> [String] {
        let environmentSurface = try normalizeEnvironmentSurface(environment["CMUX_SURFACE_ID"])
        var note: HerdrPaneNote?
        var notePath: String?
        if let path = path(
            folder: folder,
            session: environment["HERDR_SESSION"],
            pane: environment["HERDR_PANE_ID"]
        ), let text = readNote(path) {
            note = parse(text)
            notePath = path
        }
        return decide(
            note: note,
            isLiveAttach: { isLiveAttach($0, notePath ?? "") },
            environmentSurface: environmentSurface
        )
    }
}
