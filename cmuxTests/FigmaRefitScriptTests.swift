// cmux-rbf (#cm-73.46, #cm-73.44): Scenarios 300 and 316 for the scripts, run in JavaScriptCore.
// The harness is `FigmaMotionTests.browser`, the one `cm-73.37`'s tests use for the relay.
import Foundation
import JavaScriptCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("FigmaRefitScripts")
struct FigmaRefitScriptTests {
    private static let figma = "https://www.figma.com"
    // cmux-rbf #cm-73.40: the preview is a page on https://www.figma.com now; Figma's editor is too, told apart by its path.
    private static let cmuxOrigin = "https://www.figma.com"

    // MARK: Harness

    /// Figma's frame: `clockScript` on a still board, with a parent (cmux's page) and no child frames.
    private func frame(
        path: String = "/design/KEY/slug", ancestorOrigin: String? = nil, ancestors chain: [String]? = nil,
        topPath: String = "/cmux-preview/figma-embed.html", topIsAnotherOrigin: Bool = false,
        prelude: String = ""
    ) throws -> JSContext {
        let c = try #require(JSContext()); c.evaluateScript(FigmaMotionTests.browser)
        let ancestors = chain.map { "[" + $0.map { "'\($0)'" }.joined(separator: ",") + "]" }
            ?? ancestorOrigin.map { "['\($0)']" } ?? "undefined"
        c.evaluateScript("""
        window.name=''; window.parent={postMessage:function(m,t){posted.push(m); targets.push(t)}}; targets=[];
        location.hostname='www.figma.com'; location.pathname='\(path)'; location.ancestorOrigins=\(ancestors); window.top=\(topIsAnotherOrigin ? "{location:{get pathname(){throw new Error('SecurityError')}}}" : "{location:{pathname:'\(topPath)'}}");
        location.href='https://www.figma.com\(path)?node-id=12-2&embed-host=cmux&footer=false&theme=dark&page-selector=0';
        location.replace=function(s){replaced=s}; perfTime=20; wallTime=10000; performance={now:function(){return perfTime},timeOrigin:1793474311079.5};
        Date.now=function(){return wallTime}; canvas=false; raf=[]; requestAnimationFrame=function(f){raf.push(f)};
        document.querySelector=function(){return canvas ? {} : null};
        """)
        if !prelude.isEmpty { c.evaluateScript(prelude) }
        c.evaluateScript(FigmaMotion.clockScript)
        try #require(c.exception == nil, "clock script failed: \(String(describing: c.exception))")
        return c
    }

    /// cmux's page: `pageControllerScript` with the frame at `embed.figma.com`.
    private func page(marked: Bool = false, prelude: String = "") throws -> JSContext {
        let c = try #require(JSContext()); c.evaluateScript(FigmaMotionTests.browser)
        if !prelude.isEmpty { c.evaluateScript(prelude) }
        c.evaluateScript("location.search += '&motion=\(marked ? "1" : "0")'; frame.src += '&theme=light';")
        c.evaluateScript(FigmaMotion.pageScript())
        try #require(c.exception == nil, "page script failed: \(String(describing: c.exception))")
        return c
    }

    private func text(_ c: JSContext, _ js: String) -> String? { c.evaluateScript(js)?.toString() }
    private func bool(_ c: JSContext, _ js: String) -> Bool { c.evaluateScript(js)?.toBool() == true }

    /// A report from Figma's frame, as cmux's page receives it.
    private func report(
        _ c: JSContext, path: String = "/design/KEY/slug", drawn: Bool = true, player: Bool = false,
        nested: Bool? = nil, origin: String = figma, hostname: String = "www.figma.com"
    ) {
        let tag = nested.map { ",nested:\($0)" } ?? ""
        c.evaluateScript("""
        listeners.message({source:frame.contentWindow, origin:'\(origin)',
          data:{cmuxClockReport:true,player:\(player),drawn:\(drawn),mode:'freeze',hostname:'\(hostname)',path:'\(path)'\(tag)}})
        """)
    }
    private func lastReportPath(_ c: JSContext) -> String? {
        let value = c.evaluateScript("(window.__cmuxMotion.snapshot().report || {}).path")
        return value?.isUndefined == true ? nil : value?.toString()
    }

    private func key(
        _ c: JSContext, key: String = "!", code: String = "Digit1", shift: Bool = true, meta: Bool = false,
        alt: Bool = false, ctrl: Bool = false, repeating: Bool = false, target: String = "{tagName:'DIV'}"
    ) {
        c.evaluateScript("""
        prevented=false;
        listeners.keydown({key:'\(key)',code:'\(code)',shiftKey:\(shift),metaKey:\(meta),altKey:\(alt),ctrlKey:\(ctrl),
          repeat:\(repeating),target:\(target),preventDefault:function(){prevented=true}})
        """)
    }
    private func fitPosts(_ c: JSContext) -> Int {
        Int(c.evaluateScript("posted.filter(function(m){return m.cmuxKey==='fit'}).length")?.toInt32() ?? -1)
    }

    // MARK: The still frame's drawn report

    @Test func aStillBoardReportsDrawnOnTheFirstAnimationFrameAfterItsCanvas() throws {
        let c = try frame()
        #expect(bool(c, "posted[posted.length-1].drawn === false"), "the document starts undrawn")
        c.evaluateScript("raf.shift()()")
        #expect(bool(c, "posted[posted.length-1].drawn === false"), "no canvas yet")
        c.evaluateScript("canvas=true; raf.shift()(); raf.shift()()")
        #expect(bool(c, "posted[posted.length-1].drawn === true && posted[posted.length-1].player === false"))
    }

    @Test func aFrameOnAnyOtherPathWaitsForNoCanvas() throws {
        for path in ["/login", "/board/KEY/slug", "/slides/KEY/slug"] {
            let c = try frame(path: path)
            #expect(text(c, "raf.length") == "0", "\(path) polls for no canvas")
        }
    }

    // MARK: Every report names its document

    @Test func everyReportCarriesTheFrameDocumentsTimeOrigin() throws {
        let c = try frame()
        c.evaluateScript("canvas=true; raf.shift()(); raf.shift()()")
        #expect(bool(c, "posted.length >= 2 && posted.every(function(m){return m.cmuxClockReport === true && m.doc === 1793474311079.5})"),
                "the start report and the drawn report both carry doc")
        #expect(bool(c, "posted[posted.length-1].drawn === true"))
    }

    // MARK: The relay's tag

    @Test func theRelayTagsAChildsReportNestedWhateverTheChildSent() throws {
        let c = try frame()
        c.evaluateScript("window.frames=[{}]")
        for sent in ["nested:false", "nested:undefined", "x:1"] {
            c.evaluateScript("""
            listeners.message({source:window.frames[0],data:{cmuxClockReport:true,\(sent),path:'/design/x',drawn:false,hostname:'www.figma.com'}})
            """)
            #expect(bool(c, "posted[posted.length-1].nested === true && posted[posted.length-1].path === '/design/x'"), "\(sent)")
        }
    }

    @Test func theTopFramesOwnReportCarriesNoNestedTag() throws {
        let c = try frame()
        #expect(bool(c, "posted.length > 0 && posted.every(function(m){return m.nested === undefined})"))
    }

    @Test func theRelayForwardsAChildsFitKeyTaggedAndDropsAForeignOne() throws {
        let c = try frame()
        c.evaluateScript("window.frames=[{}]; listeners.message({source:window.frames[0],data:{cmuxKey:'fit'}})")
        #expect(bool(c, "posted[posted.length-1].cmuxKey === 'fit' && posted[posted.length-1].nested === true"))
        let before = text(c, "posted.length")
        c.evaluateScript("listeners.message({source:{},data:{cmuxKey:'fit'}}); listeners.message({source:window.frames[0],data:{cmuxKey:'other'}})")
        #expect(text(c, "posted.length") == before, "a foreign source, or any other key, is not forwarded")
    }

    // MARK: ⇧1 in Figma's frame

    @Test func shiftOnePostsAFitRequestAndKeepsFigmaFromSeeingIt() throws {
        let c = try frame()
        key(c)
        #expect(fitPosts(c) == 1 && bool(c, "prevented"))
        key(c, key: "1", code: "Digit1")
        #expect(fitPosts(c) == 2, "the Digit1 route, for a layout whose shifted key isn't !")
        key(c, key: "!", code: "")
        #expect(fitPosts(c) == 3, "the ! route")
    }

    @Test func inThePlayerShiftOneIsThePrototypesOwnAndCmuxTakesNothing() throws {
        let player = try frame(path: "/proto/KEY/slug")
        key(player)
        #expect(fitPosts(player) == 0, "cmux does nothing with ⇧1 in the player, so the frame must not take it")
        #expect(!bool(player, "prevented"), "a prototype's own Shift+1 key trigger still hears it")
        let board = try frame(path: "/design/KEY/slug")
        key(board)
        #expect(fitPosts(board) == 1 && bool(board, "prevented"), "on a board it is still taken")
    }

    // MARK: The editor's frames get nothing from the script (item 5b)

    @Test func aNestedFrameUnderFigmasEditorSetsUpNothingAndLeavesShiftOneToFigma() throws {
        let editor = try frame(ancestors: ["https://www.figma.com"], topPath: "/design/KEY/slug")
        #expect(text(editor, "typeof listeners.keydown") == "undefined", "no key listener in the editor's frames")
        #expect(text(editor, "typeof listeners.message") == "undefined", "no message listener either")
        key(editor)
        #expect(text(editor, "posted.length") == "0", "no report, no fit request")
        #expect(!bool(editor, "prevented"), "Figma's own ⇧1 in the editor")
    }

    @Test func aFrameUnderCmuxsPageKeepsTheScriptWhateverItsNearestParentIs() throws {
        let child = try frame(ancestors: ["https://www.figma.com", Self.cmuxOrigin])
        key(child)
        #expect(fitPosts(child) == 1 && bool(child, "prevented"), "the preview's child frame still asks for the fit")
        let unknown = try frame()
        key(unknown)
        #expect(fitPosts(unknown) == 1, "no ancestorOrigins at all, under cmux's page, still asks for the fit")
    }

    // cmux-rbf #cm-73.40 (code review 1, R3): the top's path decides, not its origin or the nearest parent. These two used to
    // ask whether WebKit reads the top's origin as null; the script no longer reads it, so they ask the .40 question.
    @Test func aFrameWhoseOriginChainIsUnreadableIsStillToldApartByTheTopsPath() throws {
        let editorNullOrigin = try frame(ancestors: ["null"], topPath: "/design/KEY/slug")
        key(editorNullOrigin)
        #expect(fitPosts(editorNullOrigin) == 0, "a null ancestor origin under Figma's editor is not cmux's page")
        let editorNoOrigins = try frame(topPath: "/design/KEY/slug")
        key(editorNoOrigins)
        #expect(fitPosts(editorNoOrigins) == 0, "no ancestorOrigins under Figma's editor is not cmux's page")
        // Controls: the same two chains under cmux's page do ask.
        let previewNullOrigin = try frame(ancestors: ["null"])
        key(previewNullOrigin)
        #expect(fitPosts(previewNullOrigin) == 1, "a null ancestor origin under cmux's page asks for the fit")
    }

    // cmux-rbf #cm-73.40 (code review 1, C2): a Figma frame under another site's page (a plain browser pane on a site that
    // embeds Figma) cannot read that top's path; reading it throws SecurityError. The script stops there, without a throw.
    @Test func aFrameUnderAnotherOriginsTopSetsUpNothingAndDoesNotThrow() throws {
        let embedded = try frame(topIsAnotherOrigin: true)
        #expect(text(embedded, "typeof listeners.keydown") == "undefined", "no key listener under another site's page")
        key(embedded)
        #expect(fitPosts(embedded) == 0, "no fit request under another site's page")
    }

    @Test func otherKeysAndModifiedKeysAreFigmasOwn() throws {
        let c = try frame()
        let presses: [(String, () -> Void)] = [
            ("1 without shift", { self.key(c, key: "1", shift: false) }),
            ("shift 2", { self.key(c, key: "@", code: "Digit2") }),
            ("meta", { self.key(c, meta: true) }),
            ("alt", { self.key(c, alt: true) }),
            ("ctrl", { self.key(c, ctrl: true) }),
            ("repeat", { self.key(c, repeating: true) })
        ]
        for (name, press) in presses {
            press()
            #expect(fitPosts(c) == 0, "\(name) is not a fit request")
            #expect(!bool(c, "prevented"), "\(name) is left to Figma, not prevented")
        }
    }

    @Test func aTextFieldKeepsItsExclamationMarkButFigmasHiddenKeyboardInputDoesNot() throws {
        let c = try frame()
        key(c, target: "{tagName:'INPUT',classList:{contains:function(n){return false}}}")
        key(c, target: "{tagName:'TEXTAREA',classList:{contains:function(n){return false}}}")
        key(c, target: "{tagName:'DIV',isContentEditable:true}")
        #expect(fitPosts(c) == 0, "typing a ! in a comment is typing")
        key(c, target: "{tagName:'INPUT',classList:{contains:function(n){return n==='focus-target'}}}")
        #expect(fitPosts(c) == 1, "Figma's own hidden input is where the canvas keys go (probe 1)")
    }

    @Test func theFitRequestGoesToCmuxsPageOnlyWhenTheFrameKnowsItsOrigin() throws {
        let known = try frame(ancestorOrigin: Self.cmuxOrigin)
        key(known)
        #expect(text(known, "targets[targets.length-1]") == Self.cmuxOrigin)
        let unknown = try frame()
        key(unknown)
        #expect(text(unknown, "targets[targets.length-1]") == "*")
    }

    // MARK: Reports omit origin diagnostics; the origin check remains

    @Test func aFrameReportsNoOriginFieldsButStillChecksTheOrigin() throws {
        let c = try frame(ancestorOrigin: Self.cmuxOrigin)
        c.evaluateScript("listeners.message({source:window.parent,origin:'\(Self.cmuxOrigin)',data:{cmuxClockCommand:true,mode:'run'}})")
        #expect(bool(c, "posted.length > 1 && posted.every(function(m){return !('parentOrigin' in m) && !('commandOrigin' in m)})"),
                "no report carries the origin fields")
        c.evaluateScript("listeners.message({source:window.parent,origin:'https://evil.example',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(c, "typeof replaced") == "undefined", "the origin check stays without diagnostics")
        c.evaluateScript("listeners.message({source:window.parent,origin:'\(Self.cmuxOrigin)',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(c, "typeof replaced") == "string")
    }

    // MARK: Scenario 316: the channel's checks

    @Test func aCommandFromACmuxPageOfTheRightOriginActsAndOneFromAnotherOriginDoesNot() throws {
        let c = try frame(ancestorOrigin: Self.cmuxOrigin)
        c.evaluateScript("listeners.message({source:window.parent,origin:'https://evil.example',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(c, "typeof replaced") == "undefined", "another origin must not navigate the frame")
        c.evaluateScript("listeners.message({source:window.parent,origin:'\(Self.cmuxOrigin)',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(c, "typeof replaced") == "string", "the control: cmux's page redraws the frame")
    }

    @Test func aFrameThatCannotReadItsParentsOriginKeepsTheSourceCheckAlone() throws {
        let c = try frame()
        c.evaluateScript("listeners.message({source:window.parent,origin:'null',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(c, "typeof replaced") == "string")
        let d = try frame()
        d.evaluateScript("listeners.message({source:{},origin:'null',data:{cmuxClockCommand:true,kind:'still'}})")
        #expect(text(d, "typeof replaced") == "undefined")
    }

    @Test func anUnknownCommandFromTheParentDoesNothing() throws {
        let c = try frame()
        c.evaluateScript("listeners.message({source:window.parent,origin:'\(Self.figma)',data:{cmuxClockCommand:true,eval:'1',kind:'zoom'}})")
        #expect(text(c, "typeof replaced") == "undefined", "no kind outside still and player navigates")
        #expect(text(c, "performance.now()") == "20")
    }

    // MARK: The page: refit

    @Test func nodeMoveUsesTheStillWwwAddressAndPreservesOtherParameters() throws {
        for node in ["16-2", "16:2"] {
            let c = try frame(ancestorOrigin: Self.cmuxOrigin)
            c.evaluateScript("location.href += '&opaque=keep%2Fme'; listeners.message({source:window.parent,origin:'\(Self.cmuxOrigin)',data:{cmuxClockCommand:true,kind:'still',node:'\(node)'}})")
            let address = try #require(text(c, "replaced"))
            let url = try #require(URLComponents(string: address))
            let q = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.host == "www.figma.com" && url.path == "/design/KEY/slug")
            #expect(q["node-id"] == "16-2")
            #expect(q["theme"] == "dark" && q["footer"] == "false" && q["embed-host"] == "cmux" && q["opaque"] == "keep/me")
        }
    }

    @Test func frameRefusesMalformedMoveNodesAndForeignSources() throws {
        for node in ["", "1", "1-2&x=3", "1-2\n", "x-2", "1-2-3"] {
            let c = try frame(ancestorOrigin: Self.cmuxOrigin)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [node]), as: UTF8.self)
            c.evaluateScript("listeners.message({source:window.parent,origin:'\(Self.cmuxOrigin)',data:{cmuxClockCommand:true,kind:'still',node:\(json)[0]}})")
            #expect(text(c, "typeof replaced") == "undefined", "\(node.debugDescription)")
        }
        for source in ["{}", "window.parent"] {
            let c = try frame(ancestorOrigin: Self.cmuxOrigin)
            c.evaluateScript("listeners.message({source:\(source),origin:'https://evil.example',data:{cmuxClockCommand:true,kind:'still',node:'16-2'}})")
            #expect(text(c, "typeof replaced") == "undefined")
        }
    }

    @Test func pageMoveRewritesOnlyEmbedWithoutLoadingOrAddingHistory() throws {
        let c = try page(); report(c)
        c.evaluateScript("""
        location.search += '&outer=kept'; history={state:{kept:1},replaceState:function(s,t,u){historyCalls.push([s,t,u]);location.search=u.slice(u.indexOf('?'))}};
        historyCalls=[]; historyPushes=0; history.pushState=function(){historyPushes++}; sent=[]; oldFrame=frame; answer=window.__cmuxMotion.command('refit','16:2');
        """)
        #expect(c.exception == nil, "\(String(describing: c.exception))")
        #expect(text(c, "sent[sent.length-1].node") == "16-2")
        #expect(text(c, "historyCalls.length") == "1")
        #expect(text(c, "historyPushes") == "0")
        #expect(bool(c, "answer && answer.report === null && frame === oldFrame"))
        let search = try #require(text(c, "location.search"))
        let url = try #require(URLComponents(string: FigmaPaneURL.previewPageURL.absoluteString + search))
        let q = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["outer"] == "kept")
        let embeddedAddress = try #require(q["embed"])
        let embed = try #require(URLComponents(string: embeddedAddress))
        #expect(embed.host == "embed.figma.com")
        #expect(embed.queryItems?.first { $0.name == "node-id" }?.value == "16-2")
        #expect(bool(c, "historyCalls[0][0].kept === 1"))
    }

    @Test func pageRefusesMalformedNodesWithoutSendingOrRewriting() throws {
        let c = try page(); report(c)
        c.evaluateScript("sent=[]; rewrites=0; history={replaceState:function(){rewrites++}}")
        for node in ["", "1-2&x=3", "1-2\n", "bad"] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [node]), as: UTF8.self)
            #expect(!bool(c, "window.__cmuxMotion.command('refit',\(json)[0])"), "\(node.debugDescription)")
        }
        #expect(text(c, "sent.length") == "0")
        #expect(text(c, "rewrites") == "0")
    }

    @Test func refusedNodeMoveLeavesTheEmbedAddressAlone() throws {
        for item in [("/login", false, true), ("/design/KEY/slug", false, false), ("/proto/KEY/slug", true, true)] {
            let c = try page(marked: item.1)
            report(c, path: item.0, drawn: item.2, player: item.1)
            c.evaluateScript("sent=[]; before=location.search; rewrites=0; history={replaceState:function(){rewrites++}}")
            #expect(!bool(c, "window.__cmuxMotion.command('refit','16-2')"))
            #expect(bool(c, "location.search === before && rewrites === 0 && sent.length === 0"))
        }
        let c = try page(); report(c)
        c.evaluateScript("window.__cmuxMotion.command('refit'); sent=[]; before=location.search; rewrites=0; history={replaceState:function(){rewrites++}}")
        #expect(!bool(c, "window.__cmuxMotion.command('refit','16-2')"), "a refit already running stops the move")
        #expect(bool(c, "location.search === before && rewrites === 0 && sent.length === 0"))
    }

    @Test func refitSendsStillAndClearsTheKeptReportBeforeItSends() throws {
        let c = try page(); report(c)
        c.evaluateScript("sent=[]; refitAnswer = window.__cmuxMotion.command('refit')")
        #expect(text(c, "sent[sent.length-1].kind") == "still")
        #expect(bool(c, "refitAnswer && refitAnswer.report === null"), "the reply carries no old drawn report")
        #expect(bool(c, "window.__cmuxMotion.snapshot().report === null && posted[posted.length-1].report === null"),
                "nor does the render")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "still")
    }

    @Test func refitRefusesWhenTheFrameIsNotADrawnDesignOrFilePage() throws {
        let cases: [(String, Bool, Bool)] = [("/design/KEY/slug", false, false), ("/board/KEY/slug", true, false), ("/login", true, false)]
        for (path, drawn, player) in cases {
            let c = try page(); report(c, path: path, drawn: drawn, player: player)
            c.evaluateScript("sent=[]")
            #expect(!bool(c, "window.__cmuxMotion.command('refit')"), "\(path)")
            #expect(text(c, "sent.length") == "0", "a refused refit sends nothing: \(path)")
        }
        let none = try page()
        #expect(!bool(none, "window.__cmuxMotion.command('refit')"), "no report is no board")
        let player = try page(marked: true); report(player, path: "/proto/KEY/slug", drawn: true, player: true)
        #expect(!bool(player, "window.__cmuxMotion.command('refit')"), "the player redraws nothing")
    }

    @Test func theRedrawnDocumentsOwnReportsComeAfterTheRefit() throws {
        let c = try page(); report(c)
        c.evaluateScript("window.__cmuxMotion.command('refit')")
        report(c, drawn: false)
        #expect(bool(c, "window.__cmuxMotion.snapshot().report.drawn === false"))
        report(c, drawn: true)
        #expect(bool(c, "window.__cmuxMotion.snapshot().report.drawn === true"))
    }

    // MARK: The page: nested reports and the fit key

    @Test func aNestedReportNeverBecomesTheKeptReport() throws {
        let c = try page(); report(c)
        report(c, path: "/design/other", drawn: false, nested: true)
        #expect(lastReportPath(c) == "/design/KEY/slug", "the top frame's report stays")
        report(c, path: "/design/KEY/slug", drawn: false)
        #expect(bool(c, "window.__cmuxMotion.snapshot().report.drawn === false"), "an untagged report still replaces it")
    }

    @Test func aNestedPlayerReportStillEndsTheLoading() throws {
        let c = try page(marked: true)
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "loading")
        report(c, path: "/proto/KEY/slug", drawn: true, player: true, nested: true)
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "frozen", "the tag keeps a report out of lastReport only")
        #expect(lastReportPath(c) == nil)
    }

    @Test func aFitRequestFromTheFrameReachesTheAppAsActionFit() throws {
        let c = try page()
        c.evaluateScript("posted=[]; listeners.message({source:frame.contentWindow,origin:'\(Self.figma)',data:{cmuxKey:'fit'}})")
        #expect(text(c, "posted[posted.length-1].action") == "fit")
        c.evaluateScript("posted=[]; listeners.message({source:frame.contentWindow,origin:'\(Self.figma)',data:{cmuxKey:'fit',nested:true}})")
        #expect(text(c, "posted[posted.length-1].action") == "fit", "a nested frame's request still counts")
    }

    @Test func aForgedFitRequestFromAnotherWindowOrOriginRunsNothing() throws {
        let c = try page()
        c.evaluateScript("posted=[]; listeners.message({source:{},origin:'\(Self.figma)',data:{cmuxKey:'fit'}})")
        #expect(text(c, "posted.length") == "0", "a second iframe is not the frame")
        c.evaluateScript("listeners.message({source:frame.contentWindow,origin:'https://evil.example',data:{cmuxKey:'fit'}})")
        #expect(text(c, "posted.length") == "0", "nor is another origin")
        c.evaluateScript("listeners.message({source:frame.contentWindow,origin:'\(Self.figma)',data:{cmuxKey:'zoom'}})")
        #expect(text(c, "posted.length") == "0", "nor another key")
    }

    @Test func aReportFromAnotherOriginIsDroppedWhateverItsHostnameClaims() throws {
        let c = try page(); report(c)
        report(c, path: "/board/forged", drawn: true, origin: "https://evil.example", hostname: "www.figma.com")
        #expect(lastReportPath(c) == "/design/KEY/slug", "the sender writes `hostname` itself; `e.origin` it can't")
        report(c, path: "/design/other", origin: "https://embed.figma.com")
        #expect(lastReportPath(c) == "/design/other", "embed.figma.com is the frame's first origin")
    }

    @Test func shiftOneOnCmuxsPageAsksForAFit() throws {
        let c = try page()
        c.evaluateScript("posted=[]; prevented=false; listeners.keydown({key:'!',code:'Digit1',shiftKey:true,metaKey:false,altKey:false,ctrlKey:false,repeat:false,target:{tagName:'BODY'},preventDefault:function(){prevented=true}})")
        #expect(text(c, "posted[posted.length-1].action") == "fit" && bool(c, "prevented"))
        c.evaluateScript("posted=[]; listeners.keydown({key:'!',code:'Digit1',shiftKey:true,metaKey:true,altKey:false,ctrlKey:false,repeat:false,target:{tagName:'BODY'},preventDefault:function(){}})")
        #expect(text(c, "posted.length") == "0")
    }

    // MARK: The Swift side builds script text from a closed set

    @Test func commandScriptTakesOnlyTheClosedSetOfNames() {
        #expect(FigmaMotion.Command.allCases.map(\.rawValue).sorted() == ["freeze", "play", "refit", "still", "toggle"])
        #expect(FigmaMotion.commandScript(.refit) == "window.__cmuxMotion && window.__cmuxMotion.command('refit')")
    }
    // MARK: cm-73.52: full screen

    /// What Safari has and the harness lacks: elements that can ask for full screen, a document whose own
    /// `fullscreenElement` is a getter, and events the script can fire. `natives` counts the calls that reach WebKit.
    private static let fullscreenPrelude = """
    natives = 0; events = [];
    Element = function () {};
    Element.prototype = { requestFullscreen: function () { natives++; }, webkitRequestFullscreen: function () { natives++; } };
    Event = function (type) { this.type = type; };
    document.dispatchEvent = function (event) { events.push(event.type); };
    document.documentElement = { name: 'html' };
    var nativeProto = { get fullscreenElement() { return 'REAL'; }, get webkitFullscreenElement() { return 'REAL-WEBKIT'; } };
    Object.setPrototypeOf(document, nativeProto);
    document.exitFullscreen = function () { natives++; }; document.webkitExitFullscreen = function () { natives++; };
    """

    private func asksForFullscreen(_ c: JSContext, _ call: String, enter: Bool) -> Bool {
        c.evaluateScript("posted = []; \(call)")
        return bool(c, "posted.length === 1 && posted[0].cmuxKey === 'fullscreen' && posted[0].enter === \(enter)")
    }

    @Test func aBoardsFullScreenRequestGoesToCmuxAndNeverToWebKit() throws {
        let c = try frame(prelude: Self.fullscreenPrelude)
        for method in ["requestFullscreen", "webkitRequestFullscreen"] {
            #expect(asksForFullscreen(c, "var r = new Element().\(method)(); window.answer = r;", enter: true), "\(method)")
            #expect(bool(c, "typeof answer.then === 'function'"), "\(method) answers with a promise, as Figma awaits it")
        }
        #expect(text(c, "natives") == "0", "the request never reaches WebKit, so a redraw can't end a full screen it started")
    }

    @Test func thePlayerKeepsFigmasOwnFullScreen() throws {
        let c = try frame(path: "/proto/KEY/slug", prelude: Self.fullscreenPrelude)
        c.evaluateScript("posted = []; new Element().requestFullscreen(); new Element().webkitRequestFullscreen()")
        #expect(text(c, "natives") == "2", "in the player the request goes through")
        #expect(text(c, "posted.length") == "0", "and cmux hears nothing of it")
        c.evaluateScript("listeners.message({source: window.parent, data: {cmuxFullscreen: true}})")
        #expect(text(c, "document.fullscreenElement") == "REAL", "the player's getters are never wrapped")
    }

    @Test func aChildFramesRequestIsRelayedOnlyFromFigmasOwnOrigins() throws {
        let c = try frame()
        c.evaluateScript("window.frames=[{}]")
        for origin in ["https://www.figma.com", "https://embed.figma.com"] {
            c.evaluateScript("posted = []; listeners.message({source:window.frames[0],origin:'\(origin)',data:{cmuxKey:'fullscreen',enter:true}})")
            #expect(bool(c, "posted.length === 1 && posted[0].cmuxKey === 'fullscreen' && posted[0].enter === true && posted[0].nested === true"), "\(origin)")
        }
        c.evaluateScript("posted = []; listeners.message({source:window.frames[0],origin:'https://www.figma.com',data:{cmuxKey:'fullscreen',enter:false}})")
        #expect(bool(c, "posted.length === 1 && posted[0].enter === false"), "a leave is relayed too")
        for origin in ["https://evil.example", "https://figma.com.evil.example", "http://www.figma.com", "null", ""] {
            c.evaluateScript("posted = []; listeners.message({source:window.frames[0],origin:'\(origin)',data:{cmuxKey:'fullscreen',enter:true}})")
            #expect(text(c, "posted.length") == "0", "a child at \(origin.debugDescription) is not relayed")
        }
        c.evaluateScript("posted = []; listeners.message({source:{},origin:'https://www.figma.com',data:{cmuxKey:'fullscreen',enter:true}})")
        #expect(text(c, "posted.length") == "0", "a window that is not one of this frame's children is not relayed")
    }

    @Test func theFrameAnswersFullScreenWhileCmuxSaysItsPageIsFullScreen() throws {
        let c = try frame(prelude: Self.fullscreenPrelude)
        #expect(text(c, "document.fullscreenElement") == "REAL", "before cmux says so, the native answer, kept by reference")
        c.evaluateScript("listeners.message({source: window.parent, data: {cmuxFullscreen: true}})")
        #expect(bool(c, "document.fullscreenElement === document.documentElement"))
        #expect(bool(c, "document.webkitFullscreenElement === document.documentElement"))
        #expect(text(c, "events.join()") == "fullscreenchange,webkitfullscreenchange", "Figma hears the change")
        c.evaluateScript("events = []; listeners.message({source: window.parent, data: {cmuxFullscreen: true}})")
        #expect(text(c, "events.length") == "0", "saying it again changes nothing")
        c.evaluateScript("listeners.message({source: window.parent, data: {cmuxFullscreen: false}})")
        #expect(text(c, "document.fullscreenElement") == "REAL", "and back to the native answer")
        #expect(text(c, "document.webkitFullscreenElement") == "REAL-WEBKIT")
        #expect(text(c, "events.join()") == "fullscreenchange,webkitfullscreenchange")
    }

    @Test func onlyCmuxsPageCanSayItIsFullScreenAndItsWordReachesTheChildren() throws {
        let c = try frame(prelude: Self.fullscreenPrelude)
        c.evaluateScript("window.frames=[{postMessage:function(m){sent.push(m)}}]; sent=[]")
        c.evaluateScript("listeners.message({source: {}, data: {cmuxFullscreen: true}}); listeners.message({source: window.frames[0], data: {cmuxFullscreen: true}})")
        #expect(text(c, "document.fullscreenElement") == "REAL", "a child, or anyone else, can't claim it")
        #expect(text(c, "events.length") == "0")
        c.evaluateScript("listeners.message({source: window.parent, data: {cmuxFullscreen: true}})")
        #expect(bool(c, "sent.length === 1 && sent[0].cmuxFullscreen === true"), "a child frame's Figma code hears it as well")
        c.evaluateScript("listeners.message({source: window.parent, data: {cmuxFullscreen: 'yes'}})")
        #expect(bool(c, "document.fullscreenElement === document.documentElement"), "only a boolean is a word")
    }

    @Test func figmasExitFromFullScreenIsARequestToCmux() throws {
        let c = try frame(prelude: Self.fullscreenPrelude)
        #expect(asksForFullscreen(c, "document.exitFullscreen()", enter: false))
        #expect(asksForFullscreen(c, "document.webkitExitFullscreen()", enter: false))
        #expect(text(c, "natives") == "0", "never called through")
    }

    @Test func thePageTellsItsFrameWhenItsOwnFullScreenChanges() throws {
        let c = try page(prelude: "docListeners = {}; document.addEventListener = function (n, f) { docListeners[n] = f; };")
        func told() -> String {
            text(c, "sent.filter(function(m){return 'cmuxFullscreen' in m}).map(function(m){return m.cmuxFullscreen}).join()") ?? ""
        }
        c.evaluateScript("sent = []; document.fullscreenElement = frame; docListeners.fullscreenchange()")
        #expect(told() == "true")
        c.evaluateScript("sent = []; document.fullscreenElement = null; docListeners.fullscreenchange()")
        #expect(told() == "false")
        c.evaluateScript("sent = []; document.webkitFullscreenElement = frame; docListeners.webkitfullscreenchange()")
        #expect(told() == "true", "WebKit's prefixed event too")
    }

    @Test func thePageTellsTheNewDocumentAfterEachDrawnReportAndOnlyThen() throws {
        let c = try page(prelude: "docListeners = {}; document.addEventListener = function (n, f) { docListeners[n] = f; };")
        func told() -> String {
            text(c, "sent.filter(function(m){return 'cmuxFullscreen' in m}).map(function(m){return m.cmuxFullscreen}).join()") ?? ""
        }
        c.evaluateScript("document.fullscreenElement = frame; sent = []")
        report(c, drawn: false)
        #expect(told() == "", "an undrawn report is a document still loading")
        report(c, drawn: true)
        #expect(told() == "true", "a redraw is a new document, which starts out not knowing")
        c.evaluateScript("sent = []")
        report(c, drawn: true, nested: true)
        #expect(told() == "", "a nested frame's report is not the top frame's document")
    }

    @Test func thePagePassesFigmasFullScreenRequestToThePanelOnlyFromItsFramesOwnOrigins() throws {
        let c = try page()
        func post(source: String = "frame.contentWindow", origin: String, data: String) {
            c.evaluateScript("posted = []; listeners.message({source:\(source),origin:'\(origin)',data:\(data)})")
        }
        post(origin: Self.figma, data: "{cmuxKey:'fullscreen',enter:true}")
        #expect(bool(c, "posted.length === 1 && posted[0].action === 'fullscreen' && posted[0].enter === true"))
        post(origin: "https://embed.figma.com", data: "{cmuxKey:'fullscreen',enter:false}")
        #expect(bool(c, "posted.length === 1 && posted[0].action === 'fullscreen' && posted[0].enter === false"))
        post(origin: "https://evil.example", data: "{cmuxKey:'fullscreen',enter:true}")
        #expect(text(c, "posted.length") == "0", "another origin is refused")
        post(source: "{}", origin: Self.figma, data: "{cmuxKey:'fullscreen',enter:true}")
        #expect(text(c, "posted.length") == "0", "a window that is not the frame is refused")
    }
}
