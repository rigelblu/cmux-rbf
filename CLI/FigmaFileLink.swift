import Foundation

/// The one recogniser of a Figma file link.
///
/// **Compiled into the CLI, the app and the tests.** `cmux figma open` and
/// `goto` use it to refuse a link, the app's panel collapse and its
/// stay-in-the-pane rule use it to decide whether a page is Figma's, and they
/// have to agree. Two lists of hosts and paths drifted apart once already.
///
/// A link is a Figma file link only when it is `https`, its host is Figma's,
/// its path starts with one of the four file kinds, no part of the path is
/// `..`, and the path holds no backslash. Figma serves `/design/../community`
/// as a page that is not a file, and a browser reads `\` as `/` in an https
/// path, so `/design/..\community` is the same link.
///
/// Nothing may sit between `https://` and the host or after it: no user name,
/// password or port, however it is written. The read view's page refuses an
/// address that has one, so such a link would open an empty pane and print `OK`.
enum FigmaFileLink {

    /// Hosts the editor loads from.
    private static let editorHosts: Set<String> = ["figma.com", "www.figma.com"]
    /// The host of the read view's address.
    static let embedHost = "embed.figma.com"

    /// `/design/<key>/<slug>` today, `/file/<key>/<slug>` on older links.
    private static let kindPrefixes = ["/design/", "/file/", "/board/", "/slides/"]

    /// A link to Figma's editor: `figma.com` or `www.figma.com`.
    static func isEditorLink(_ url: URL) -> Bool {
        isFileLink(url, hosts: editorHosts)
    }

    /// A link to a Figma file on any of Figma's hosts, the read view's included.
    static func isFileLink(_ url: URL) -> Bool {
        isFileLink(url, hosts: editorHosts.union([embedHost]))
    }

    /// Whether an address is any page on Figma's editor hosts: `https`, and
    /// nothing between `https://` and the host or after it. The path is not read.
    static func isEditorPage(_ url: URL) -> Bool {
        isOn(url, hosts: editorHosts)
    }

    /// The text between `https://` and the next `/`, `?` or `#` has to be one
    /// of the hosts, whole. Asking Foundation for the parts is not enough:
    /// it reports no port for `:9223372036854775808` or for a bare `:`, and
    /// the address built from such a link keeps the text. This one rule also
    /// covers the scheme, the host, and any user name, password or port.
    private static func isOn(_ url: URL, hosts: Set<String>) -> Bool {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("https://") else { return false }
        let authority = text.dropFirst("https://".count).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return hosts.contains(authority.lowercased())
    }

    private static func isFileLink(_ url: URL, hosts: Set<String>) -> Bool {
        guard isOn(url, hosts: hosts) else { return false }
        // `URL.path` is percent-decoded, so `%2e%2e`, `%2e%2e%2f` and `%5C` are caught too.
        let path = url.path
        guard kindPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        return !path.contains("\\") && !path.split(separator: "/").contains("..")
    }
}
