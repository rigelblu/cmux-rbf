import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf #cm-73.43: Scenario 350, the title rule row by row. `FigmaTabTitle` is a pure
// function whose every input is a parameter, so these tests never read the setting's
// holder or any settings file and need no serialising.
@Suite("FigmaTabTitleRule")
struct FigmaTabTitleRuleTests {

    /// `cm-73 - figma native pane`, linked as Figma links it.
    private static let file = "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73-figma-native-pane"

    /// The preview of that file's frame: cmux's own page carrying the embed.
    private static let frame: URL = {
        let pasted = URL(string: file + "?node-id=12-2")!
        return (try? FigmaPaneURL.destination(for: pasted).url) ?? pasted
    }()

    private static func title(
        _ address: String? = nil,
        address url: URL? = nil,
        bar: Bool = false,
        agent: Bool = false,
        page: String? = nil,
        known: String? = nil,
        shows: Bool = true
    ) -> String? {
        FigmaTabTitle.title(
            address: url ?? address.flatMap { URL(string: $0) },
            showsAddressBar: bar,
            isAgentPane: agent,
            pageName: page,
            knownName: known,
            showsFileName: shows
        )
    }

    // (a) the preview, no name from Figma yet: the link's name
    @Test func previewFallsBackToLinkName() {
        #expect(Self.title(address: Self.frame) == "Figma (cm 73 figma native pane)")
    }

    // (b) the menu's name beats the link's
    @Test func previewReadsKnownNameOverLinkName() {
        #expect(Self.title(address: Self.frame, known: "cm-73 - figma native pane") == "Figma (cm-73 - figma native pane)")
    }

    // (c) the editor's own page title beats the menu's name
    @Test func pageNameWinsOverKnownName() {
        #expect(Self.title(Self.file, page: "cm-73 - figma native pane", known: "old name") == "Figma (cm-73 - figma native pane)")
    }

    // (d) Tom's off state, in the preview and the editor
    @Test func settingOffReadsFigma() {
        #expect(Self.title(address: Self.frame, known: "cm-73 - figma native pane", shows: false) == "Figma")
        #expect(Self.title(Self.file, page: "cm-73 - figma native pane", shows: false) == "Figma")
    }

    // (e) a link with no name part and no name known
    @Test func linkWithNoNamePartReadsFigma() {
        #expect(Self.title("https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2?node-id=12-2") == "Figma")
    }

    // (f) a FigJam board
    @Test func figjamBoardReadsItsName() {
        #expect(Self.title("https://www.figma.com/board/KEY123/Retro-board") == "Figma (Retro board)")
    }

    // (g) a slide deck
    @Test func slideDeckReadsItsName() {
        #expect(Self.title("https://www.figma.com/slides/KEY123/Q4-review") == "Figma (Q4 review)")
    }

    // (h) a branch link names the branch's file
    @Test func branchLinkReadsTheNameAfterBranchKey() {
        #expect(Self.title("https://www.figma.com/design/KEY123/branch/BRANCH9/Branch-name") == "Figma (Branch name)")
    }

    // (i) a new file before its key reaches the address
    @Test func newFileKeepsTodaysTitle() {
        #expect(Self.title("https://www.figma.com/design/new?folder_id=1") == nil)
        #expect(Self.title("https://www.figma.com/design/new?folder_id=1", page: "Untitled", known: "x") == nil)
    }

    // (j) Recents and Log in
    @Test func recentsAndLoginKeepTodaysTitle() {
        #expect(Self.title("https://www.figma.com/files/recent") == nil)
        #expect(Self.title("https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed") == nil)
        #expect(Self.title("https://www.figma.com/login") == nil)
    }

    // (k) an ordinary browser tab on a Figma file, with its address bar
    @Test func addressBarShowingKeepsTodaysTitle() {
        #expect(Self.title(Self.file, bar: true, page: "cm-73 - figma native pane") == nil)
        #expect(Self.title(address: Self.frame, bar: true) == nil)
    }

    // (l) any other page
    @Test func nonFigmaPageKeepsTodaysTitle() {
        #expect(Self.title("https://example.com/design/KEY123/Name") == nil)
        #expect(Self.title("https://www.figma.com.example.com/design/KEY123/Name") == nil)
        #expect(Self.title(nil) == nil)
    }

    // (m) cm-126: an Agent Pane keeps today's title, whatever else holds
    @Test func agentPaneKeepsTodaysTitle() {
        #expect(Self.title(address: Self.frame, agent: true, known: "cm-73 - figma native pane") == nil)
        #expect(Self.title(Self.file, agent: true, page: "cm-73 - figma native pane", shows: false) == nil)
    }

    // The private TEMP file in the preview, before Figma's Log in shows.
    @Test func privateFileLinkReadsItsName() {
        let pasted = URL(string: "https://www.figma.com/design/ipYfv7jhPJeqH0ZIv83pVd/TEMP?node-id=12-2")!
        let preview = (try? FigmaPaneURL.destination(for: pasted).url) ?? pasted
        #expect(Self.title(address: preview) == "Figma (TEMP)")
    }

    // A new file once Figma gives it a key: Figma's own name for it.
    @Test func newFileWithKeyReadsFigmasUntitled() {
        #expect(Self.title("https://www.figma.com/design/NEWKEY123/Untitled", page: "Untitled") == "Figma (Untitled)")
        #expect(Self.title("https://www.figma.com/design/NEWKEY123", page: "Untitled") == "Figma (Untitled)")
    }

    // An empty name from either source reads as no name, never `Figma ()`.
    @Test func emptyNameReadsFigma() {
        #expect(Self.title("https://www.figma.com/design/KEY123", page: "") == "Figma")
    }
}
