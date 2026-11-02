import Foundation
import Testing

/// Establishes the real attach guard before a fixture asks the CLI to read its note.
struct HerdrAttachNoteTestSupport {
    let pid: Int32
    let notePath: String

    func waitUntilLive(timeout: TimeInterval = 5) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        // Lead-directed fixture polling: wait for the production predicate, bounded at five seconds.
        while !HerdrAttachProcess.isLiveAttach(pid: pid, notePath: notePath),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let started = HerdrAttachProcess.startTime(pid: pid)
        let written = HerdrAttachProcess.modificationTime(path: notePath)
        let startBeforeMtime = started.flatMap { start in written.map { start <= $0 } } ?? false
        let alive: Bool = HerdrAttachProcess.isAlive(pid: pid)
        let name: String = HerdrAttachProcess.argv0LastPathComponent(pid: pid) ?? "nil"
        let startTime: TimeInterval = started?.timeIntervalSince1970 ?? -1
        let modificationTime: TimeInterval = written?.timeIntervalSince1970 ?? -1
        let diagnostic: String = "attach fixture not live within \(timeout)s: pid=\(pid), alive=\(alive), name=\(name), start=\(startTime), mtime=\(modificationTime), start-before-mtime=\(startBeforeMtime), note=\(notePath)"
        try #require(
            HerdrAttachProcess.isLiveAttach(pid: pid, notePath: notePath),
            "\(diagnostic)"
        )
    }
}
