import Foundation

// cmux-rbf #cm-73.45: the terminal a `cmux figma` or `agent-pane show` command ran in (#cm-126.3).

extension CMUXCLI {

    /// The terminals this command may name as its caller, best first.
    ///
    /// herdr-agent's note for this herdr pane comes first, when its pid is a
    /// live `herdr-agent-attach`, since an agent herdr resumed carries no
    /// `CMUX_SURFACE_ID`; then `CMUX_SURFACE_ID`; then nothing. The second is
    /// also what a caller retries with when the app answers `not_found` for the
    /// first. Reads one file and writes nothing. A note that is missing, stale
    /// or malformed is skipped, and never fails the command; a `CMUX_SURFACE_ID`
    /// that is no surface at all fails as it did before the note existed.
    ///
    /// `strict` says whether a `CMUX_SURFACE_ID` that is no surface at all fails the command. It does where the
    /// command read that variable before the note existed (`open`; `goto` and `fit` without `--surface`), and
    /// not elsewhere (`goto --surface`, `fit --surface`): there the bad value is dropped and the command goes on.
    /// `agent-pane show` also passes `strict: true`: its pane opens beside a terminal (#cm-126.3).
    func figmaCallerSurfaces(client: SocketClient, strict: Bool) throws -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let folder = (home as NSString).appendingPathComponent(".local/state/herdr-agent/panes")
        return try HerdrPaneNote.callers(
            environment: environment,
            folder: folder,
            readNote: { HerdrPaneNote.readNote(atPath: $0) },
            isLiveAttach: { note, notePath in
                HerdrAttachProcess.isLiveAttach(pid: note.pid, notePath: notePath)
            },
            normalizeEnvironmentSurface: { raw in
                if strict { return try self.normalizeSurfaceHandle(raw, client: client) }
                return (try? self.normalizeSurfaceHandle(raw, client: client)) ?? nil
            }
        )
    }

    /// The first of `callers` the app knows, for a command that has no call of its
    /// own to learn it from (`goto --surface`, which lists nothing). One probe,
    /// only when there is a second to fall back to; an unknown pane answers
    /// `not_found`, any other answer keeps the candidate.
    func figmaFirstKnownCaller(_ callers: [String], client: SocketClient) -> String? {
        guard callers.count > 1 else { return callers.first }
        for caller in callers {
            do {
                _ = try client.sendV2(method: "surface.list", params: ["surface_id": caller])
                return caller
            } catch let error as CLIError where error.v2Code == "not_found" {
                continue
            } catch {
                return caller
            }
        }
        return nil
    }
}
