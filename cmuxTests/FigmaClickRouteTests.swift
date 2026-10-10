import Foundation
import Testing

/// Where a clicked Figma link goes, with no app: the rule is a pure function of
/// the link and the workspace's browser panes in order.
@Suite("FigmaClickRoute")
struct FigmaClickRouteTests {

    private let wrapper = URL(fileURLWithPath: "/tmp/cmux-figma-click-route-tests/figma-embed.html")

    private func url(_ raw: String) -> URL { URL(string: raw)! }

    /// A pane that is the editor: Figma's own address, no address bar.
    private func editorPane(_ raw: String, bar: Bool = false) -> FigmaClickRoute.Pane {
        FigmaClickRoute.Pane(id: UUID(), address: url(raw), showsAddressBar: bar)
    }

    /// A pane that is the read view: cmux's page carrying the frame's address.
    private func readViewPane(_ raw: String) throws -> FigmaClickRoute.Pane {
        let address = try FigmaPaneURL.destination(for: url(raw), wrapper: wrapper).url
        return FigmaClickRoute.Pane(id: UUID(), address: address, showsAddressBar: false)
    }

    private func answer(_ raw: String, _ panes: [FigmaClickRoute.Pane] = []) -> FigmaClickRoute.Answer {
        FigmaClickRoute.answer(for: url(raw), panes: panes, wrapper: wrapper)
    }

    @Test("R1 another host is not ours")
    func r1AnotherHost() {
        #expect(answer("https://example.com/design/KEY/x") == .notOurs)
    }

    @Test("R2 a link with a port is not ours")
    func r2Port() {
        #expect(answer("https://www.figma.com:8080/design/KEY/x") == .notOurs)
    }

    @Test("R3 /proto/ is not ours")
    func r3Proto() {
        #expect(answer("https://www.figma.com/proto/KEY/x") == .notOurs)
    }

    @Test("R4 /make/ is not ours")
    func r4Make() {
        #expect(answer("https://www.figma.com/make/KEY/x") == .notOurs)
    }

    @Test("R5 no pane on that file, a link with a frame: open new")
    func r5NoPaneFrame() {
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2") == .openNew)
    }

    @Test("R6 no pane on that file, a link with no frame: open new")
    func r6NoPaneNoFrame() {
        #expect(answer("https://www.figma.com/design/KEY/x") == .openNew)
    }

    @Test("R7 same file, a link with a frame: move that pane to the frame")
    func r7MoveToFrame() {
        let pane = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [pane]) == .move(pane: pane.id, node: "12-2"))
    }

    @Test("R8 same file, a link with no frame: bring that pane forward")
    func r8BringForward() {
        let pane = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R9 a different file: open new, naming no pane")
    func r9DifferentFile() {
        let pane = editorPane("https://www.figma.com/design/OTHER/x")
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [pane]) == .openNew)
    }

    @Test("R10 two panes on one file: the first in the order given moves")
    func r10FirstPaneMoves() {
        let first = editorPane("https://www.figma.com/design/KEY/x")
        let second = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [first, second]) == .move(pane: first.id, node: "12-2"))
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [second, first]) == .move(pane: second.id, node: "12-2"))
    }

    @Test("R11 a pane that shows an address bar is not counted")
    func r11AddressBarNotCounted() {
        let ordinary = editorPane("https://www.figma.com/design/KEY/x", bar: true)
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [ordinary]) == .openNew)
        let figma = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x", [ordinary, figma]) == .bringForward(pane: figma.id))
    }

    @Test("R12 a /file/ link is taken")
    func r12FileLink() {
        #expect(answer("https://www.figma.com/file/KEY/x") == .openNew)
    }

    @Test("R13 a /board/ link is taken")
    func r13BoardLink() {
        #expect(answer("https://www.figma.com/board/KEY/x") == .openNew)
    }

    @Test("R14 a /slides/ link is taken")
    func r14SlidesLink() {
        #expect(answer("https://www.figma.com/slides/KEY/x") == .openNew)
    }

    @Test("R15 same key, another name after the key: the same file")
    func r15AnotherName() {
        let pane = editorPane("https://www.figma.com/design/KEY/old-name")
        #expect(answer("https://www.figma.com/design/KEY/new-name", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R16 same key, no name after the key: the same file")
    func r16NoName() {
        let named = editorPane("https://www.figma.com/design/KEY/old-name")
        #expect(answer("https://www.figma.com/design/KEY", [named]) == .bringForward(pane: named.id))
        let bare = editorPane("https://www.figma.com/design/KEY")
        #expect(answer("https://www.figma.com/design/KEY/new-name", [bare]) == .bringForward(pane: bare.id))
    }

    @Test("R17 a /file/KEY link against a /design/KEY pane: the same file")
    func r17AnotherKind() {
        let pane = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/file/KEY/y", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R18 a read-view pane and an editor pane on one key: the same file, whatever follows the key")
    func r18ReadViewAndEditor() throws {
        let readView = try readViewPane("https://www.figma.com/design/KEY/alpha?node-id=1-2")
        #expect(answer("https://www.figma.com/design/KEY/beta", [readView]) == .bringForward(pane: readView.id))
        #expect(answer("https://www.figma.com/design/KEY/beta?node-id=12-2", [readView]) == .move(pane: readView.id, node: "12-2"))
        let editor = editorPane("https://www.figma.com/design/KEY/gamma")
        #expect(answer("https://www.figma.com/design/KEY/beta", [editor]) == .bringForward(pane: editor.id))
    }

    @Test("R19 a branch link against the main file: a different file, so open new")
    func r19BranchAgainstMain() {
        let main = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/branch/BRANCHKEY/x?node-id=12-2", [main]) == .openNew)
        let branch = editorPane("https://www.figma.com/design/KEY/branch/BRANCHKEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x", [branch]) == .openNew)
    }

    @Test("R20 a branch link against a pane on that same branch: the same file")
    func r20SameBranch() {
        let pane = editorPane("https://www.figma.com/design/KEY/branch/BRANCHKEY/old-name")
        #expect(answer("https://www.figma.com/design/KEY/branch/BRANCHKEY/new-name", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R21 a branch link against a pane on another branch of the same key: a different file")
    func r21OtherBranch() {
        let pane = editorPane("https://www.figma.com/design/KEY/branch/OTHERBRANCH/x")
        #expect(answer("https://www.figma.com/design/KEY/branch/BRANCHKEY/x", [pane]) == .openNew)
    }

    @Test("R22 node-id=0-1 names no frame: bring forward, not move")
    func r22FirstPageDash() {
        let pane = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=0-1", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R23 node-id=0:1 names no frame, the same way")
    func r23FirstPageColon() {
        let pane = editorPane("https://www.figma.com/design/KEY/x")
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=0:1", [pane]) == .bringForward(pane: pane.id))
    }

    @Test("R24 a link on embed.figma.com is not ours, though `open` takes it")
    func r24EmbedHost() {
        #expect(answer("https://embed.figma.com/design/KEY/x?node-id=1-2") == .notOurs)
        #expect(FigmaFileLink.isFileLink(url("https://embed.figma.com/design/KEY/x?node-id=1-2")))
    }

    @Test("R25 a link with a user name is not ours")
    func r25UserName() {
        #expect(answer("https://user@www.figma.com/design/KEY/x") == .notOurs)
    }

    @Test("R26 a link whose path holds a backslash is not ours")
    func r26Backslash() {
        #expect(answer("https://www.figma.com/design/KEY/x%5Cy") == .notOurs)
    }

    @Test("R27 a page that is not cmux's, carrying a Figma link in `embed=`, is not a Figma pane")
    func r27ForeignPageCarryingEmbed() {
        let foreign = FigmaClickRoute.Pane(
            id: UUID(),
            address: url("https://example.com/page?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fx%3Fnode-id%3D1-2"),
            showsAddressBar: false
        )
        let elsewhere = FigmaClickRoute.Pane(
            id: UUID(),
            address: url("file:///tmp/elsewhere/figma-embed.html?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fx%3Fnode-id%3D1-2"),
            showsAddressBar: false
        )
        #expect(answer("https://www.figma.com/design/KEY/x?node-id=12-2", [foreign, elsewhere]) == .openNew)
    }
}
