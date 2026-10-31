// cmux-rbf (#cm-73.37): execute the production page and frame scripts with controlled clocks/DOM.
import AppKit
import Combine
import CmuxBrowser
import CmuxCommandPalette
import Foundation
import JavaScriptCore
import Testing
import WebKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("FigmaMotion")
struct FigmaMotionTests {
    private func page(marked: Bool = true, dark: Bool = false, run: Bool = false) throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript(Self.browser)
        c.evaluateScript("location.search += '&motion=\(marked ? "1" : "0")'; frame.src += '&theme=\(dark ? "dark" : "light")';")
        c.evaluateScript(FigmaMotion.pageScript(run: run))
        try #require(c.exception == nil, "page script failed: \(String(describing: c.exception))")
        return c
    }
    private func drawn(_ c: JSContext) {
        c.evaluateScript("listeners.message({source: frame.contentWindow, origin: 'https://www.figma.com', data: {cmuxClockReport:true, player:true, drawn:true, mode:'freeze', hostname:'www.figma.com'}})")
    }
    private func text(_ c: JSContext, _ js: String) -> String? { c.evaluateScript(js)?.toString() }
    private func bool(_ c: JSContext, _ js: String) -> Bool { c.evaluateScript(js)?.toBool() == true }

    @Test func loadingDisablesBothCellsUntilDrawn() throws {
        let c = try page()
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "loading")
        #expect(bool(c, "elements['cmux-motion-toggle'].disabled && elements['cmux-motion-still'].disabled"), "Loading disables both cells")
        #expect(text(c, "elements['cmux-motion-toggle'].textContent") == "▶")
        #expect(!bool(c, "window.__cmuxMotion.command('toggle')"))
        c.evaluateScript("listeners.message({source: frame.contentWindow, origin: 'https://www.figma.com', data: {cmuxClockReport:true,player:true,drawn:false,mode:'freeze',hostname:'www.figma.com'}})")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "loading", "undrawn reports cannot end Loading")
    }
    @Test func frozenFirstStateShowsPlayAndEnabledStill() throws {
        let c = try page(); drawn(c)
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "frozen", "drawn ends Loading at frozen")
        #expect(text(c, "elements['cmux-motion-toggle'].textContent") == "▶")
        #expect(bool(c, "!elements['cmux-motion-toggle'].disabled && !elements['cmux-motion-still'].disabled"))
    }
    @Test func playingShowsPauseWithoutNavigation() throws {
        let c = try page(); drawn(c)
        c.evaluateScript("window.__cmuxMotion.command('toggle')")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "playing")
        #expect(text(c, "elements['cmux-motion-toggle'].textContent") == "❚❚")
        #expect(bool(c, "!elements['cmux-motion-still'].disabled"))
        #expect(text(c, "sent[sent.length-1].mode") == "run", "Play releases the same frame clock")
        #expect(bool(c, "sent.every(function(m) { return !m.kind; })"))
    }
    @Test func pausedShowsPlayAndEnabledStill() throws {
        let c = try page(); drawn(c)
        c.evaluateScript("window.__cmuxMotion.command('toggle'); window.__cmuxMotion.command('toggle')")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "paused")
        #expect(text(c, "elements['cmux-motion-toggle'].textContent") == "▶")
        #expect(bool(c, "!elements['cmux-motion-still'].disabled"))
        #expect(text(c, "sent[sent.length-1].mode") == "freeze")
    }
    @Test func stillShowsPlayAndDisabledStillThenLoadsPlayer() throws {
        let c = try page(); drawn(c)
        c.evaluateScript("window.__cmuxMotion.command('still')")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "still")
        #expect(text(c, "elements['cmux-motion-toggle'].textContent") == "▶")
        #expect(bool(c, "!elements['cmux-motion-toggle'].disabled && elements['cmux-motion-still'].disabled"))
        #expect(text(c, "sent[sent.length-1].kind") == "still")
        c.evaluateScript("window.__cmuxMotion.command('toggle')")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "loading")
        #expect(text(c, "sent[sent.length-1].kind") == "player")
        drawn(c)
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "playing")
    }
    @Test func playMotionTooltip() throws {
        let c = try page(); drawn(c)
        #expect(text(c, "elements['cmux-motion-toggle'].title") == "Play motion")
    }
    @Test func pauseMotionTooltip() throws {
        let c = try page(); drawn(c); c.evaluateScript("window.__cmuxMotion.command('toggle')")
        #expect(text(c, "elements['cmux-motion-toggle'].title") == "Pause motion")
    }
    @Test func showStillZoomTooltipAndAccessibleLabel() throws {
        let c = try page()
        #expect(text(c, "elements['cmux-motion-still'].title") == "Show still view (zoom)")
        #expect(text(c, "elements['cmux-motion-still']['aria-label']") == "Show still view (zoom)")
    }
    @Test func themeComesFromFrameAddress() throws {
        for dark in [true, false] {
            let c = try page(dark: dark)
            #expect(text(c, "elements['cmux-motion-pill'].style.backgroundColor") == (dark ? "#2C2C2C" : "#FFFFFF"))
            #expect(text(c, "elements['cmux-motion-toggle'].style.color") == (dark ? "#5C5C5C" : "#B3B3B3"))
            drawn(c)
            #expect(text(c, "elements['cmux-motion-toggle'].style.color") == (dark ? "#FFFFFF" : "#1E1E1E"))
            #expect(text(c, "window.__cmuxMotion.colors('https://figma.com/?theme=other').fill") == "#FFFFFF")
        }
    }
    @Test func unmarkedStillHasNoPillAndPalettePlayRevealsIt() throws {
        let c = try page(marked: false)
        #expect(text(c, "elements['cmux-motion-pill'].style.display") == "none")
        c.evaluateScript("window.__cmuxMotion.command('toggle')")
        #expect(text(c, "elements['cmux-motion-pill'].style.display") == "flex")
    }
    @Test func stillPlayerNavigationWaitsForFrameClockReadiness() throws {
        let c = try page(marked: false)
        c.evaluateScript("window.__cmuxMotion.command('toggle'); sent=[]; listeners.message({source:frame.contentWindow,origin:'https://www.figma.com',data:{cmuxClockReport:true,player:false,drawn:false,mode:'run',hostname:'www.figma.com',path:'/design/KEY/slug'}})")
        #expect(text(c, "sent[sent.length-1].kind") == "player", "the last navigation command must reach a newly ready frame")
    }

    @Test func foreignFrameCannotReportDrawn() throws {
        let c = try page()
        c.evaluateScript("listeners.message({source: {}, data: {cmuxClockReport:true,player:true,drawn:true,hostname:'www.figma.com'}})")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "loading")
    }
    @Test func pagehideFreezesAndPageshowKeepsPausedPoint() throws {
        let c = try page(); drawn(c); c.evaluateScript("window.__cmuxMotion.command('toggle'); listeners.pagehide(); listeners.pageshow()")
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "paused", "pagehide must pause the retained player")
        #expect(bool(c, "sent.some(function(m) {return m.mode === 'freeze';})"))
    }
    @Test func gotoPlayStartsRunningAsSoonAsDrawn() throws {
        let c = try page(run: true); drawn(c)
        #expect(text(c, "window.__cmuxMotion.snapshot().state") == "playing")
    }
    @Test func pillPostsOnlySharedActionNames() throws {
        let c = try page(); drawn(c)
        c.evaluateScript("elements['cmux-motion-toggle'].onclick(); elements['cmux-motion-still'].onclick()")
        #expect(text(c, "posted[posted.length-2].action") == "toggle")
        #expect(text(c, "posted[posted.length-1].action") == "still")
    }

    private func clock(path: String = "/proto/KEY/slug", host: String = "www.figma.com") throws -> JSContext {
        let c = try #require(JSContext()); c.evaluateScript(Self.browser)
        c.evaluateScript("window.name='cmux-freeze'; window.parent={postMessage:function(m){posted.push(m)}}; location.hostname='\(host)'; location.pathname='\(path)'; location.href='https://\(host)\(path)?node-id=12-2&embed-host=cmux&footer=false&theme=dark&page-selector=0'; location.replace=function(s){replaced=s}; perfTime=20; wallTime=10000; performance={now:function(){return perfTime}}; Date.now=function(){return wallTime}; canvas=false; raf=[]; requestAnimationFrame=function(f){raf.push(f)}; document.querySelector=function(){return canvas ? {} : null};")
        c.evaluateScript(FigmaMotion.clockScript)
        try #require(c.exception == nil, "clock script failed: \(String(describing: c.exception))")
        return c
    }
    @Test func frameRejectsCommandsFromAnyoneExceptParent() throws {
        let c = try clock()
        c.evaluateScript("listeners.message({source:{},data:{cmuxClockCommand:true,mode:'run',kind:'still'}}); perfTime=60; wallTime=11000")
        #expect(text(c, "performance.now()") == "20", "foreign source must not release clock")
        #expect(text(c, "typeof replaced") == "undefined", "foreign source must not navigate")
        c.evaluateScript("listeners.message({source:window.parent,data:{cmuxClockCommand:true,mode:'run'}}); perfTime+=7")
        #expect(text(c, "performance.now()") == "27")
    }
    @Test func frameFreezesOnlyClockAndResumesWithoutSleepJump() throws {
        let c = try clock()
        c.evaluateScript("perfTime+=3; wallTime+=120000")
        #expect(text(c, "performance.now()") == "20")
        #expect(text(c, "Date.now()") == "10000")
        #expect(text(c, "raf.length") == "1", "animation frames keep running while frozen")
        c.evaluateScript("canvas=true; raf.shift()(); raf.shift()()")
        #expect(bool(c, "posted[posted.length-1].drawn"), "canvas plus one animation frame reports drawn")
        c.evaluateScript("listeners.message({source:window.parent,data:{cmuxClockCommand:true,mode:'run'}}); perfTime+=10; wallTime+=10")
        #expect(text(c, "performance.now()") == "30")
        #expect(text(c, "Date.now()") == "10010", "Date uses wall time minus its own frozen span")
    }
    // Scenario 234: WebKit caches the preview page before cmux's `freeze` message reaches
    // Figma's frame, so the frame holds its own clock when its document is hidden.
    @Test func playingFrameHoldsItsClockFromItsOwnPagehide() throws {
        let c = try clock()
        c.evaluateScript("listeners.message({source:window.parent,data:{cmuxClockCommand:true,mode:'run'}}); perfTime+=4000; wallTime+=4000")
        #expect(text(c, "performance.now()") == "4020")
        c.evaluateScript("if (listeners.pagehide) listeners.pagehide({persisted:true}); perfTime+=8500; wallTime+=8500")
        #expect(text(c, "performance.now()") == "4020", "the clock must hold from the moment the page was hidden")
        #expect(text(c, "Date.now()") == "14000", "Date must hold from the moment the page was hidden")
        c.evaluateScript("listeners.message({source:window.parent,data:{cmuxClockCommand:true,mode:'run'}}); perfTime+=10; wallTime+=10")
        #expect(text(c, "performance.now()") == "4030", "play after return resumes from where it was left")
    }
    @Test func loginAndInterstitialKeepRealClock() throws {
        for path in ["/login", "/embed/interstitial", "/design/KEY/slug"] {
            let c = try clock(path: path)
            c.evaluateScript("perfTime=90; wallTime=20000")
            #expect(text(c, "performance.now()") == "90")
            #expect(text(c, "Date.now()") == "20000")
        }
    }
    @Test func parentClockCommandsReachChildFramesAndChildReportsReachParent() throws {
        let c = try clock()
        c.evaluateScript("window.frames=[{postMessage:function(m){sent.push(m)}}]; listeners.message({source:window.parent,data:{cmuxClockCommand:true,mode:'freeze'}})")
        #expect(text(c, "sent[sent.length-1].mode") == "freeze", "clock commands must reach child frames")
        c.evaluateScript("listeners.message({source:window.frames[0],data:{cmuxClockReport:true,drawn:true,hostname:'www.figma.com'}})")
        #expect(bool(c, "posted[posted.length-1].drawn"), "child clock reports must reach the preview")
    }

    @Test func stillToPlayerMappingPreservesNodeThemeAndEmbedParameters() throws {
        let c = try clock(path: "/design/KEY/slug")
        c.evaluateScript("listeners.message({source:window.parent,data:{cmuxClockCommand:true,kind:'player'}})")
        let address = try #require(text(c, "replaced"))
        let u = try #require(URLComponents(string: address))
        #expect(u.host == "www.figma.com" && u.path == "/proto/KEY/slug")
        let q = Dictionary(uniqueKeysWithValues: (u.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["node-id"] == "12-2" && q["starting-point-node-id"] == "12-2")
        #expect(q["hide-ui"] == "1" && q["scaling"] == "contain" && q["bg-color"] == "e5e5e5")
        #expect(q["theme"] == "dark" && q["footer"] == "false" && q["embed-host"] == "cmux")
        #expect(q["page-selector"] == nil)
    }
    @Test func playerToStillMappingRemovesOnlyPlayerParameters() throws {
        let c = try clock(host: "embed.figma.com")
        c.evaluateScript("location.href += '&hide-ui=1&scaling=contain&starting-point-node-id=12-2&bg-color=e5e5e5'; listeners.message({source:window.parent,data:{cmuxClockCommand:true,kind:'still'}})")
        let address = try #require(text(c, "replaced"))
        let u = try #require(URLComponents(string: address))
        #expect(u.host == "www.figma.com" && u.path == "/design/KEY/slug")
        let q = Dictionary(uniqueKeysWithValues: (u.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["page-selector"] == "0" && q["node-id"] == "12-2")
        #expect(q["theme"] == "dark" && q["footer"] == "false" && q["embed-host"] == "cmux")
        for key in ["hide-ui", "scaling", "starting-point-node-id", "bg-color"] { #expect(q[key] == nil) }
    }
    // Scenario 232: Figma's redirect from `embed.figma.com/proto/…` carries no `viewer=1`, and
    // `www.figma.com/design?embed-host=…` without it draws an empty page (measured 2026-10-29).
    // The first address is the one read off a frame that opened in the player; the second, one
    // that opened in the read view and was played, already carries it.
    @Test func stillAddressAlwaysAsksForFigmasViewerOnce() throws {
        let addresses = [
            "https://www.figma.com/proto/OlnsbHBaQ6WeIU3lx8Qsnn/slug?bg-color=e5e5e5&content-scaling=fixed&embed-host=cmux&footer=0&hide-ui=1&kind=proto&node-id=106-426&scaling=contain&starting-point-node-id=106-426&theme=light&version=2",
            "https://www.figma.com/proto/OlnsbHBaQ6WeIU3lx8Qsnn/slug?embed-host=cmux&footer=0&kind=file&node-id=106-426&theme=light&version=2&viewer=1&hide-ui=1&bg-color=e5e5e5&scaling=contain&starting-point-node-id=106-426"
        ]
        for href in addresses {
            let c = try clock(path: "/proto/OlnsbHBaQ6WeIU3lx8Qsnn/slug")
            c.evaluateScript("location.href = '\(href)'; listeners.message({source:window.parent,data:{cmuxClockCommand:true,kind:'still'}})")
            let address = try #require(text(c, "replaced"))
            let u = try #require(URLComponents(string: address))
            #expect(u.host == "www.figma.com" && u.path == "/design/OlnsbHBaQ6WeIU3lx8Qsnn/slug")
            let items = u.queryItems ?? []
            #expect(items.filter { $0.name == "viewer" }.map(\.value) == ["1"], "Figma draws an empty read view without viewer=1: \(address)")
            #expect(items.contains { $0.name == "node-id" && $0.value == "106-426" } && items.contains { $0.name == "page-selector" && $0.value == "0" })
        }
    }

    // cmux-rbf (#cm-73.44): internal so FigmaRefitScriptTests runs in the same harness; reports now carry the real `origin`.
    static let browser = #"""
    window=this; window.frames=[]; elements={}; listeners={}; sent=[]; posted=[];
    window.addEventListener=function(n,f){listeners[n]=f};
    window.webkit={messageHandlers:{cmuxFigmaMotion:{postMessage:function(m){posted.push(m)}}}};
    location={search:'?embed='+encodeURIComponent('https://embed.figma.com/design/KEY/slug?node-id=12-2')};
    URLSearchParams=function(s){var p={}; s.replace(/^\?/,'').split('&').forEach(function(v){var a=v.indexOf('='); p[decodeURIComponent(v.slice(0,a))]=decodeURIComponent(v.slice(a+1))});this.get=function(k){return p[k]||null}};
    frame={src:'https://embed.figma.com/proto/KEY/slug?node-id=12-2',contentWindow:{postMessage:function(m){sent.push(m)}}};
    function element(){var e={style:{},appendChild:function(){},setAttribute:function(k,v){this[k]=v}};return e;}
    document={readyState:'complete',querySelector:function(s){return s==='iframe'?frame:null},createElement:element,body:{appendChild:function(e){elements[e.id]=e}},addEventListener:function(){}};
    var makeElement=document.createElement;
    document.createElement=function(){var e=makeElement();Object.defineProperty(e,'id',{set:function(v){this._id=v;elements[v]=this},get:function(){return this._id}});return e};
    """#
}

@MainActor
@Suite("FigmaMotionNative", .serialized)
struct FigmaMotionNativeTests {
    private func panel() throws -> BrowserPanel {
        let pane = BrowserPanel(workspaceId: UUID(), initialURL: nil, renderInitialNavigation: false, chromeVisibility: .hidden)
        pane.publishObservedDocumentURL(try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/design/KEY/slug")!, node: "12-2", motion: true).url)
        return pane
    }
    @Test func handlerRejectsSubframeAndForeignMainFrameReports() throws {
        let p = try panel(); defer { p.close() }
        let body = ["state": "playing"]
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: false, address: p.currentURL, body: body)
        #expect(p.figmaMotionState == .still, "subframe report must be rejected")
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: URL(string: "https://example.com")!, body: body)
        #expect(p.figmaMotionState == .still)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: body)
        #expect(p.figmaMotionState == .playing, "own main-frame report must update the shared state")
    }
    @Test func previewRoleInstallsClockAtDocumentStartInEveryFrameAndRebindingDoesNotDuplicate() throws {
        let p = try panel(); defer { p.close() }
        p.installFigmaMotionBridge(on: p.webView, address: URL(string: "https://example.com"))
        #expect(!p.webView.configuration.userContentController.userScripts.contains { $0.source == FigmaMotion.clockScript })
        p.bindWebView(try #require(p.webView as? CmuxWebView))
        p.bindWebView(try #require(p.webView as? CmuxWebView))
        let scripts = p.webView.configuration.userContentController.userScripts.filter { $0.source == FigmaMotion.clockScript }
        #expect(scripts.count == 1, "binding a preview must install its clock once")
        #expect(scripts.first?.injectionTime == .atDocumentStart && scripts.first?.isForMainFrameOnly == false)
    }
    @Test func editorNeverCarriesPreviewClock() throws {
        let p = try panel(); defer { p.close() }
        p.installFigmaMotionBridge(on: p.webView, address: p.currentURL)
        try #require(p.switchFigmaPreviewAndEditor())
        #expect(!p.webView.configuration.userContentController.userScripts.contains { $0.source == FigmaMotion.clockScript }, "editor must have its own real clock")
    }
    @Test func restoredRequestFunnelInstallsPreviewClock() throws {
        let p = try panel(); defer { p.close() }
        _ = p.navigateWithoutInsecureHTTPPrompt(request: URLRequest(url: try #require(p.currentURL)), recordTypedNavigation: false, trustedInternalNavigation: true)
        #expect(p.webView.configuration.userContentController.userScripts.contains { $0.source == FigmaMotion.clockScript }, "request funnel must install clock before loading")
    }

    private func seed(_ p: BrowserPanel) async throws {
        let address = try #require(p.currentURL)
        p.installFigmaMotionBridge(on: p.webView, address: address)
        let previous = p.webView.navigationDelegate
        p.webView.navigationDelegate = nil // Seed a controlled document; production navigation policy is tested separately.
        defer { p.webView.navigationDelegate = previous }
        _ = p.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<html><body>fixture</body></html>")
        for _ in 0..<150 {
            if !p.webView.isLoading, p.webView.url == address,
               (try? await p.webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                p.publishObservedDocumentURL(address)
                _ = try await p.webView.evaluateJavaScript("window.commands=[]; window.__cmuxMotion={command:function(a){commands.push(a); return {state:a==='still'?'still':a==='freeze'?'paused':'playing'}}, snapshot:function(){return {state:'paused'}}};")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaMotionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture did not load within 3 seconds; url=\(String(describing: p.webView.url)) loading=\(p.webView.isLoading)"])
    }
    private func delivered(_ p: BrowserPanel, action: String) async throws {
        for _ in 0..<100 {
            if (try? await p.webView.evaluateJavaScript("commands[commands.length-1]")) as? String == action { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaMotionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "shared motion action did not deliver \(action) within 2 seconds"])
    }
    @Test func visibilityLeaveDeliversFreezeWithoutNavigating() async throws {
        let p = try panel(); defer { p.close() }; try await seed(p)
        p.figmaMotionState = .playing
        let view = p.webView
        p.noteWebViewVisibility(true, reason: "fixture")
        p.noteWebViewVisibility(false, reason: "fixture leave")
        try await delivered(p, action: "freeze")
        #expect(p.webView === view)
    }
    @Test func pillHandlerDeliversSharedToggleAndStill() async throws {
        let p = try panel(); defer { p.close() }; try await seed(p)
        p.figmaMotionState = .frozen
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "toggle"])
        try await delivered(p, action: "toggle")
        #expect(p.figmaMotionState == .playing)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "still"])
        try await delivered(p, action: "still")
    }
    @Test func loadingRejectsNativeToggleAndStill() throws {
        let p = try panel(); defer { p.close() }; p.figmaMotionState = .loading
        #expect(!p.toggleFigmaMotion(), "Loading must reject the key/palette toggle")
        var completed: Bool?
        p.showFigmaStill { completed = $0 }
        #expect(completed == false, "Loading must reject the key/palette still action")
    }

    private func actionFixture() throws -> (TabManager, Workspace, BrowserPanel) {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedPanelId)
        let address = try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/design/KEY/slug")!, node: "12-2", motion: true).url
        let p = try #require(workspace.newBrowserSplit(from: terminal, orientation: .horizontal, url: address, focus: false, chromeVisibility: .hidden, websiteDataStore: .nonPersistent()))
        workspace.focusPanel(terminal)
        return (manager, workspace, p)
    }
    @Test func paletteHandlersDeliverBothSharedActions() async throws {
        let (manager, workspace, p) = try actionFixture(); defer { workspace.teardownAllPanels() }
        try await seed(p); p.figmaMotionState = .frozen
        manager.selectedTabId = workspace.id
        workspace.setPortalRenderingEnabled(true, reason: "cm37 palette fixture")
        workspace.focusPanel(p.id)
        try #require(workspace.figmaMotionTarget() === p, "palette fixture has no visible Figma target; url=\(String(describing: p.currentURL)) omni=\(p.isOmnibarVisible) portal=\(workspace.isPortalRenderingEnabled)")
        var registry = CommandPaletteHandlerRegistry()
        ContentView.registerFigmaMotionPaletteHandler(&registry, tabManager: manager)
        let toggle = try #require(registry.handler(for: "palette.toggleFigmaMotion"))
        toggle()
        try await delivered(p, action: "toggle")
        let still = try #require(registry.handler(for: "palette.showFigmaStill"))
        still()
        try await delivered(p, action: "still")
    }
    @Test func configuredKeysDeliverBothSharedActions() async throws {
        _ = NSApplication.shared
        let priorDelegate = AppDelegate.shared, delegate = AppDelegate()
        AppDelegate.shared = delegate
        let (manager, workspace, p) = try actionFixture()
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: manager)
        delegate.tabManager = manager
        let actions: [KeyboardShortcutSettings.Action] = [.toggleFigmaMotion, .showFigmaStill]
        let bindings = actions.map { UserDefaults.standard.object(forKey: $0.defaultsKey) }
        let priorFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cm37-motion-keys")
        defer {
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            delegate.tabManager = nil; AppDelegate.shared = priorDelegate
            KeyboardShortcutSettings.settingsFileStore = priorFileStore
            for (action, prior) in zip(actions, bindings) {
                if let prior { UserDefaults.standard.set(prior, forKey: action.defaultsKey) }
                else { UserDefaults.standard.removeObject(forKey: action.defaultsKey) }
            }
            workspace.teardownAllPanels()
        }
        try await seed(p); p.figmaMotionState = .frozen
        manager.selectedTabId = workspace.id
        workspace.setPortalRenderingEnabled(true, reason: "cm37 key fixture")
        workspace.focusPanel(p.id)
        try #require(workspace.figmaMotionTarget() === p, "key fixture has no visible Figma target; url=\(String(describing: p.currentURL)) omni=\(p.isOmnibarVisible) portal=\(workspace.isPortalRenderingEnabled)")
        for (action, key, command) in [(actions[0], "m", "toggle"), (actions[1], "s", "still")] {
            let binding = StoredShortcut(key: key, command: true, shift: true, option: true, control: false)
            KeyboardShortcutSettings.setShortcut(binding, for: action)
            let keyCode = try #require(binding.firstStroke.resolvedKeyCode())
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: binding.modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: keyCode
            ))
            #expect(delegate.handleConfiguredShortcutKeyEquivalent(event))
            try await delivered(p, action: command)
        }
    }

    @Test func reportedMotionStateInvalidatesTheLivePaletteOwner() throws {
        let (manager, workspace, p) = try actionFixture(); defer { workspace.teardownAllPanels() }
        var updates = 0
        let subscription = manager.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["state": "frozen"])
        #expect(updates > 0, "motion reports must invalidate the live palette owner after the header control is removed")
    }

    @Test func installedHandlerAcceptsOwnMainFrameAndRejectsOwnPageInASubframe() async throws {
        let p = try panel(); defer { p.close() }
        let base = URL(string: "cmux-motion-test://cmux/figma-embed.html")!
        let address = try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/design/KEY/slug")!, node: "12-2", wrapper: base).url
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MotionPageFixture(), forURLScheme: "cmux-motion-test")
        let view = CmuxWebView(frame: .zero, configuration: config)
        p.webView = view; p.figmaPageWrapper = base; p.publishObservedDocumentURL(address)
        p.bindWebView(view)
        view.navigationDelegate = nil
        view.load(URLRequest(url: address))
        var finished = false
        for _ in 0..<150 {
            if (try? await view.evaluateJavaScript("window.childFinished === true")) as? Bool == true { finished = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(finished, "own-page child fixture did not report within 3 seconds")
        #expect(p.figmaMotionState == .frozen, "installed handler must accept the main-frame report and reject the own-page subframe report")
    }

    private final class MotionPageFixture: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let child = url.query?.contains("child=1") == true
            let html = child ? """
            <script>window.webkit.messageHandlers.cmuxFigmaMotion.postMessage({state:'playing'}); parent.postMessage('child-finished','*');</script>
            """ : """
            <body><script>
            window.childFinished=false;
            window.addEventListener('message',function(e){if(e.data==='child-finished')window.childFinished=true});
            window.webkit.messageHandlers.cmuxFigmaMotion.postMessage({state:'frozen'});
            var f=document.createElement('iframe');f.src=location.href+'&child=1';document.body.appendChild(f);
            </script></body>
            """
            let data = Data(html.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    @Test func paletteAndKeysAreDisabledWhileLoading() throws {
        var context = CommandPaletteContextSnapshot()
        let p = try panel(); defer { p.close() }; p.figmaMotionState = .loading
        ContentView.populateFigmaMotionContext(&context, target: p)
        #expect(ContentView.figmaMotionCommandContribution().when(context))
        #expect(!ContentView.figmaMotionCommandContribution().enablement(context), "Loading disables palette toggle")
        #expect(!ContentView.figmaShowStillCommandContribution().enablement(context), "Loading disables palette Show Still")
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.showFigmaStill") == .showFigmaStill)
    }
}
