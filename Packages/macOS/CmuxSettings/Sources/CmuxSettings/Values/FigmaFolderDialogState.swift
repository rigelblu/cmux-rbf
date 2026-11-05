import Foundation

/// What the Set Figma Folder dialog shows and when it lets the person press Set Folder
/// (`15_design-experience.md`, Interaction `#15`). Pure: the dialog reads it and draws it.
///
/// - **The pop-up** lists the workspace's directory first, as the terminal reported it (its
///   shell form), then each parent up to and including the home folder or a volume's root
///   (`/Volumes/<name>`), whichever comes first. Never `/`, `/Volumes` or `/Users`.
/// - **A directory that already has an entry** carries ``Item/hasFolder``.
/// - **On opening,** when an entry answers its directory is selected and its link fills the
///   field; otherwise the workspace's own directory is selected and the field is empty.
/// - **Switching the pop-up** shows that directory's stored link, until the person types. From
///   then on their text stays whatever they pick.
/// - **Set Folder** is enabled only while the field's text passes ``FigmaFolderLink/check(_:)``.
///   The key written is the picked directory with symlinks resolved.
public struct FigmaFolderDialogState: Equatable, Sendable {
    /// One pop-up item.
    public struct Item: Equatable, Sendable {
        /// The directory as the terminal showed it (its shell form).
        public let directory: String
        /// What the pop-up shows: the path, with the home folder as `~`.
        public let title: String
        /// An entry already binds this directory.
        public let hasFolder: Bool
        /// What that entry holds, as text; empty for none or for a value that is not text.
        public let storedLink: String
    }

    /// Empty when the workspace's own directory is one of the directories never offered.
    public let items: [Item]
    public private(set) var selectedIndex: Int
    public private(set) var text: String
    public private(set) var hasTyped = false

    /// - Parameters:
    ///   - directory: The workspace's directory, as its terminal reported it.
    ///   - entries: `figma.folders` as read now.
    ///   - choice: What answers for that directory now.
    ///   - home: What `~` stands for.
    public init(
        directory: String,
        entries: FigmaFolderEntries,
        choice: FigmaFolderChoice,
        home: String = FigmaFolderPath.homeDirectory
    ) {
        let shell = FigmaFolderPath.shellForm(directory, home: home)
        var directories = [shell]
        var parts = FigmaFolderPath.parts(of: shell)
        let homeParts = FigmaFolderPath.parts(of: home)
        let underHome = !homeParts.isEmpty && parts.starts(with: homeParts) && parts.count > homeParts.count
        let underVolume = parts.count > 2 && parts[0] == "Volumes"
        // A workspace in a directory that is never set (`/`, or a link to it) is offered nothing, parents included.
        let ownDirectoryIsNeverSet = FigmaFolderPath.isNeverSet(resolved: FigmaFolderPath.resolvedForm(shell))
        while !ownDirectoryIsNeverSet, parts.count > 1 {
            parts.removeLast()
            let path = "/" + parts.joined(separator: "/")
            if parts.count < (underHome ? homeParts.count : underVolume ? 2 : 1) { break }
            if FigmaFolderPath.isNeverSet(resolved: FigmaFolderPath.resolvedForm(path)) { break }
            directories.append(path)
            if underHome, parts.count == homeParts.count { break }
            if !underHome, underVolume, parts.count == 2 { break }
        }

        var resolvedKeys: [(resolved: String, text: String)] = []
        for key in entries.entries.keys.sorted() {
            guard let forms = FigmaFolderPath.keyForms(key, home: home) else { continue }
            if case .link(let linkText) = entries.entries[key] {
                resolvedKeys.append((forms.resolved, linkText.trimmingCharacters(in: FigmaFolderLink.blanks)))
            } else {
                resolvedKeys.append((forms.resolved, ""))
            }
        }
        func stored(_ resolved: String) -> (has: Bool, text: String) {
            guard let found = resolvedKeys.first(where: { $0.resolved == resolved }) else { return (false, "") }
            return (true, found.text)
        }

        // Never `/`, `/Volumes` or `/Users`, the workspace's own directory included: a folder
        // for one of those would answer for every product on the Mac.
        directories.removeAll { FigmaFolderPath.isNeverSet(resolved: FigmaFolderPath.resolvedForm($0)) }
        var built = directories.map { path -> Item in
            let found = stored(FigmaFolderPath.resolvedForm(path))
            return Item(
                directory: path,
                title: FigmaFolderPath.displayPath(path, home: home),
                hasFolder: found.has,
                storedLink: found.text
            )
        }

        var selected = 0
        var field = ""
        switch choice {
        case .folder(_, from: .directory(let key)),
             .refused(_, from: .directory(let key)),
             .notText(from: .directory(let key)):
            let keyShell = FigmaFolderPath.shellForm(key, home: home)
            let resolved = FigmaFolderPath.resolvedForm(keyShell)
            if let index = built.firstIndex(where: { FigmaFolderPath.resolvedForm($0.directory) == resolved }) {
                selected = index
            } else if FigmaFolderPath.isNeverSet(resolved: resolved) {
                selected = -1
            } else {
                let found = stored(resolved)
                built.append(Item(
                    directory: keyShell,
                    title: FigmaFolderPath.displayPath(keyShell, home: home),
                    hasFolder: true,
                    storedLink: found.text
                ))
                selected = built.count - 1
            }
            field = built.indices.contains(selected) ? built[selected].storedLink : ""
        default:
            break
        }
        items = built
        selectedIndex = max(selected, 0)
        text = field
    }

    /// Picks a pop-up item. The field shows its stored link until the person types.
    public mutating func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        if !hasTyped { text = items[index].storedLink }
    }

    /// The field's text changed: typed or pasted.
    public mutating func type(_ newText: String) {
        text = newText
        hasTyped = true
    }

    /// The link the field holds, when it passes the check.
    public var link: FigmaFolderLink? {
        if case .success(let link) = FigmaFolderLink.check(text) { return link }
        return nil
    }

    /// Why the field's text is refused: `nil` while it is empty or passes.
    public var refusal: FigmaFolderLink.Refusal? {
        guard !text.trimmingCharacters(in: FigmaFolderLink.blanks).isEmpty,
              case .failure(let refusal) = FigmaFolderLink.check(text)
        else { return nil }
        return refusal
    }

    /// Set Folder is enabled.
    public var canSet: Bool { link != nil && !items.isEmpty }

    /// The picked directory as the terminal showed it.
    public var selectedDirectory: String { items.indices.contains(selectedIndex) ? items[selectedIndex].directory : "" }

    /// The key Set Folder writes: the picked directory with symlinks resolved.
    public var resolvedDirectory: String { FigmaFolderPath.resolvedForm(selectedDirectory) }
}
