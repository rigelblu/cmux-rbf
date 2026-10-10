import Foundation

/// Where a clicked Figma link goes, as a pure function of the link and the
/// workspace's browser panes, so a test can hold every rule with no app.
///
/// **Compiled into the app and the tests, not the CLI**: nothing in the CLI
/// calls it. The inputs and the answer are Foundation types and types declared
/// here, never `FigmaPaneURL.Destination`: the test target compiles its own copy
/// of that file, and a signature using the app's would not be callable from it.
///
/// **A click takes `figma.com` and `www.figma.com` links to the four file kinds**
/// (``FigmaFileLink/isEditorLink(_:)``), one host narrower than `cmux figma open`.
enum FigmaClickRoute {

    /// One browser pane in the workspace.
    struct Pane: Equatable {
        let id: UUID
        let address: URL
        let showsAddressBar: Bool
    }

    enum Answer: Equatable {
        /// Not a link this rule takes: it opens as it does today.
        case notOurs
        /// No Figma pane shows that file: a new Figma tab, where `open` puts one.
        case openNew
        /// A Figma pane shows that file and the link names a frame.
        case move(pane: UUID, node: String)
        /// A Figma pane shows that file and the link names no frame.
        case bringForward(pane: UUID)
    }

    /// - Parameter panes: in the order the workspace shows them. When two show
    ///   the file the first moves: a click has nobody to ask which one.
    static func answer(
        for link: URL,
        panes: [Pane],
        wrapper: URL = FigmaPaneURL.wrapperFileURL()
    ) -> Answer {
        guard FigmaFileLink.isEditorLink(link),
              let key = FigmaPaneURL.fileKey(fromPaneURL: link, wrapper: wrapper)
        else { return .notOurs }

        // A pane counts when it shows a Figma file and has no address bar, as
        // for `cmux figma goto`. A Figma file in an ordinary browser tab is left alone.
        guard let pane = panes.first(where: {
            !$0.showsAddressBar && FigmaPaneURL.fileKey(fromPaneURL: $0.address, wrapper: wrapper) == key
        }) else { return .openNew }

        // The same question `open` asks: an embed means the link names a frame,
        // and `0-1` / `0:1`, the file's first page, name none.
        guard case .embed(_, let embedded)? = try? FigmaPaneURL.destination(for: link, wrapper: wrapper),
              let node = FigmaPaneURL.node(fromPaneURL: embedded, wrapper: wrapper)
        else { return .bringForward(pane: pane.id) }
        return .move(pane: pane.id, node: node)
    }
}
