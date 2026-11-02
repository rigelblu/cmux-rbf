import Foundation

// cmux-rbf #cm-126.3: `cmux agent-pane`'s page rule and its messages, pure.

/// What `cmux agent-pane show <page>` accepts, and what it says for each
/// refusal. Built into the CLI and the unit tests both, as `FigmaCLIRules` is.
/// The caller isn't here: `cm-73.45`'s `figmaCallerSurfaces` picks it.
enum AgentPaneCLIRules {

    enum PageRefusal: Error, Equatable {
        /// Not a path, and not a `file://`, `https://` or `http://` URL.
        case badPage(String)
        /// A missing path that looks like a host and port without `http://`.
        case hostPortWithoutScheme(String)
        /// A path or `file://` URL to nothing.
        case noSuchFile(String)
        /// A path to a directory, which cannot be shown as a page.
        case notFile(String)
        /// Figma's editor, or cmux's read view: those go to the Figma pane.
        case figmaAddress
    }

    /// `<page>` as a URL: a path made absolute against `cwd` (it must exist),
    /// or a `file://`, `https://` or `http://` URL. A Figma editor or read-view
    /// address is refused, so an Agent Pane's address never matches the Figma rule.
    static func page(
        _ raw: String,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (String) -> Bool = { path in
            var directory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            return directory.boolValue
        }
    ) -> Result<URL, PageRefusal> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.badPage(raw)) }
        guard hasScheme(text) else {
            let file = absoluteFileURL(text, cwd: cwd)
            guard fileExists(file.path) else {
                if looksLikeHostAndPort(text) { return .failure(.hostPortWithoutScheme(text)) }
                return .failure(.noSuchFile(file.path))
            }
            guard !isDirectory(file.path) else { return .failure(.notFile(file.path)) }
            return .success(file)
        }
        guard var url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["file", "https", "http"].contains(scheme) else {
            return .failure(.badPage(raw))
        }
        if scheme == "file" {
            guard !url.path.isEmpty,
                  (url.host?.isEmpty ?? true) || url.host?.lowercased() == "localhost" else {
                return .failure(.badPage(raw))
            }
            let path = url.hasDirectoryPath && !url.path.hasSuffix("/") ? url.path + "/" : url.path
            let file = absoluteFileURL(path, cwd: cwd)
            var resolved = URLComponents(url: file, resolvingAgainstBaseURL: false)
            let original = URLComponents(url: url, resolvingAgainstBaseURL: false)
            resolved?.percentEncodedQuery = original?.percentEncodedQuery
            resolved?.percentEncodedFragment = original?.percentEncodedFragment
            guard let absolute = resolved?.url else { return .failure(.badPage(raw)) }
            guard fileExists(file.path) else { return .failure(.noSuchFile(file.path)) }
            guard !isDirectory(file.path) else { return .failure(.notFile(file.path)) }
            url = absolute
        } else if url.host?.isEmpty ?? true {
            return .failure(.badPage(raw))
        }
        if FigmaPaneURL.isWrapperPage(url) || FigmaFileLink.isEditorPage(url) {
            return .failure(.figmaAddress)
        }
        return .success(url)
    }

    /// One resolution for bare paths and file URLs, including tilde expansion.
    private static func absoluteFileURL(_ path: String, cwd: String) -> URL {
        let base = URL(fileURLWithPath: cwd, isDirectory: true)
        let normalized = path.hasPrefix("/") ? "/" + String(path.drop(while: { $0 == "/" })) : path
        return URL(fileURLWithPath: normalized, relativeTo: base).standardizedFileURL
    }

    /// Known URL schemes, or a syntactic scheme followed by `//`, stay URLs.
    /// Other colons belong to file names, such as `report:v2.html`.
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }
        let scheme = text[text.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        guard scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return false
        }
        let knownSchemes = [
            "file", "http", "https", "about", "data", "javascript", "mailto", "tel", "sms",
            "ftp", "ftps", "sftp", "ssh", "ws", "wss", "cmux", "cmux-figma", "view-source"
        ]
        return knownSchemes.contains(scheme.lowercased()) || text[text.index(after: colon)...].hasPrefix("//")
    }

    private static func looksLikeHostAndPort(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex,
              !text[..<colon].contains("/") else { return false }
        let port = text[text.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy { $0.isASCII && $0 >= "0" && $0 <= "9" }
    }

    static let noCallerMessage =
        "cmux agent-pane show needs the agent's terminal: run it in a cmux terminal or pass --surface"

    static func message(for refusal: PageRefusal) -> String {
        switch refusal {
        case .badPage(let page): return "not a file, file://, https:// or http:// page: \(page)"
        case .hostPortWithoutScheme(let page):
            return "not a file, file://, https:// or http:// page: \(page); did you mean http://\(page)?"
        case .noSuchFile(let path): return "no such file: \(path)"
        case .notFile(let path): return "not a file: \(path)"
        case .figmaAddress: return figmaAddressMessage
        }
    }

    static let figmaAddressMessage =
        "a Figma address goes to your Figma pane, not the Agent Pane: put the board in a page of your own "
        + "(Figma's embed in an iframe) and show that page"

    /// One socket error, as the CLI reads it: the code, and from `data` the
    /// reason and the values a message names.
    struct SocketFailure: Error, Equatable {
        var code: String
        var message: String
        var reason: String?
        var surface: String?
        var type: String?
        var host: String?
        var url: String?
        var page: String?
    }

    /// The message the CLI prints for a socket error; the socket's own message
    /// is an English diagnostic, used only where this has nothing better.
    static func message(for failure: SocketFailure) -> String {
        switch (failure.code, failure.reason) {
        case ("not_found", _):
            return "that terminal is gone: \(failure.surface ?? "unknown")"
        case ("invalid_params", "not_terminal"):
            return "the Agent Pane belongs to a terminal, and \(failure.surface ?? "that surface") is a \(failure.type ?? "surface")"
        case ("unsupported", "in_dock"):
            return "the Agent Pane opens beside a terminal in a workspace, not in the Dock"
        case ("unavailable", "browser_off"):
            return "cmux's browser is off in Settings, so the Agent Pane can't open"
        case ("invalid_params", "insecure_http"):
            return "http:// opens only for localhost or a host on cmux's insecure-HTTP list (Settings): "
                + "\(failure.host ?? "unknown"). Use https:// or a local file"
        case ("invalid_params", "figma_address"):
            return figmaAddressMessage
        case ("invalid_params", "bad_scheme"):
            return "not a file, file://, https:// or http:// page: \(failure.page ?? failure.url ?? "unknown")"
        case ("browser_url_blocked", _):
            return "the embedded browser's URL policy blocks \(failure.url ?? "that page"): \(failure.message)"
        case ("internal_error", _):
            return "the Agent Pane couldn't open, and nothing was changed: \(failure.message)"
        default:
            return "\(failure.code): \(failure.message)"
        }
    }
}
