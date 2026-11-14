import Foundation
import Testing

// cmux-rbf #cm-73.45: which terminal `cmux figma open` and `goto` name as their caller.

/// herdr-agent's note, read as text and decided on. The answer to "is that pid a
/// live attach" is given by each test, so no process and no file is touched.
@Suite("HerdrPaneNote")
struct HerdrPaneNoteTests {

    private let s1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let s2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let workspace = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let folder = "/notes"

    private func noteLine(surface: UUID, pid: Int32 = 4242) -> String {
        "\(surface.uuidString)\t\(workspace.uuidString)\t\(pid)\n"
    }

    /// The lookup over one fake note folder. `reads` collects every path asked for.
    private func callers(
        environment: [String: String],
        files: [String: String],
        isLiveAttach: @escaping (HerdrPaneNote, String) -> Bool = { _, _ in true },
        reads: ReadLog = ReadLog()
    ) -> [String] {
        HerdrPaneNote.callers(
            environment: environment,
            folder: folder,
            readNote: { path in
                reads.paths.append(path)
                return files[path]
            },
            isLiveAttach: isLiveAttach,
            normalizeEnvironmentSurface: HerdrPaneNote.trimmed
        )
    }

    private final class ReadLog {
        var paths: [String] = []
    }

    private func herdr(session: String = "s", pane: String = "p1") -> [String: String] {
        ["HERDR_SESSION": session, "HERDR_PANE_ID": pane]
    }

    // MARK: - The order

    @Test("a note whose pid is a live attach beats CMUX_SURFACE_ID")
    func liveNoteBeatsEnvironment() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": noteLine(surface: s1)]
        )
        #expect(result.first == s1.uuidString)
    }

    @Test("the environment's surface follows the note's, for the retry on not_found")
    func environmentFollowsNote() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": noteLine(surface: s1)]
        )
        #expect(result == [s1.uuidString, s2.uuidString])
    }

    @Test("a note and CMUX_SURFACE_ID naming the same surface give it once")
    func sameSurfaceOnce() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s1.uuidString.lowercased()]) { $1 },
            files: ["/notes/s.p1": noteLine(surface: s1)]
        )
        #expect(result == [s1.uuidString])
    }

    // MARK: - A note that does not count

    @Test("a note whose pid is dead falls to CMUX_SURFACE_ID")
    func deadPidFallsThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": noteLine(surface: s1, pid: 4242)],
            isLiveAttach: { note, _ in note.pid != 4242 }
        )
        #expect(result.first == s2.uuidString)
    }

    @Test("a note whose pid is alive but not an attach falls to CMUX_SURFACE_ID")
    func aliveButNotAnAttachFallsThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": noteLine(surface: s1, pid: 77)],
            isLiveAttach: { _, _ in false }
        )
        #expect(result.first == s2.uuidString)
    }

    @Test("a note with two fields falls to CMUX_SURFACE_ID")
    func twoFieldsFallThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": "\(s1.uuidString)\t4242\n"]
        )
        #expect(result.first == s2.uuidString)
    }

    @Test("a note whose surface is not a UUID falls to CMUX_SURFACE_ID")
    func nonUUIDSurfaceFallsThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": "surface:3\t\(workspace.uuidString)\t4242\n"]
        )
        #expect(result.first == s2.uuidString)
    }

    @Test("an empty note falls to CMUX_SURFACE_ID")
    func emptyNoteFallsThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: ["/notes/s.p1": ""]
        )
        #expect(result.first == s2.uuidString)
    }

    @Test("a missing note falls to CMUX_SURFACE_ID")
    func missingNoteFallsThrough() {
        let result = callers(
            environment: herdr().merging(["CMUX_SURFACE_ID": s2.uuidString]) { $1 },
            files: [:]
        )
        #expect(result == [s2.uuidString])
    }

    // MARK: - A path that is refused reads nothing

    @Test("HERDR_SESSION without HERDR_PANE_ID reads no file")
    func paneIdMissingReadsNothing() {
        let reads = ReadLog()
        let result = callers(
            environment: ["HERDR_SESSION": "s", "CMUX_SURFACE_ID": s2.uuidString],
            files: ["/notes/s.p1": noteLine(surface: s1)],
            reads: reads
        )
        #expect(result == [s2.uuidString])
        #expect(reads.paths.isEmpty)
    }

    @Test("a HERDR_PANE_ID of ../x reads no file")
    func parentComponentReadsNothing() {
        let reads = ReadLog()
        let result = callers(
            environment: ["HERDR_SESSION": "s", "HERDR_PANE_ID": "../x", "CMUX_SURFACE_ID": s2.uuidString],
            files: [:],
            reads: reads
        )
        #expect(result == [s2.uuidString])
        #expect(reads.paths.isEmpty)
    }

    @Test("a HERDR_SESSION holding a slash reads no file")
    func slashReadsNothing() {
        let reads = ReadLog()
        let result = callers(
            environment: ["HERDR_SESSION": "a/b", "HERDR_PANE_ID": "p1", "CMUX_SURFACE_ID": s2.uuidString],
            files: [:],
            reads: reads
        )
        #expect(result == [s2.uuidString])
        #expect(reads.paths.isEmpty)
    }

    // MARK: - Nobody

    @Test("no note and no CMUX_SURFACE_ID names nobody")
    func nobody() {
        #expect(callers(environment: [:], files: [:]).isEmpty)
        #expect(callers(environment: herdr(), files: [:]).isEmpty)
    }

    // MARK: - The path and the line

    @Test("a note whose file name keeps a colon is found")
    func colonInFileName() {
        let reads = ReadLog()
        let result = callers(
            environment: herdr(session: "cmux-rbf", pane: "w4:p18"),
            files: ["/notes/cmux-rbf.w4:p18": noteLine(surface: s1)],
            reads: reads
        )
        #expect(result == [s1.uuidString])
        #expect(reads.paths == ["/notes/cmux-rbf.w4:p18"])
    }

    @Test("the line parses to surface, workspace and pid, trailing newline or not")
    func parsesTheLine() {
        let expected = HerdrPaneNote(surface: s1, workspace: workspace, pid: 4242)
        #expect(HerdrPaneNote.parse(noteLine(surface: s1)) == expected)
        #expect(HerdrPaneNote.parse(noteLine(surface: s1).trimmingCharacters(in: .newlines)) == expected)
    }

    @Test("only the first line counts")
    func onlyTheFirstLine() {
        let text = noteLine(surface: s1) + "junk\n"
        #expect(HerdrPaneNote.parse(text)?.surface == s1)
    }

    @Test("a pid that is not a positive integer is no note")
    func badPid() {
        #expect(HerdrPaneNote.parse("\(s1.uuidString)\t\(workspace.uuidString)\tabc\n") == nil)
        #expect(HerdrPaneNote.parse("\(s1.uuidString)\t\(workspace.uuidString)\t0\n") == nil)
        #expect(HerdrPaneNote.parse("\(s1.uuidString)\t\(workspace.uuidString)\t-5\n") == nil)
    }

    @Test("the path joins the folder, session and pane with a dot")
    func buildsThePath() {
        #expect(HerdrPaneNote.path(folder: "/n", session: "s", pane: "w4:p18") == "/n/s.w4:p18")
        #expect(HerdrPaneNote.path(folder: "/n", session: "", pane: "p") == nil)
        #expect(HerdrPaneNote.path(folder: "/n", session: nil, pane: "p") == nil)
    }
}
