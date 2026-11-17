import Foundation

/// The title a Figma pane's tab or caption shows: `Figma (<name>)`.
///
/// cmux-rbf #cm-73.43. One pure rule with every input a parameter, so a test
/// holds the whole of it with no panel, no workspace and no settings file. It
/// has two callers, as ``FigmaTabMark/picture(own:address:showsAddressBar:wrapper:)``
/// does: a live browser panel, and a restored tab not made yet.
enum FigmaTabTitle {

    /// The tab's title, or `nil` when the tab keeps today's (the page's title,
    /// else the address's host, else "New tab").
    ///
    /// - Parameters:
    ///   - address: the pane's address (cmux's preview page, or Figma's own).
    ///   - showsAddressBar: an ordinary browser tab shows its bar; a Figma pane doesn't.
    ///   - isAgentPane: an Agent Pane (`cm-126.3`) keeps today's title everywhere.
    ///   - pageName: Figma's own name for the file, from the editor's page title,
    ///     for this file only (``FigmaFileList/titleName(_:)``).
    ///   - knownName: the name the workspace's Figma file list holds for this file.
    ///   - showsFileName: the setting; off reads just `Figma`.
    static func title(
        address: URL?,
        showsAddressBar: Bool,
        isAgentPane: Bool,
        pageName: String?,
        knownName: String?,
        showsFileName: Bool
    ) -> String? {
        guard FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar),
              let address else { return nil }
        guard !isAgentPane else { return nil }
        guard let key = FigmaPaneURL.fileKey(fromPaneURL: address), key != "new" else { return nil }
        guard showsFileName else { return plain }
        let name = pageName
            ?? knownName
            ?? FigmaPaneURL.documentURL(fromPaneURL: address).flatMap(FigmaFileList.linkName)
        guard let name, !name.isEmpty else { return plain }
        return String(localized: "figma.tab.titleWithFile", defaultValue: "Figma (\(name))")
    }

    /// The pane's own word, as Figma's mark says it: not the file's kind.
    private static let plain = "Figma"
}
