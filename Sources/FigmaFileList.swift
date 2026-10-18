import Foundation

// cmux-rbf #cm-73.16: workspace-local Figma files, independent of the UI.
struct FigmaFileList: Equatable {
    enum View: String, Codable { case read, editor }

    struct Entry: Equatable {
        var link: URL
        var view: View
        var name: String
        // Runtime precedence only; the session record remains {link, view, name}.
        var nameFromTitle: Bool = false
        var key: String { FigmaPaneURL.fileKey(fromPaneURL: link) ?? "" }
        var displayName: String {
            guard name.count > 50 else { return name }
            return String(name.prefix(25)) + "…" + String(name.suffix(24))
        }
    }

    private(set) var entries: [Entry] = []

    /// Restores saved order, normalizing links and enforcing the same cap and keys.
    mutating func restore(entries saved: [Entry]) {
        var result: [Entry] = []
        var seen: Set<String> = []
        for entry in saved {
            var normalized = FigmaFileList()
            normalized.show(entry.link)
            guard var clean = normalized.entries.first, seen.insert(clean.key).inserted else { continue }
            clean.view = entry.view
            clean.name = entry.name
            // Stored records carry no provenance; preserve their known names until a title replaces them.
            clean.nameFromTitle = true
            result.append(clean)
            if result.count == 10 { break }
        }
        entries = result
    }

    /// Called for a showing. Only pass a title received after this address's key.
    mutating func show(_ address: URL, title: String? = nil) {
        guard let key = FigmaPaneURL.fileKey(fromPaneURL: address), key != "new",
              let document = FigmaPaneURL.documentURL(fromPaneURL: address)
        else { return }
        let view: View = FigmaPaneURL.isWrapperPage(address) ? .read : .editor
        guard var components = URLComponents(url: view == .read ? document : address, resolvingAgainstBaseURL: false) else { return }
        if view == .read {
            components.queryItems = FigmaPaneURL.node(fromPaneURL: address).map {
                [URLQueryItem(name: "node-id", value: $0)]
            }
        } else {
            let kept = components.queryItems?.filter { $0.name != "t" }
            components.queryItems = kept?.isEmpty == false ? kept : nil
        }
        guard let link = components.url else { return }
        let previous = entries.first { $0.key == key }
        let titleName = title.flatMap(Self.fileName(fromTitle:))
        let name = titleName ?? (previous?.nameFromTitle == true ? previous?.name : nil)
            ?? Self.fileName(fromLink: document)
        let entry = Entry(
            link: link,
            view: view,
            name: name,
            nameFromTitle: titleName != nil || previous?.nameFromTitle == true
        )
        entries.removeAll { $0.key == key }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(10))
    }

    /// A late title updates the row where it stands, never its recency.
    mutating func rename(key: String, title: String) {
        guard let name = Self.fileName(fromTitle: title),
              let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[index].name = name
        entries[index].nameFromTitle = true
    }

    private static func fileName(fromTitle title: String) -> String? {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !["Figma", "FigJam", "Figma Slides"].contains(name) else { return nil }
        for suffix in [" – Figma Slides", " – FigJam", " – Figma"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func fileName(fromLink link: URL) -> String {
        // URL.path has already percent-decoded the link's name part once.
        let parts = link.path.split(separator: "/").map(String.init)
        let nameIndex = parts.count >= 4 && parts[2] == "branch" ? 4 : 2
        guard parts.count > nameIndex else { return String(localized: "figma.menu.untitled", defaultValue: "Untitled") }
        let name = parts[nameIndex].replacingOccurrences(of: "-", with: " ")
        return name.isEmpty ? String(localized: "figma.menu.untitled", defaultValue: "Untitled") : name
    }
}
