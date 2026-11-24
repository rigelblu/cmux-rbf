import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf #cm-126.3, #cm-126.14: the Agent Pane's rules, over plain values.

@Suite("AgentPaneMark")
struct AgentPaneMarkTests {

    private let terminalA = UUID()
    private let terminalB = UUID()

    private func agentPane(_ owner: UUID, id: UUID = UUID()) -> AgentPaneMark.Candidate {
        .init(panelID: id, owner: owner, kind: .agentPane)
    }

    @Test("isAgentPaneKind needs an owner and the Agent Pane kind: a Figma pane with an owner and no kind is not one")
    func isAgentPaneKindNeedsOwnerAndKind() {
        #expect(AgentPaneMark.isAgentPaneKind(owner: terminalA, kind: .agentPane))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: terminalA, kind: nil))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: nil, kind: .agentPane))
        #expect(!AgentPaneMark.isAgentPaneKind(owner: nil, kind: nil))
    }

    @Test("panes(ownedBy:) keeps only that terminal's panes, in the order given")
    func panesOwnedByKeepsTheOwnersOnly() {
        let first = agentPane(terminalA)
        let others = agentPane(terminalB)
        let figmaPane = AgentPaneMark.Candidate(panelID: UUID(), owner: terminalA, kind: nil)
        let second = agentPane(terminalA)
        let plain = AgentPaneMark.Candidate(panelID: UUID(), owner: nil, kind: nil)
        let found = AgentPaneMark.panes(ownedBy: terminalA, among: [first, others, figmaPane, second, plain])
        #expect(found == [first.panelID, second.panelID])
    }

    @Test("placement with no Agent Pane opens one")
    func placementWithNoneOpens() {
        #expect(AgentPaneMark.placement(panes: []) == .open)
    }

    @Test("placement with one Agent Pane steers it, with no others")
    func placementWithOneNavigates() {
        let id = UUID()
        #expect(AgentPaneMark.placement(panes: [id]) == .navigate(id, others: 0))
    }

    @Test("placement with two panes steers the first and counts the second")
    func placementWithTwoNavigatesTheFirst() {
        let first = UUID()
        let second = UUID()
        #expect(AgentPaneMark.placement(panes: [first, second]) == .navigate(first, others: 1))
    }

    @Test("picture is the mark for an Agent Pane, whatever the page's own icon")
    func pictureIsTheMarkForAnAgentPane() {
        let own = Data([1, 2, 3])
        #expect(AgentPaneMark.picture(isAgentPaneKind: true, own: own) == AgentPaneMark.shippedPicture)
        #expect(AgentPaneMark.picture(isAgentPaneKind: true, own: nil) == AgentPaneMark.shippedPicture)
    }

    @Test("picture is the page's own icon for a plain pane")
    func pictureIsTheOwnIconOtherwise() {
        let own = Data([1, 2, 3])
        #expect(AgentPaneMark.picture(isAgentPaneKind: false, own: own) == own)
        #expect(AgentPaneMark.picture(isAgentPaneKind: false, own: nil) == nil)
    }

    @Test("an Agent Pane title is its localized fixed caption")
    func agentPaneTitleIsFixed() {
        #expect(AgentPaneMark.title(isAgentPaneKind: true, own: "Page title") == "Agent Pane")
    }

    @Test("a plain browser pane keeps its own title")
    func plainPaneTitleIsUnchanged() {
        #expect(AgentPaneMark.title(isAgentPaneKind: false, own: "Page title") == "Page title")
    }

    @Test("the mark is the window, a 64 by 64 pixel PNG")
    func theMarkIsTheWindowAt64Pixels() throws {
        let bitmap = try #require(NSBitmapImageRep(data: AgentPaneMark.shippedPicture))
        // Require, don't expect: the pixel reads below assume 64 × 64 and would run past a smaller picture's buffer.
        try #require(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
        // Read bytes, not `colorAt`, which converts colour spaces. Check the layout `rgba` assumes before reading.
        try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4 && !bitmap.isPlanar
            && !bitmap.bitmapFormat.contains(.alphaFirst))
        let bytes = try #require(bitmap.bitmapData)
        func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let p = bytes + y * bitmap.bytesPerRow + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
        }
        #expect(rgba(0, 0).a == 0, "the corner outside the frame is clear")
        let sash = rgba(9, 20), cross = rgba(32, 32)
        #expect(sash.r > 240 && sash.g > 240 && sash.b > 240 && sash.a == 255, "the frame is white: \(sash)")
        #expect(cross.r > 240 && cross.g > 240 && cross.b > 240 && cross.a == 255, "the cross is white: \(cross)")
        // cmux-rbf: changed on purpose (#cm-126.13, 2026-11-18). Was one blue-to-red-orange gradient across the four panes
        // and a grey border; Tom asked for no reddish panes, each pane its own colour, pixelated glass and no border.
        let edge = rgba(6, 32)
        #expect(edge.r > 240 && edge.g > 240 && edge.b > 240, "no grey border on the frame's edge: \(edge)")
        // Each pane: its base-colour cell, and a lighter cell of the same pane (the 3 × 3 tint blocks).
        let green = rgba(13, 14), greenLight = rgba(13, 20)
        let blue = rgba(43, 20), blueLight = rgba(37, 14)
        let yellow = rgba(20, 36), yellowLight = rgba(13, 36)
        let purple = rgba(43, 49), purpleLight = rgba(43, 36)
        #expect(green.g > green.r + 60 && green.g > green.b + 50, "top-left is green: \(green)")
        #expect(blue.b > blue.r + 100 && blue.b > blue.g + 50, "top-right is blue: \(blue)")
        #expect(yellow.r > 230 && yellow.g > 170 && yellow.b < yellow.g - 80, "bottom-left is yellow: \(yellow)")
        #expect(purple.r > purple.g + 50 && purple.b > purple.g + 70, "bottom-right is purple: \(purple)")
        for (name, base, light) in [("green", green, greenLight), ("blue", blue, blueLight),
                                    ("yellow", yellow, yellowLight), ("purple", purple, purpleLight)] {
            // No channel near black, the way the old red-orange (≈ 229, 57, 53) had.
            #expect(min(base.r, base.g, base.b) > 60, "the \(name) pane is no strong red or orange: \(base)")
            let gap = max(abs(light.r - base.r), abs(light.g - base.g), abs(light.b - base.b))
            #expect(gap >= 30, "the \(name) pane's glass is pixelated, not flat: \(base) vs \(light)")
        }
    }

    @Test("paneHoldsAgentPane is true only for a pane with an Agent Pane among its tabs")
    func paneHoldsAgentPane() {
        let plain = AgentPaneMark.Candidate(panelID: UUID(), owner: nil, kind: nil)
        let figmaPane = AgentPaneMark.Candidate(panelID: UUID(), owner: terminalA, kind: nil)
        #expect(AgentPaneMark.paneHoldsAgentPane([plain, agentPane(terminalA)]))
        #expect(!AgentPaneMark.paneHoldsAgentPane([plain, figmaPane]))
        #expect(!AgentPaneMark.paneHoldsAgentPane([]))
    }

    @Test("the app's own page check refuses other schemes and Figma addresses, and takes file, https and http")
    func appRefusesSchemesAndFigma() throws {
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "javascript:alert(1)"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "data:text/html,x"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "about:blank"))) == .badScheme)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "https://www.figma.com/design/K/x?node-id=1-2"))) == .figmaAddress)
        // cmux-rbf (#cm-126.3, #cm-73.40, #cm-142.1): cmux's page moved from cmux-figma: to an https address under
        // www.figma.com (#cm-73.40). The old address is refused for its scheme, the new one as a Figma address.
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.legacyServedPageURL) == .badScheme)
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.previewPageURL) == .figmaAddress)
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.wrapperFileURL()) == .figmaAddress)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "https://example.org/"))) == nil)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "http://localhost:8000/p.html"))) == nil)
        #expect(AgentPaneMark.refusal(for: URL(fileURLWithPath: "/tmp/p1.html")) == nil)
    }

    // MARK: - cmux-rbf #cm-126.14: State transition table

    @Test("isCleared is true for a URL inside the cleared folder and false for every other page")
    func isClearedDerivation() {
        let clearedFolder = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/cleared")
        let clearedPage = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/cleared/pane-1.html")
        let otherFolderPage = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/other/pane-1.html")
        let tmpPage = URL(fileURLWithPath: "/Volumes/tom-ssd/tmp/page.html")
        let webURL = URL(string: "https://example.com/cleared/pane-1.html")

        #expect(AgentPaneMark.isCleared(url: clearedPage, clearedFolderURL: clearedFolder))
        #expect(!AgentPaneMark.isCleared(url: otherFolderPage, clearedFolderURL: clearedFolder))
        #expect(!AgentPaneMark.isCleared(url: tmpPage, clearedFolderURL: clearedFolder))
        #expect(!AgentPaneMark.isCleared(url: webURL, clearedFolderURL: clearedFolder))
        #expect(!AgentPaneMark.isCleared(url: nil, clearedFolderURL: clearedFolder))
    }

    @Test("isClearedPageURL checks directory boundary, scheme, dot-dot traversal, and symlinks")
    func isClearedPageURLBoundaryCheck() throws {
        let clearedFolder = URL(fileURLWithPath: "/app/cleared")
        let inside = URL(fileURLWithPath: "/app/cleared/1.html")
        let siblingWithCommonPrefix = URL(fileURLWithPath: "/app/cleared-other/1.html")
        let folderItself = URL(fileURLWithPath: "/app/cleared")
        let httpsWithSamePath = try #require(URL(string: "https://example.com/app/cleared/1.html"))
        let dotDotTraversal = URL(fileURLWithPath: "/app/cleared/../x.html")

        #expect(AgentPaneMark.isClearedPageURL(inside, in: clearedFolder))
        #expect(!AgentPaneMark.isClearedPageURL(siblingWithCommonPrefix, in: clearedFolder))
        #expect(!AgentPaneMark.isClearedPageURL(folderItself, in: clearedFolder))
        #expect(!AgentPaneMark.isClearedPageURL(httpsWithSamePath, in: clearedFolder))
        #expect(!AgentPaneMark.isClearedPageURL(dotDotTraversal, in: clearedFolder))

        // Symlinked folder check
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("AgentPaneMarkTests-\(UUID().uuidString)")
        let realDir = tempRoot.appendingPathComponent("real-cleared")
        let symlinkDir = tempRoot.appendingPathComponent("symlink-cleared")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        let fileInRealDir = realDir.appendingPathComponent("pane.html")
        try Data("<html></html>".utf8).write(to: fileInRealDir)
        let fileViaSymlink = symlinkDir.appendingPathComponent("pane.html")
        #expect(AgentPaneMark.isClearedPageURL(fileInRealDir, in: symlinkDir))
        #expect(AgentPaneMark.isClearedPageURL(fileViaSymlink, in: realDir))
    }

    // MARK: - clear's page (cm-126.14)

    @Test("the cleared page is one file named by the pane's id, inside the cleared folder")
    func clearedPageIsNamedByThePanesID() {
        let folder = URL(fileURLWithPath: "/app/cleared", isDirectory: true)
        let a = UUID()
        let b = UUID()
        #expect(AgentPaneMark.clearedPageURL(panelID: a, in: folder).path == "/app/cleared/\(a.uuidString).html")
        #expect(AgentPaneMark.clearedPageURL(panelID: a, in: folder) != AgentPaneMark.clearedPageURL(panelID: b, in: folder))
        #expect(AgentPaneMark.isClearedPageURL(AgentPaneMark.clearedPageURL(panelID: a, in: folder), in: folder))
    }

    @Test("a page is removed when Tom closes the pane, and only then")
    func removesClearedPageOnlyWhenTomCloses() {
        for origin in ["tab_close", "pane_close"] {
            #expect(AgentPaneMark.removesClearedPage(origin: origin, closePanel: true, appIsTerminating: false))
            #expect(!AgentPaneMark.removesClearedPage(origin: origin, closePanel: false, appIsTerminating: false), "a move")
            #expect(!AgentPaneMark.removesClearedPage(origin: origin, closePanel: true, appIsTerminating: true), "a quit")
        }
        for origin in ["workspace_teardown", "terminal_respawn", ""] {
            #expect(!AgentPaneMark.removesClearedPage(origin: origin, closePanel: true, appIsTerminating: false), "\(origin)")
        }
    }

    private static let probePage = """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Nothing to answer right now</title>
        <style>
          html, body { height: 100%; margin: 0; }
          body { display: flex; flex-direction: column; align-items: center; justify-content: center;
                 font: 13px -apple-system, system-ui, sans-serif; color: -apple-system-secondary-label; background: Canvas; }
          p { margin: 0; }
          p + p { margin-top: 1.4em; }
          a { color: inherit; text-decoration: underline; text-underline-offset: 2px; }
        </style></head>
        <body><p>Nothing to answer right now</p><p><a href="file:///Volumes/tom-ssd/tmp/cm-126/pages/update-2026-11-17T004357.991Z.html">The last post</a></p></body></html>

        """

    @Test("the cleared page is the captured design: its text, its link to the last post, light or dark")
    func clearedPageIsTheCapturedDesign() throws {
        let last = try #require(URL(string: "file:///Volumes/tom-ssd/tmp/cm-126/pages/update-2026-11-17T004357.991Z.html"))
        #expect(AgentPaneMark.clearedPageHTML(
            title: "Nothing to answer right now", linkText: "The last post", previousURL: last
        ) == Self.probePage)
    }

    @Test("with no earlier page the link is left out; the text and the title stay")
    func clearedPageWithoutAPreviousPageHasNoLink() {
        let html = AgentPaneMark.clearedPageHTML(title: "Nothing to answer right now", linkText: "The last post", previousURL: nil)
        #expect(html.contains("<body><p>Nothing to answer right now</p></body>"))
        #expect(!html.contains("<a "))
        #expect(!html.contains("The last post"))
    }

    @Test("a title, link text or address with markup is escaped, never written as markup")
    func clearedPageEscapesItsInputs() throws {
        let url = try #require(URL(string: "https://example.org/a?x=1&y=%22\"><script>"))
        let html = AgentPaneMark.clearedPageHTML(title: "<b>&'\"", linkText: "<i>post</i>", previousURL: url)
        #expect(!html.contains("<b>"))
        #expect(!html.contains("<i>"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;b&gt;&amp;&#39;&quot;"))
        #expect(html.contains("&lt;i&gt;post&lt;/i&gt;"))
        #expect(html.contains("x=1&amp;y="))
    }

    // MARK: - the cleared page's link (cm-126.14, step 3d)

    @Test("the link on a cleared page reads back as the address it was written with, special characters included")
    func clearedPageLinkRoundTrips() throws {
        let url = try #require(URL(string: "file:///posts/a%20b.html?x=1&y=%22#frag"))
        let html = AgentPaneMark.clearedPageHTML(title: "T", linkText: "L", previousURL: url)
        #expect(AgentPaneMark.clearedPageLink(inHTML: html) == url)
        #expect(AgentPaneMark.clearedPageLink(inHTML: AgentPaneMark.clearedPageHTML(title: "T", linkText: "L", previousURL: nil)) == nil)
        #expect(AgentPaneMark.clearedPageLink(inHTML: "<p>no link</p>") == nil)
    }

    @Test("the link is read from the page file; a missing file, a non-file address and no address give none")
    func clearedPageLinkAtAFile() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cm-126.14-link-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let post = try #require(URL(string: "file:///posts/one.html"))
        let page = folder.appendingPathComponent("pane.html")
        try Data(AgentPaneMark.clearedPageHTML(title: "T", linkText: "L", previousURL: post).utf8).write(to: page)
        #expect(AgentPaneMark.clearedPageLink(at: page) == post)
        #expect(AgentPaneMark.clearedPageLink(at: folder.appendingPathComponent("missing.html")) == nil)
        #expect(AgentPaneMark.clearedPageLink(at: URL(string: "https://example.org/")) == nil)
        #expect(AgentPaneMark.clearedPageLink(at: nil) == nil)
    }

    private static let handOverFolder = URL(fileURLWithPath: "/app/cleared", isDirectory: true)
    private static let handOverSource = URL(fileURLWithPath: "/app/cleared/pane.html")
    private static let handOverLink = URL(string: "file:///posts/one.html")!

    private func hands(
        linkActivation: Bool = true,
        mainFrame: Bool = true,
        agentPane: Bool = true,
        source: URL? = AgentPaneMarkTests.handOverSource,
        target: URL = AgentPaneMarkTests.handOverLink,
        pageLink: URL? = AgentPaneMarkTests.handOverLink,
        folder: URL? = AgentPaneMarkTests.handOverFolder
    ) -> Bool {
        AgentPaneMark.handsLinkToApp(
            isLinkActivation: linkActivation, isMainFrame: mainFrame, isAgentPane: agentPane,
            source: source, target: target, clearedFolderURL: folder, pageLink: { pageLink }
        )
    }

    @Test("the click on a cleared page's own link is handed to the app")
    func handsTheClearedPagesOwnLink() {
        #expect(hands())
    }

    @Test("every other click goes through the browser's usual checks")
    func handsNothingElse() throws {
        #expect(!hands(target: URL(string: "file:///posts/two.html")!), "a link the page doesn't carry")
        #expect(!hands(source: URL(fileURLWithPath: "/elsewhere/page.html")), "a page that isn't a cleared page")
        #expect(!hands(source: URL(fileURLWithPath: "/app/cleared-other/pane.html")), "a folder with a common prefix")
        #expect(!hands(source: try #require(URL(string: "https://example.org/app/cleared/pane.html"))), "an https page at the same path")
        #expect(!hands(source: nil), "no page")
        #expect(!hands(pageLink: nil), "a page with no link")
        #expect(!hands(folder: nil), "no cleared folder")
        let web = try #require(URL(string: "https://example.org/post"))
        #expect(!hands(target: web, pageLink: web), "a web page, even when the page links it")
        let clearedTarget = URL(fileURLWithPath: "/app/cleared/other.html")
        #expect(!hands(target: clearedTarget, pageLink: clearedTarget), "another cleared page")
        #expect(!hands(target: URL(string: "file:///posts/one.html#frag")!), "the link with something added")
    }

    @Test("each guard on its own refuses: not a link click, not the main frame, not an Agent Pane")
    func handsNothingWithoutEachNavigationGuard() {
        #expect(!hands(linkActivation: false), "a reload, back/forward, form or script navigation")
        #expect(!hands(mainFrame: false), "a subframe")
        #expect(!hands(agentPane: false), "a pane that is not an Agent Pane")
    }

    @Test("the page's file is read only once every other guard has passed")
    func handsReadsThePageOnlyAtTheEnd() {
        func reads(_ call: (_ read: @escaping () -> URL?) -> Bool) -> (decision: Bool, count: Int) {
            var count = 0
            let decision = call { count += 1; return Self.handOverLink }
            return (decision, count)
        }
        func decide(
            linkActivation: Bool = true, mainFrame: Bool = true, agentPane: Bool = true,
            source: URL? = Self.handOverSource, target: URL = Self.handOverLink
        ) -> (decision: Bool, count: Int) {
            reads { read in
                AgentPaneMark.handsLinkToApp(
                    isLinkActivation: linkActivation, isMainFrame: mainFrame, isAgentPane: agentPane,
                    source: source, target: target, clearedFolderURL: Self.handOverFolder, pageLink: read
                )
            }
        }
        #expect(decide() == (true, 1))
        #expect(decide(linkActivation: false).count == 0)
        #expect(decide(mainFrame: false).count == 0)
        #expect(decide(agentPane: false).count == 0)
        #expect(decide(source: URL(fileURLWithPath: "/elsewhere/page.html")).count == 0, "not a cleared page: no disk read")
        #expect(decide(source: nil).count == 0)
        #expect(decide(target: URL(string: "https://example.org/")!).count == 0)
        #expect(decide(target: URL(fileURLWithPath: "/app/cleared/other.html")).count == 0)
    }

    @Test("a clear links the page the pane shows; on a cleared page it links the last post, then the page's own link; never a cleared page")
    func linkTargetNeverLinksAClearedPage() throws {
        let folder = Self.handOverFolder
        let cleared = Self.handOverSource
        let otherCleared = URL(fileURLWithPath: "/app/cleared/other.html")
        let post1 = try #require(URL(string: "https://example.org/one"))
        let post2 = try #require(URL(string: "https://example.org/two"))
        func target(_ shown: URL?, _ recorded: URL?, _ link: URL?) -> URL? {
            AgentPaneMark.linkTarget(shown: shown, recordedPost: recorded, pageLink: { link }, clearedFolderURL: folder)
        }
        #expect(target(post1, post2, nil) == post1, "a post shown now wins over the record")
        #expect(target(cleared, post2, post1) == post2, "back on the cleared page: the last post shown")
        #expect(target(cleared, nil, post1) == post1, "no record: the link the page has")
        #expect(target(cleared, otherCleared, post1) == post1, "a record that is a cleared page is skipped")
        #expect(target(cleared, otherCleared, otherCleared) == nil, "never a cleared page")
        #expect(target(cleared, nil, nil) == nil)
        #expect(target(nil, post1, post2) == nil, "no page shown")
    }

    @Test("a clear reads the cleared page's file only when the shown page and the record give nothing")
    func linkTargetReadsTheFileLast() throws {
        let folder = Self.handOverFolder
        let cleared = Self.handOverSource
        let post = try #require(URL(string: "https://example.org/one"))
        func reads(shown: URL?, recorded: URL?) -> Int {
            var count = 0
            _ = AgentPaneMark.linkTarget(shown: shown, recordedPost: recorded, pageLink: { count += 1; return post }, clearedFolderURL: folder)
            return count
        }
        #expect(reads(shown: post, recorded: nil) == 0, "a post is shown: nothing to read")
        #expect(reads(shown: nil, recorded: nil) == 0)
        #expect(reads(shown: cleared, recorded: post) == 0, "a recorded post settles it")
        #expect(reads(shown: cleared, recorded: nil) == 1)
        #expect(reads(shown: cleared, recorded: URL(fileURLWithPath: "/app/cleared/other.html")) == 1)
    }

    // Found in Scenario 36 (2026-11-18): a post's link to a file in another folder is refused by WebKit, the pane lands
    // on about:blank ("Can't open this page"), and the clear linked "The last post" to about:blank.
    @Test("a clear made on a page that failed to load links the last post, or nothing; never about:blank")
    func linkTargetSkipsAPageThatFailedToLoad() throws {
        let folder = Self.handOverFolder
        let blank = try #require(URL(string: "about:blank"))
        let post = URL(fileURLWithPath: "/Volumes/tom-ssd/tmp/posts/post-4.html")
        let otherCleared = URL(fileURLWithPath: "/app/cleared/other.html")
        func target(_ shown: URL?, _ recorded: URL?) -> URL? {
            AgentPaneMark.linkTarget(shown: shown, recordedPost: recorded, pageLink: { nil }, clearedFolderURL: folder)
        }
        #expect(target(blank, post) == post, "the post the agent showed last")
        #expect(target(blank, nil) == nil, "no record: no link")
        #expect(target(blank, otherCleared) == nil, "never a cleared page")
        let data = try #require(URL(string: "data:text/html,hi"))
        #expect(target(data, post) == post, "any page that isn't file, https or http links the post")
        let figma = try #require(URL(string: "https://www.figma.com/design/AAAAAAAAAAAAAAAAAAAAAA/board"))
        #expect(target(figma, post) == figma, "a Figma page Tom went to is a page: it keeps its own link")
    }

    // MARK: - the name for the pane's agent (cmux-rbf #cm-126.15)

    private let names = ["claude": "wg-still Outie", "*": "Agent Outie"]

    @Test("name: an exact slug beats *, and an agent with no entry takes *")
    func nameExactBeatsStar() {
        #expect(AgentPaneMark.name(agent: "claude", names: names) == "wg-still Outie")
        #expect(AgentPaneMark.name(agent: "codex", names: names) == "Agent Outie")
    }

    @Test("name: with no entry for the slug and none for *, there is no name")
    func nameNoneWithoutEntries() {
        #expect(AgentPaneMark.name(agent: "codex", names: ["claude": "wg-still Outie"]) == nil)
        #expect(AgentPaneMark.name(agent: nil, names: ["claude": "wg-still Outie"]) == nil)
        #expect(AgentPaneMark.name(agent: "claude", names: [:]) == nil)
    }

    @Test("name: * alone names every agent's pane, and an agent that is not known too")
    func nameStarOnly() {
        #expect(AgentPaneMark.name(agent: "claude", names: ["*": "Agent Outie"]) == "Agent Outie")
        #expect(AgentPaneMark.name(agent: nil, names: ["*": "Agent Outie"]) == "Agent Outie")
        #expect(AgentPaneMark.name(agent: "", names: ["*": "Agent Outie"]) == "Agent Outie")
    }

    @Test("name: the agent is normalized: case, spaces, and the launcher and lifecycle spellings")
    func nameNormalizesTheAgent() {
        #expect(AgentPaneMark.name(agent: " Claude ", names: ["claude": "Outie"]) == "Outie")
        #expect(AgentPaneMark.name(agent: "claudeteams", names: ["claude": "Outie"]) == "Outie")
        #expect(AgentPaneMark.name(agent: "codexTeams", names: ["codex": "Codex Outie", "*": "x"]) == "Codex Outie")
        #expect(AgentPaneMark.name(agent: "claude_code", names: ["claude": "Outie"]) == "Outie")
    }

    @Test("normalizedAgentSlug trims, lowercases and reads the launcher spellings; empty is none")
    func slugNormalizer() {
        #expect(AgentPaneMark.normalizedAgentSlug(" Claude ") == "claude")
        #expect(AgentPaneMark.normalizedAgentSlug("claudeteams") == "claude")
        #expect(AgentPaneMark.normalizedAgentSlug("codexTeams") == "codex")
        #expect(AgentPaneMark.normalizedAgentSlug("claude_code") == "claude")
        #expect(AgentPaneMark.normalizedAgentSlug("gemini") == "gemini")
        #expect(AgentPaneMark.normalizedAgentSlug("  ") == nil)
        #expect(AgentPaneMark.normalizedAgentSlug(nil) == nil)
    }

    @Test("title: the name Tom set, else Agent Pane; a plain pane keeps its own title, whatever the name")
    func titleOrder() {
        #expect(AgentPaneMark.title(isAgentPaneKind: true, own: "Page", name: "wg-still Outie") == "wg-still Outie")
        #expect(AgentPaneMark.title(isAgentPaneKind: true, own: "Page", name: nil) == "Agent Pane")
        #expect(AgentPaneMark.title(isAgentPaneKind: false, own: "Page", name: "Outie") == "Page")
    }

    @Test("agent: a show that sent one records it, and the one live agent wins when it differs")
    func agentSentAndLive() {
        #expect(AgentPaneMark.agent(sent: "claude", saved: nil, liveAgentKeys: []) == "claude")
        #expect(AgentPaneMark.agent(sent: "codex", saved: "claude", liveAgentKeys: []) == "codex")
        #expect(AgentPaneMark.agent(sent: "claudeteams", saved: nil, liveAgentKeys: ["claude_code"]) == "claude")
        // An inherited variable: gemini runs, the variable still says claude.
        #expect(AgentPaneMark.agent(sent: "claude", saved: nil, liveAgentKeys: ["gemini"]) == "gemini")
        // Two live agents: the variable stands.
        #expect(AgentPaneMark.agent(sent: "claude", saved: nil, liveAgentKeys: ["gemini", "codex"]) == "claude")
        #expect(AgentPaneMark.agent(sent: "claude", saved: nil, liveAgentKeys: ["claude_code", "claude"]) == "claude")
    }

    @Test("agent: a show that sent none takes the one live agent, else keeps the saved one, else none")
    func agentNoneSent() {
        // The one live agent beats a stale saved one: Claude exited and an unwrapped agent started in the terminal.
        #expect(AgentPaneMark.agent(sent: nil, saved: "claude", liveAgentKeys: ["gemini"]) == "gemini")
        // No live agent (exit, Clear Agent State, a restart), or two: the saved one stands.
        #expect(AgentPaneMark.agent(sent: nil, saved: "claude", liveAgentKeys: []) == "claude")
        #expect(AgentPaneMark.agent(sent: nil, saved: "claude", liveAgentKeys: ["gemini", "codex"]) == "claude")
        #expect(AgentPaneMark.agent(sent: nil, saved: nil, liveAgentKeys: ["claude_code"]) == "claude")
        #expect(AgentPaneMark.agent(sent: nil, saved: nil, liveAgentKeys: ["gemini", "codex"]) == nil)
        #expect(AgentPaneMark.agent(sent: nil, saved: nil, liveAgentKeys: []) == nil)
        #expect(AgentPaneMark.agent(sent: "  ", saved: "codex", liveAgentKeys: []) == "codex")
    }
}
