import Foundation

/// The two forms of a directory that `figma.folders` is matched against, and
/// the two forms of each key.
///
/// - The **shell form** is the path as the shell shows it: a leading `~`
///   expanded, `.` and `..` parts dropped by their text as the shell does, a
///   trailing `/` dropped. A `cd` through a symlink keeps the symlink's path
///   here, so a terminal inside a product's `rb-drive` counts as inside the
///   product.
/// - The **resolved form** is the shell form with symlinks resolved. An agent
///   that Claude Code started through a symlink runs in this one.
///
/// A directory that no longer exists keeps its standardized text in both.
public enum FigmaFolderPath {
    /// A directory's shell form and its resolved form.
    public struct Forms: Equatable, Sendable {
        public let shell: String
        public let resolved: String

        public init(shell: String, resolved: String) {
            self.shell = shell
            self.resolved = resolved
        }
    }

    /// Directories no folder is ever set for (see ``isNeverSet(resolved:)``). A hand-written entry for
    /// one still answers, and `clear --dir` can still remove it.
    private static let neverSet: Set<String> = ["/", "/Volumes", "/Users"]

    /// Whether no folder is ever set for this directory: `/`, `/Volumes` and `/Users`, each of which
    /// would answer for every product under it. Asked of the **resolved** form, the key that gets written,
    /// so a workspace at `/Volumes/Macintosh HD` (a link to `/`) is refused as `/` is.
    public static func isNeverSet(resolved: String) -> Bool {
        neverSet.contains(resolved)
    }

    /// The home folder `~` stands for. `CmuxConfigLocation` reads the same one,
    /// so `HOME` alone does not move it (`CFFIXED_USER_HOME` does).
    public static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The text of `path` with a leading `~` expanded and nothing else changed.
    public static func expandingHome(_ path: String, home: String = homeDirectory) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// The shell form of `path`.
    ///
    /// - Parameters:
    ///   - path: Absolute, `~` or `~/…`, or relative to `base`.
    ///   - base: What a relative `path` is taken from. A relative path with no base is taken from `/`.
    ///   - home: What `~` stands for.
    public static func shellForm(
        _ path: String,
        relativeTo base: String? = nil,
        home: String = homeDirectory
    ) -> String {
        var text = expandingHome(path, home: home)
        if !text.hasPrefix("/"), let base { text = base + "/" + text }
        return "/" + parts(of: text).joined(separator: "/")
    }

    /// The resolved form: `shellForm` with symlinks resolved by the system
    /// (`realpath`), so `/tmp` is `/private/tmp`. A path that cannot be resolved
    /// keeps its text.
    public static func resolvedForm(_ shellForm: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(shellForm, &buffer) != nil else { return shellForm }
        return String(cString: buffer)
    }

    /// Both forms of `directory`, which is absolute or starts with `~`.
    public static func forms(of directory: String, home: String = homeDirectory) -> Forms {
        let shell = shellForm(directory, home: home)
        return Forms(shell: shell, resolved: resolvedForm(shell))
    }

    /// The forms of the directory the command runs in.
    ///
    /// The shell form is `$PWD` when `$PWD` is absolute and resolves to the same
    /// place as the working directory (a shell that `cd`ed through a symlink
    /// exports it), and the working directory itself otherwise (a stale `$PWD`,
    /// or none).
    public static func cliForms(pwd: String?, cwd: String) -> Forms {
        let working = forms(of: cwd)
        guard let pwd, pwd.hasPrefix("/") else { return working }
        let shell = shellForm(pwd)
        guard resolvedForm(shell) == working.resolved else { return working }
        return Forms(shell: shell, resolved: working.resolved)
    }

    /// The two forms of a key as written in `figma.folders`, or `nil` for a key
    /// that is neither absolute nor `~/…`, which never matches anything.
    public static func keyForms(_ key: String, home: String = homeDirectory) -> Forms? {
        guard key.hasPrefix("/") || key == "~" || key.hasPrefix("~/") else { return nil }
        return forms(of: key, home: home)
    }

    /// `path` for a person to read: the home folder, or the start of the path, as `~`.
    public static func displayPath(_ path: String, home: String = homeDirectory) -> String {
        let homeParts = parts(of: home)
        let pathParts = parts(of: path)
        guard !homeParts.isEmpty, pathParts.starts(with: homeParts) else { return path }
        let rest = pathParts.dropFirst(homeParts.count)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }

    /// The last path part of a key's directory, for a row's title: `Home` is the caller's word for the
    /// home folder, which this returns as `nil`.
    public static func lastPart(of key: String, home: String = homeDirectory) -> String? {
        let keyParts = parts(of: expandingHome(key, home: home))
        if keyParts == parts(of: home) { return nil }
        return keyParts.last ?? "/"
    }

    /// The path parts of a form: what whole-part matching compares.
    static func parts(of path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !result.isEmpty { result.removeLast() }
                continue
            }
            result.append(String(part))
        }
        return result
    }
}
