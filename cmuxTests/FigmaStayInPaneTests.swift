import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The check shared by both places where cmux chooses a new tab. A wrong yes
/// would keep ordinary links from opening tabs, so the refusals carry the risk.
@Suite("FigmaStayInPane")
struct FigmaStayInPaneTests {

    private static let wrapper = URL(fileURLWithPath: "/tmp/cmux-test/figma-embed.html")
    private static let readView = URL(string: "file:///tmp/cmux-test/figma-embed.html?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fslug%3Fnode-id%3D12-7")!
    private static let openInFigma = "https://www.figma.com/file/KEY/slug?node-id=12-7"

    private func stays(
        pane: URL? = readView,
        omnibarVisible: Bool = false,
        target: String? = openInFigma
    ) -> Bool {
        FigmaStayInPane.shouldLoadInThisPane(
            paneURL: pane,
            isOmnibarVisible: omnibarVisible,
            target: target.flatMap { URL(string: $0) },
            wrapper: Self.wrapper
        )
    }

    @Test("a Figma file link from the read view of a pane with no address bar loads in that pane")
    func staysForTheOpenInFigmaMark() {
        #expect(stays())
        #expect(stays(target: "https://www.figma.com/design/KEY/slug?node-id=12-7&t=abc"))
        #expect(stays(target: "https://figma.com/file/KEY/slug"))
    }

    @Test("with its address bar showing, the pane still opens a new tab")
    func addressBarShowingMeansANewTab() {
        #expect(!stays(omnibarVisible: true))
    }

    @Test("only the read view stays: the editor, another page and the embed's own address do not")
    func onlyTheReadViewStays() {
        #expect(!stays(pane: URL(string: "https://www.figma.com/design/KEY/slug")))
        #expect(!stays(pane: URL(string: "https://example.com/")))
        #expect(!stays(pane: URL(string: "https://embed.figma.com/design/KEY/slug")))
        #expect(!stays(pane: URL(string: "file:///tmp/elsewhere/figma-embed.html?embed=x")))
        #expect(!stays(pane: nil))
    }

    @Test("a sign-in, help or other address opens a new tab as it does today")
    func otherTargetsOpenANewTab() {
        for target in [
            "https://www.figma.com/login",
            "https://www.figma.com/files/recent",
            "https://help.figma.com/hc/en-us",
            "https://example.com/",
            "https://example.com/file/KEY/slug",
            "https://www.figma.com.example.com/file/KEY/slug"
        ] {
            #expect(!stays(target: target), "\(target)")
        }
        #expect(!stays(target: nil))
    }

    @Test("a target that is not a strict Figma file link opens a new tab")
    func looseTargetsOpenANewTab() {
        #expect(!stays(target: "http://www.figma.com/file/KEY/slug"))
        #expect(!stays(target: "https://www.figma.com/file/../community"))
        #expect(!stays(target: "https://embed.figma.com/design/KEY/slug"))
    }

    @Test("the file list: Figma's recent files page is not the read view, so no link from it stays in the pane (cm-73.9 holds the rule as built)")
    func theFileListStaysOutOfThePane() {
        let fileList = URL(string: "https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed")
        let file = "https://www.figma.com/design/KEY/a"
        // Rows 1 and 2 of Scenario 86, restated beside the new ones.
        #expect(stays(target: file))
        #expect(!stays(pane: URL(string: file), target: "https://www.figma.com/design/OTHER/b"))
        // Row 3: the file list, no address bar, a file.
        #expect(!stays(pane: fileList, target: file))
        // Row 4: the file list, address bar shown, a file.
        #expect(!stays(pane: fileList, omnibarVisible: true, target: file))
        // Row 5: the file list, no address bar, a help page.
        #expect(!stays(pane: fileList, target: "https://help.figma.com/hc"))
    }
}
