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

    // cmux-rbf #cm-126.14: title with wroteAt set shows "You wrote <time>" for an Agent Pane, but leaves a plain pane unchanged
    @Test("title with wroteAt formats as 'You wrote <time>' for Agent Pane and leaves plain pane unchanged")
    func titleWithWroteAtFormatsForAgentPane() {
        let time = Date(timeIntervalSince1970: 1731815520) // 2024-11-17 03:52:00 UTC
        let gmt = TimeZone(secondsFromGMT: 0)!
        let enUS = Locale(identifier: "en_US")
        let enGB = Locale(identifier: "en_GB")

        let agentTitleUS = AgentPaneMark.title(isAgentPaneKind: true, own: "Page title", wroteAt: time, locale: enUS, timeZone: gmt)
        #expect(agentTitleUS == "You wrote 3:52\u{202F}AM")

        let agentTitleGB = AgentPaneMark.title(isAgentPaneKind: true, own: "Page title", wroteAt: time, locale: enGB, timeZone: gmt)
        #expect(agentTitleGB == "You wrote 3:52")

        let defaultAgentTitle = AgentPaneMark.title(isAgentPaneKind: true, own: "Page title", wroteAt: time)
        #expect(defaultAgentTitle == "You wrote \(time.formatted(date: .omitted, time: .shortened))")

        let plainTitleWithTime = AgentPaneMark.title(isAgentPaneKind: false, own: "Page title", wroteAt: time, locale: enUS, timeZone: gmt)
        #expect(plainTitleWithTime == "Page title")

        let plainTitleWithoutTime = AgentPaneMark.title(isAgentPaneKind: false, own: "Page title", wroteAt: nil)
        #expect(plainTitleWithoutTime == "Page title")

        let agentTitleWithoutTime = AgentPaneMark.title(isAgentPaneKind: true, own: "Page title", wroteAt: nil)
        #expect(agentTitleWithoutTime == "Agent Pane")
    }

    // cmux-rbf: changed on purpose (#cm-126.13). Was `theMarkIsA32PixelPNG`, for `.3`'s SF Symbol `eyeglasses` at 32 px.
    // The mark is now Tom's window, a 64 px PNG: 64 so it stays sharp when the tab font scales the 14 pt slot.
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
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.previewPageURL) == .badScheme)
        #expect(AgentPaneMark.refusal(for: FigmaPaneURL.wrapperFileURL()) == .figmaAddress)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "https://example.org/"))) == nil)
        #expect(AgentPaneMark.refusal(for: try #require(URL(string: "http://localhost:8000/p.html"))) == nil)
        #expect(AgentPaneMark.refusal(for: URL(fileURLWithPath: "/tmp/p1.html")) == nil)
    }

    // MARK: - cmux-rbf #cm-126.14: State transition table

    @Test("AgentPaneAnswerState transition table covers every state and event pair")
    func answerStateTransitions() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)

        // Any + show -> .post
        #expect(AgentPaneAnswerState.next(state: .post, event: .show) == .post)
        #expect(AgentPaneAnswerState.next(state: .wroteSince(t1), event: .show) == .post)
        #expect(AgentPaneAnswerState.next(state: .cleared, event: .show) == .post)

        // Any + clear -> .cleared
        #expect(AgentPaneAnswerState.next(state: .post, event: .clear) == .cleared)
        #expect(AgentPaneAnswerState.next(state: .wroteSince(t1), event: .clear) == .cleared)
        #expect(AgentPaneAnswerState.next(state: .cleared, event: .clear) == .cleared)

        // .post + tomWrote(t1) -> .wroteSince(t1)
        #expect(AgentPaneAnswerState.next(state: .post, event: .tomWrote(at: t1)) == .wroteSince(t1))

        // .wroteSince(t1) + tomWrote(t2) -> unchanged (first time kept)
        #expect(AgentPaneAnswerState.next(state: .wroteSince(t1), event: .tomWrote(at: t2)) == .wroteSince(t1))

        // .cleared + tomWrote(t1) -> .cleared
        #expect(AgentPaneAnswerState.next(state: .cleared, event: .tomWrote(at: t1)) == .cleared)
    }

    @Test("AgentPaneAnswerState helper properties")
    func answerStateHelpers() {
        let t1 = Date(timeIntervalSince1970: 1000)
        #expect(AgentPaneAnswerState.post.wroteAt == nil)
        #expect(AgentPaneAnswerState.post.isPost)
        #expect(!AgentPaneAnswerState.post.isCleared)

        #expect(AgentPaneAnswerState.wroteSince(t1).wroteAt == t1)
        #expect(!AgentPaneAnswerState.wroteSince(t1).isPost)
        #expect(!AgentPaneAnswerState.wroteSince(t1).isCleared)

        #expect(AgentPaneAnswerState.cleared.wroteAt == nil)
        #expect(!AgentPaneAnswerState.cleared.isPost)
        #expect(AgentPaneAnswerState.cleared.isCleared)
    }

    // MARK: - cmux-rbf #cm-126.14: Key rule, pure

    @Test("isCountedReturn counts pressed Return and keypad Enter with no modifiers")
    func isCountedReturnCountsPressOfReturnAndKeypadEnter() {
        #expect(AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: 0, isCommittedText: false, isComposing: false))
        #expect(AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x4C, modsRaw: 0, isCommittedText: false, isComposing: false))
    }

    @Test("isCountedReturn rejects key releases")
    func isCountedReturnRejectsReleases() {
        #expect(!AgentPaneMark.isCountedReturn(isPress: false, keycode: 0x24, modsRaw: 0, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: false, keycode: 0x4C, modsRaw: 0, isCommittedText: false, isComposing: false))
    }

    @Test("isCountedReturn rejects committed text")
    func isCountedReturnRejectsCommittedText() {
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: 0, isCommittedText: true, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x4C, modsRaw: 0, isCommittedText: true, isComposing: false))
    }

    @Test("isCountedReturn rejects IME composition commit and accumulatedText")
    func isCountedReturnRejectsComposing() {
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: 0, isCommittedText: false, isComposing: true))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x4C, modsRaw: 0, isCommittedText: false, isComposing: true))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: 0, isCommittedText: false, isComposing: false, hasAccumulatedText: true))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x4C, modsRaw: 0, isCommittedText: false, isComposing: false, hasAccumulatedText: true))
    }

    @Test("isCountedReturn allows Caps Lock and Num Lock alone or together")
    func isCountedReturnAllowsCapsLockAndNumLock() {
        let caps = AgentPaneMark.capsLockModMask
        let num = AgentPaneMark.numLockModMask
        #expect(AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: caps, isCommittedText: false, isComposing: false))
        #expect(AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: num, isCommittedText: false, isComposing: false))
        #expect(AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: caps | num, isCommittedText: false, isComposing: false))
    }

    @Test("isCountedReturn rejects modifiers other than Caps/Num lock")
    func isCountedReturnRejectsDisallowedModifiers() {
        let shift: UInt32 = 1 << 0
        let ctrl: UInt32 = 1 << 1
        let alt: UInt32 = 1 << 2
        let superMod: UInt32 = 1 << 3
        let shiftRight: UInt32 = 1 << 6
        let ctrlRight: UInt32 = 1 << 7
        let altRight: UInt32 = 1 << 8
        let superRight: UInt32 = 1 << 9

        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: shift, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: alt, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: ctrl, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: superMod, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: shiftRight, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: altRight, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: ctrlRight, isCommittedText: false, isComposing: false))
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: superRight, isCommittedText: false, isComposing: false))

        // Caps Lock + Shift is still rejected because Shift is present
        let capsAndShift = AgentPaneMark.capsLockModMask | shift
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x24, modsRaw: capsAndShift, isCommittedText: false, isComposing: false))
    }

    @Test("isCountedReturn rejects keys other than Return and keypad Enter")
    func isCountedReturnRejectsOtherKeys() {
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x31, modsRaw: 0, isCommittedText: false, isComposing: false)) // Space
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x35, modsRaw: 0, isCommittedText: false, isComposing: false)) // Escape
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0x00, modsRaw: 0, isCommittedText: false, isComposing: false)) // 'A'
        #expect(!AgentPaneMark.isCountedReturn(isPress: true, keycode: 0xFF, modsRaw: 0, isCommittedText: false, isComposing: false))
    }

    // MARK: - cmux-rbf #cm-126.14: Restore derivation, pure

    @Test("restoredState derives .cleared for URLs inside cleared folder and .post otherwise")
    func restoredStateDerivation() {
        let clearedFolder = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/cleared")
        let clearedPage = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/cleared/pane-1.html")
        let otherFolderPage = URL(fileURLWithPath: "/Users/test/Library/Application Support/cmux/other/pane-1.html")
        let tmpPage = URL(fileURLWithPath: "/Volumes/tom-ssd/tmp/page.html")
        let webURL = URL(string: "https://example.com/cleared/pane-1.html")

        #expect(AgentPaneMark.restoredState(url: clearedPage, clearedFolderURL: clearedFolder) == .cleared)
        #expect(AgentPaneMark.restoredState(url: otherFolderPage, clearedFolderURL: clearedFolder) == .post)
        #expect(AgentPaneMark.restoredState(url: tmpPage, clearedFolderURL: clearedFolder) == .post)
        #expect(AgentPaneMark.restoredState(url: webURL, clearedFolderURL: clearedFolder) == .post)
        #expect(AgentPaneMark.restoredState(url: nil, clearedFolderURL: clearedFolder) == .post)
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
}
