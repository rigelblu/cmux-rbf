import Darwin
import Foundation
import Testing

// cmux-rbf #cm-73.45: the real process check behind herdr-agent's note.

/// Whether a note's pid is still herdr's attach client, against real processes.
/// The attach client runs `/bin/sleep` with argv[0] `herdr-agent-attach`, as
/// herdr runs its own binary under that name. The note folder is a scratch
/// directory, never `~/.local/state`.
@Suite("FigmaCallerSurface")
struct FigmaCallerSurfaceTests {

    /// A scratch folder holding notes and retaining stand-ins until `finish()`.
    private final class Scratch {
        let folder: URL
        private var children: [Process] = []

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cm-73.45-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// Starts the stand-in, which sleeps `seconds`.
        func startAttach(seconds: String = "600") throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-fc", "exec -a herdr-agent-attach /bin/sleep \"$1\"", "herdr-attach-test", seconds]
            process.environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            children.append(process)
            return process
        }

        /// Writes a note the way herdr does, after the attach client started.
        func writeNote(named name: String = "s.p1", pid: Int32) throws -> String {
            let path = folder.appendingPathComponent(name).path
            let line = "\(UUID().uuidString)\t\(UUID().uuidString)\t\(pid)\n"
            try line.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        func writeLiveNote(pid: Int32) throws -> String {
            let path = try writeNote(pid: pid)
            try HerdrAttachNoteTestSupport(pid: pid, notePath: path).waitUntilLive()
            return path
        }

        func finish() {
            for child in children where child.isRunning { child.terminate() }
            for child in children { child.waitUntilExit() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func withScratch(_ body: (Scratch) throws -> Void) throws {
        let scratch = try Scratch()
        defer { scratch.finish() }
        try body(scratch)
    }

    @Test("a live attach: the stand-in is alive, named herdr-agent-attach, and started before the note")
    func liveAttach() throws {
        try withScratch { scratch in
            let child = try scratch.startAttach()
            let note = try scratch.writeLiveNote(pid: child.processIdentifier)
            #expect(HerdrAttachProcess.isLiveAttach(pid: child.processIdentifier, notePath: note))
        }
    }

    @Test("the test's own pid is alive but not an attach")
    func aliveWithTheWrongName() throws {
        try withScratch { scratch in
            let ownPid = getpid()
            let note = try scratch.writeNote(pid: ownPid)
            #expect(HerdrAttachProcess.isAlive(pid: ownPid))
            #expect(HerdrAttachProcess.isLiveAttach(pid: ownPid, notePath: note) == false)
        }
    }

    @Test("an attach that has exited and been waited for is not an attach")
    func exitedAttach() throws {
        try withScratch { scratch in
            let child = try scratch.startAttach(seconds: "0")
            child.waitUntilExit()
            let note = try scratch.writeNote(pid: child.processIdentifier)
            #expect(HerdrAttachProcess.isAlive(pid: child.processIdentifier) == false)
            #expect(HerdrAttachProcess.isLiveAttach(pid: child.processIdentifier, notePath: note) == false)
        }
    }

    @Test("a note written before the process started names a reused pid, not an attach")
    func reusedPid() throws {
        try withScratch { scratch in
            let child = try scratch.startAttach()
            let note = try scratch.writeLiveNote(pid: child.processIdentifier)
            let started = try #require(HerdrAttachProcess.startTime(pid: child.processIdentifier))
            try FileManager.default.setAttributes(
                [.modificationDate: started.addingTimeInterval(-60)],
                ofItemAtPath: note
            )
            #expect(HerdrAttachProcess.isAlive(pid: child.processIdentifier))
            #expect(HerdrAttachProcess.isLiveAttach(pid: child.processIdentifier, notePath: note) == false)
        }
    }

    @Test("a note that cannot be read is not an attach")
    func missingNoteFile() throws {
        try withScratch { scratch in
            let child = try scratch.startAttach()
            let missing = scratch.folder.appendingPathComponent("nope").path
            #expect(HerdrAttachProcess.isLiveAttach(pid: child.processIdentifier, notePath: missing) == false)
        }
    }

    @Test("through the real read: a note in the scratch folder for a live attach names its surface")
    func lookupReadsTheNoteAndChecksTheProcess() throws {
        try withScratch { scratch in
            let child = try scratch.startAttach()
            let surface = UUID()
            let other = UUID()
            let path = scratch.folder.appendingPathComponent("sess.w1:p3").path
            try "\(surface.uuidString)\t\(UUID().uuidString)\t\(child.processIdentifier)\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            try HerdrAttachNoteTestSupport(pid: child.processIdentifier, notePath: path).waitUntilLive()

            let named = HerdrPaneNote.callers(
                environment: ["HERDR_SESSION": "sess", "HERDR_PANE_ID": "w1:p3", "CMUX_SURFACE_ID": other.uuidString],
                folder: scratch.folder.path,
                readNote: { try? String(contentsOfFile: $0, encoding: .utf8) },
                isLiveAttach: { note, notePath in
                    HerdrAttachProcess.isLiveAttach(pid: note.pid, notePath: notePath)
                },
                normalizeEnvironmentSurface: HerdrPaneNote.trimmed
            )
            #expect(named == [surface.uuidString, other.uuidString])

            child.terminate()
            child.waitUntilExit()
            let afterExit = HerdrPaneNote.callers(
                environment: ["HERDR_SESSION": "sess", "HERDR_PANE_ID": "w1:p3", "CMUX_SURFACE_ID": other.uuidString],
                folder: scratch.folder.path,
                readNote: { try? String(contentsOfFile: $0, encoding: .utf8) },
                isLiveAttach: { note, notePath in
                    HerdrAttachProcess.isLiveAttach(pid: note.pid, notePath: notePath)
                },
                normalizeEnvironmentSurface: HerdrPaneNote.trimmed
            )
            #expect(afterExit == [other.uuidString])
        }
    }

    @Test("the note reader returns a regular file's text, at most 4096 bytes of it")
    func readsARegularFileUpToTheLimit() throws {
        try withScratch { scratch in
            let small = scratch.folder.appendingPathComponent("small").path
            try "abc\n".write(toFile: small, atomically: true, encoding: .utf8)
            #expect(HerdrPaneNote.readNote(atPath: small) == "abc\n")

            let huge = scratch.folder.appendingPathComponent("huge").path
            try String(repeating: "x", count: 10_000_000).write(toFile: huge, atomically: true, encoding: .utf8)
            #expect(HerdrPaneNote.readNote(atPath: huge)?.utf8.count == 4096)
        }
    }

    @Test("the note reader returns nothing for a FIFO, and promptly")
    func fifoReadsNothing() throws {
        try withScratch { scratch in
            let fifo = scratch.folder.appendingPathComponent("fifo").path
            #expect(mkfifo(fifo, 0o600) == 0)
            let started = Date()
            #expect(HerdrPaneNote.readNote(atPath: fifo) == nil)
            #expect(Date().timeIntervalSince(started) < 5)
        }
    }

    @Test("the note reader returns nothing for a directory or a missing path")
    func directoryAndMissingReadNothing() throws {
        try withScratch { scratch in
            #expect(HerdrPaneNote.readNote(atPath: scratch.folder.path) == nil)
            #expect(HerdrPaneNote.readNote(atPath: scratch.folder.appendingPathComponent("nope").path) == nil)
            // A device is not a regular file, though it opens and reads: it must not be taken for a note.
            #expect(HerdrPaneNote.readNote(atPath: "/dev/zero") == nil)
        }
    }
}
