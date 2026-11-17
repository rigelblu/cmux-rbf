import Foundation

// cmux-rbf #cm-73.16: one recorder path for every subscribed workspace browser panel.
extension Workspace {
    struct FigmaFileObservation {
        var key: String?
        var view: FigmaFileList.View?
        var title: String = ""
        var lastAddress: URL?
    }

    /// Loading, favicon, mute and selection emissions do not count as showings.
    func recordFigmaFile(panelID: UUID, address: URL?, title: String, showsAddressBar: Bool) {
        var previous = figmaFileObservations[panelID] ?? FigmaFileObservation()
        guard let address,
              FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar),
              let key = FigmaPaneURL.fileKey(fromPaneURL: address), key != "new" else {
            // Non-file pages do not erase the file/view this tab last recorded.
            previous.lastAddress = address
            previous.title = title
            figmaFileObservations[panelID] = previous
            return
        }
        let view: FigmaFileList.View = FigmaPaneURL.isWrapperPage(address) ? .read : .editor
        // cmux-rbf #cm-73.43: the name the list holds for this file before and after, so every other
        // tab on the file catches up when it changes.
        let nameBefore = figmaFiles.entries.first { $0.key == key }?.name
        if previous.key != key || previous.view != view {
            // cmux-rbf #cm-73.43: a showing hands the list the title Figma's editor gave this file in a
            // tab of this workspace, read from the panel and not from this emission (the sink runs a
            // turn later, when a switch has already written the preview's `Figma`). A panel this
            // workspace doesn't hold gives none, which is today's behaviour.
            figmaFiles.show(address, title: keptFigmaTitle(forPanel: panelID, key: key))
        } else if previous.lastAddress == address, previous.title != title {
            // Titles paired with an address change belong to the previous page until a later emission.
            figmaFiles.rename(key: key, title: title)
        }
        previous.key = key
        previous.view = view
        previous.lastAddress = address
        previous.title = title
        figmaFileObservations[panelID] = previous
        if figmaFiles.entries.first(where: { $0.key == key })?.name != nameBefore {
            refreshFigmaTabTitles(key: key)
        }
    }

    /// Seed only the saved file/view. The first address sets the title baseline without a new showing.
    func beginFigmaFileRestore(panelID: UUID, address: URL?) {
        let key = address.flatMap { FigmaPaneURL.fileKey(fromPaneURL: $0) }.flatMap { $0 == "new" ? nil : $0 }
        let view: FigmaFileList.View? = key == nil ? nil : (address.map { FigmaPaneURL.isWrapperPage($0) } == true ? .read : .editor)
        figmaFileObservations[panelID] = FigmaFileObservation(key: key, view: view)
    }

    func restoreFigmaFiles(from snapshot: SessionWorkspaceSnapshot) {
        let entries = (snapshot.figmaFiles ?? []).compactMap { record -> FigmaFileList.Entry? in
            guard let link = URL(string: record.link),
                  FigmaFileLink.isEditorLink(link),
                  let view = FigmaFileList.View(rawValue: record.view) else { return nil }
            if view == .read && FigmaPaneURL.node(fromPaneURL: link) == nil { return nil }
            return FigmaFileList.Entry(link: link, view: view, name: record.name, nameFromTitle: true)
        }
        figmaFiles.restore(entries: entries)
    }

    func combineFigmaFilesIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        for entry in figmaFiles.entries {
            hasher.combine(entry.link)
            hasher.combine(entry.view.rawValue)
            hasher.combine(entry.name)
        }
    }
}
