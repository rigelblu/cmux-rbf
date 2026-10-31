import Darwin
import Foundation

// cmux-rbf #cm-73.45: is the pid in a herdr-agent note still that pane's attach client?

/// The process checks behind `HerdrPaneNote`. A live pid alone is not enough:
/// of 1,062 notes measured 2026-10-30, 26 pids were alive and 12 of those had
/// been reused by unrelated processes. So the pid must be a `herdr-agent-attach`
/// that started no later than the note was written.
///
/// Compiled into the CLI and `cmuxTests`, so it cannot call `CMUXCLI` methods.
enum HerdrAttachProcess {

    /// Alive, named `herdr-agent-attach`, and started no later than `notePath`'s
    /// last write. Any read that fails answers `false`.
    static func isLiveAttach(pid: Int32, notePath: String) -> Bool {
        guard isAlive(pid: pid),
              argv0LastPathComponent(pid: pid) == "herdr-agent-attach",
              let started = startTime(pid: pid),
              let written = modificationTime(path: notePath) else {
            return false
        }
        return started <= written
    }

    /// `kill(pid, 0) == 0 || errno == EPERM`, the CLI's own test for a live pid.
    static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// The last path part of the process's `argv[0]`. Not `proc_pidpath`: herdr
    /// starts the attach client as its own `herdr` binary under the name
    /// `herdr-agent-attach`, so the image path is `herdr` and only `argv[0]`
    /// carries the name.
    static func argv0LastPathComponent(pid: Int32) -> String? {
        guard let argv0 = argv0(pid: pid) else { return nil }
        return (argv0 as NSString).lastPathComponent
    }

    /// When the process started, from `PROC_PIDTBSDINFO`.
    static func startTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
    }

    /// When the file was last written.
    static func modificationTime(path: String) -> Date? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func argv0(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return argv0(fromProcessArguments: Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` lays out `argc`, the executable path, NULs, then each
    /// argument NUL-terminated. This returns the first argument.
    private static func argv0(fromProcessArguments bytes: [UInt8]) -> String? {
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { raw in
            raw.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        guard Int32(littleEndian: argcRaw) > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        let start = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(bytes: bytes[start..<index], encoding: .utf8)
    }
}
