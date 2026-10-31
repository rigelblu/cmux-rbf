// cmux-rbf (#cm-73.37): clock control and canvas controls for a Figma preview.
import Foundation
import WebKit

enum FigmaMotionState: String {
    case loading, frozen, playing, paused, still
    var canToggle: Bool { self != .loading }
    var canShowStill: Bool { self != .loading && self != .still }
}

enum FigmaMotion {
    static let handlerName = "cmuxFigmaMotion"

    /// cmux-rbf (#cm-73.44): Figma's own fit key, `⇧1`, and where it must not be taken. Heard in
    /// Figma's frame and on cmux's page. Figma's hidden keyboard input is the canvas's key sink
    /// (probe 1), so it is not a text field; `FigmaFit.focusGuardScript` draws the same line.
    static let fitKeyScript = #"""
    function cmuxIsFitKey(e) {
      if (!e || e.repeat || e.metaKey || e.altKey || e.ctrlKey) return false;
      return e.key === '!' || (e.code === 'Digit1' && e.shiftKey === true);
    }
    function cmuxIsEditable(t) {
      if (!t) return false;
      if (t.isContentEditable) return true;
      if (t.tagName !== 'INPUT' && t.tagName !== 'TEXTAREA' && t.tagName !== 'SELECT') return false;
      return !(t.classList && t.classList.contains('focus-target'));
    }
    """#

    // Installed only in a preview web view, including its retained/replacement views.
    // Login and interstitial documents keep the real clock.
    static let clockScript = FigmaPlayScript.script + FigmaPlayScript.stillAddressScript + fitKeyScript + #"""
    (function () {
      if (window === window.parent || !/(^|\.)figma\.com$/i.test(location.hostname)) return;
      // cmux-rbf (#cm-73.44): this script is for cmux's preview only. When the top page is Figma's own (the pane shows the
      // editor), its frames get nothing from it: Figma keeps its ⇧1, and no report goes to a page that ignores it.
      var topOrigin = location.ancestorOrigins && location.ancestorOrigins.length
        ? location.ancestorOrigins[location.ancestorOrigins.length - 1] : '';
      if (/^https:\/\/([^\/]+\.)?figma\.com$/i.test(topOrigin)) return;
      var player = location.pathname.indexOf('/proto/') === 0;
      // cmux-rbf (#cm-73.46, #cm-73.44): which document this is. A back-forward restore keeps it; a re-fit's redraw is a new one.
      var doc = performance.timeOrigin;
      // cmux-rbf (#cm-73.46): a still board reports drawn too, so a re-fit knows when Figma has painted.
      var board = /^\/(design|file)\//.test(location.pathname);
      // cmux-rbf (#cm-73.44): cmux's page is the only window this frame takes commands from. The origin
      // is checked too when WebKit gives one for the custom scheme; if it doesn't, the source check stands alone.
      var parentOrigin = (location.ancestorOrigins && location.ancestorOrigins[0]) || '';
      var up = parentOrigin === 'cmux-figma://cmux' ? parentOrigin : '*';
      var drawn = false;
      var frozen = player && window.name === 'cmux-freeze';
      var perf = performance.now.bind(performance), date = Date.now.bind(Date);
      var perfOffset = 0, dateOffset = 0;
      var perfHeld = perf(), dateHeld = date();
      if (player) {
        Object.defineProperty(performance, 'now', { configurable: true, value: function () {
          return frozen ? perfHeld - perfOffset : perf() - perfOffset;
        }});
        Date.now = function () { return frozen ? dateHeld - dateOffset : date() - dateOffset; };
      }
      function report() {
        window.parent.postMessage({ cmuxClockReport: true, player: player, drawn: drawn, doc: doc,
          mode: frozen ? 'freeze' : 'run', hostname: location.hostname, path: location.pathname,
          offsetMs: dateOffset + (frozen ? date() - dateHeld : 0) }, '*');
      }
      function clock(mode) {
        if (!player || (mode !== 'freeze' && mode !== 'run')) return;
        if (mode === 'freeze' && !frozen) { perfHeld = perf(); dateHeld = date(); frozen = true; }
        if (mode === 'run' && frozen) {
          perfOffset += perf() - perfHeld; dateOffset += date() - dateHeld; frozen = false;
        }
      }
      // WebKit caches the preview page before cmux's freeze message reaches this frame
      // (Scenario 234, 2026-10-29), so the frame holds its clock from its own pagehide.
      window.addEventListener('pagehide', function () { clock('freeze'); });
      window.addEventListener('message', function (e) {
        // Child clock reports and fit requests travel through their own parent, never an arbitrary window.
        // cmux-rbf (#cm-73.44): the forwarded copy carries nested: true, set here on the copy so a child can't remove it.
        if (e.data && (e.data.cmuxClockReport === true || e.data.cmuxKey === 'fit')) {
          for (var i = 0; i < window.frames.length; i++) {
            if (e.source !== window.frames[i]) continue;
            if (e.data.cmuxKey === 'fit') { window.parent.postMessage({ cmuxKey: 'fit', nested: true }, up); return; }
            var copy = Object.assign({}, e.data); copy.nested = true;
            window.parent.postMessage(copy, '*'); return;
          }
          return;
        }
        if (e.source !== window.parent) return;
        if (parentOrigin === 'cmux-figma://cmux' && e.origin && e.origin !== 'null' && e.origin !== parentOrigin) return;
        var data = e.data || {};
        if (!data.cmuxClockCommand) return;
        if (data.kind === 'still' || data.kind === 'player') {
          var target = data.kind === 'player' ? cmuxProtoAddress(location.href, 'e5e5e5') : cmuxStillAddress(location.href);
          target = target.replace(/^https:\/\/[^/]+/i, 'https://www.figma.com');
          window.name = data.kind === 'player' ? 'cmux-run' : 'cmux-freeze';
          location.replace(target);
          return;
        }
        clock(data.mode);
        for (var i = 0; i < window.frames.length; i++) window.frames[i].postMessage(data, '*');
        report();
      });
      // Candidate paint signal, isolated for Scenario 230's real screenshot check.
      function reportFirstDrawnFrame() {
        if (!player && !board) return;
        if (!document.querySelector('canvas')) { requestAnimationFrame(reportFirstDrawnFrame); return; }
        requestAnimationFrame(function () { drawn = true; report(); });
      }
      // cmux-rbf (#cm-73.44): ⇧1 in Figma's frame is a request to cmux, which redraws the frame; Figma never sees it.
      // In the player cmux does nothing with it (it fits itself), so a prototype keeps its own Shift+1 key trigger.
      window.addEventListener('keydown', function (e) {
        if (player) return;
        if (!cmuxIsFitKey(e) || cmuxIsEditable(e.target)) return;
        e.preventDefault();
        window.parent.postMessage({ cmuxKey: 'fit' }, up);
      }, true);
      report();
      reportFirstDrawnFrame();
    })();
    """#

    /// Injected into cmux's served page on commit; never added to its source.
    static func pageScript(run: Bool = false) -> String {
        let labels = [
            "play": String(localized: "figma.motion.play", defaultValue: "Play motion"),
            "pause": String(localized: "figma.motion.pause", defaultValue: "Pause motion"),
            "still": String(localized: "figma.motion.showStillZoom", defaultValue: "Show still view (zoom)")
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: labels), encoding: .utf8)!
        return """
        (function () {
          if (window.__cmuxMotion) { return window.__cmuxMotion.snapshot(); }
          var labels = \(json);
          var startRunning = \(run ? "true" : "false");
          \(fitKeyScript)
          \(pageControllerScript)
        })();
        """
    }

    static let pageControllerScript = #"""
    var frame = function () { return document.querySelector('iframe'); };
    var params = new URLSearchParams(location.search);
    var marked = params.get('motion') === '1';
    var source = params.get('embed') || '';
    if (!/^https:\/\/embed\.figma\.com\/(design|file|proto)\//i.test(source)) return null;
    var kind = marked ? 'player' : 'still';
    var mode = startRunning ? 'run' : 'freeze';
    var drawn = false, hasRun = startRunning, lastReport = null, pendingKind = null;
    var pill = null, toggle = null, stop = null;
    function state() {
      if (kind === 'still') return 'still';
      if (!drawn) return 'loading';
      if (mode === 'run') return 'playing';
      return hasRun ? 'paused' : 'frozen';
    }
    function snapshot() { return { state: state(), report: lastReport }; }
    function post(body) {
      if (window.webkit && window.webkit.messageHandlers.cmuxFigmaMotion) {
        window.webkit.messageHandlers.cmuxFigmaMotion.postMessage(body);
      }
    }
    function send(command) {
      var f = frame();
      if (f && f.contentWindow) f.contentWindow.postMessage(Object.assign({ cmuxClockCommand: true }, command), '*');
    }
    function colors(address) {
      var dark = /(?:\?|&)theme=dark(?:&|$)/.test(address || '');
      return dark ? { fill: '#2C2C2C', glyph: '#FFFFFF', disabled: '#5C5C5C' }
                  : { fill: '#FFFFFF', glyph: '#1E1E1E', disabled: '#B3B3B3' };
    }
    function render() {
      var s = state(), f = frame();
      if (!pill && document.body && f) {
        pill = document.createElement('div'); pill.id = 'cmux-motion-pill';
        pill.style.cssText = 'position:fixed;z-index:2147483647;bottom:21px;left:50%;transform:translateX(-50%);display:flex;border-radius:7px;box-shadow:inset 0 0 0 1px #E6E6E6,0 1px 3px #0000001f;overflow:hidden';
        toggle = document.createElement('button'); stop = document.createElement('button');
        toggle.id = 'cmux-motion-toggle'; stop.id = 'cmux-motion-still';
        [toggle, stop].forEach(function (b) {
          b.style.cssText = 'width:32px;height:32px;padding:0;border:0;background:transparent;font:16px -apple-system;cursor:pointer';
          pill.appendChild(b);
        });
        toggle.onclick = function () { post({ action: 'toggle' }); };
        stop.onclick = function () { post({ action: 'still' }); };
        document.body.appendChild(pill);
      }
      if (pill) {
        var c = colors(f.src);
        pill.style.backgroundColor = c.fill;
        pill.style.display = marked || kind === 'player' ? 'flex' : 'none';
        toggle.textContent = s === 'playing' ? '❚❚' : '▶'; stop.textContent = '■';
        toggle.title = s === 'playing' ? labels.pause : labels.play;
        stop.title = labels.still;
        toggle.setAttribute('aria-label', toggle.title); stop.setAttribute('aria-label', stop.title);
        toggle.disabled = s === 'loading'; stop.disabled = s === 'loading' || s === 'still';
        toggle.style.color = toggle.disabled ? c.disabled : c.glyph;
        stop.style.color = stop.disabled ? c.disabled : c.glyph;
      }
      post(snapshot());
    }
    function command(action) {
      if (action === 'freeze') {
        if (kind === 'player') { mode = 'freeze'; send({ mode: mode }); }
      } else {
        if (state() === 'loading') return false;
        if (action === 'refit') {
          // cmux-rbf (#cm-73.46): only a drawn, still /design/ or /file/ page redraws. The kept report goes first,
          // so this reply and the render carry no old drawn report: the next one is the redrawn document's own.
          if (kind !== 'still' || !lastReport || lastReport.drawn !== true || !/^\/(design|file)\//.test(lastReport.path || '')) return false;
          lastReport = null; drawn = false; send({ kind: 'still' });
        } else if (action === 'still') {
          if (kind === 'still') return false;
          kind = 'still'; pendingKind = 'still'; drawn = false; mode = 'freeze'; send({ kind: 'still' });
        } else if (action === 'toggle' || action === 'play') {
          if (kind === 'still') {
            kind = 'player'; pendingKind = 'player'; drawn = false; mode = 'run'; hasRun = true; send({ kind: 'player' });
          } else { mode = action === 'play' || mode === 'freeze' ? 'run' : 'freeze'; send({ mode: mode }); }
        } else return false;
      }
      if (mode === 'run') hasRun = true;
      render(); return snapshot();
    }
    window.__cmuxMotion = { command: command, snapshot: snapshot, colors: colors };
    window.addEventListener('message', function (e) {
      var f = frame(), r = e.data;
      if (!f || e.source !== f.contentWindow || !r) return;
      // cmux-rbf (#cm-73.44): the real origin, not `hostname`, which the sender writes itself.
      if (!/^https:\/\/(www|embed)\.figma\.com$/.test(e.origin || '')) return;
      if (r.cmuxKey === 'fit') { post({ action: 'fit' }); return; }
      if (r.cmuxClockReport !== true) return;
      // A nested frame's report (the relay always tags it) is read for the player and the pending kind, never kept as the frame's.
      if (r.nested !== true) lastReport = r;
      if (pendingKind && /^\/(design|file|proto)\//.test(r.path || '')) {
        if ((pendingKind === 'player') === r.player) pendingKind = null;
        else send({ kind: pendingKind });
      }
      if (kind === 'player' && r.player === true) {
        drawn = r.drawn === true;
        if (r.mode !== mode) send({ mode: mode });
      }
      render();
    });
    window.addEventListener('keydown', function (e) {
      if (!cmuxIsFitKey(e) || cmuxIsEditable(e.target)) return;
      e.preventDefault(); post({ action: 'fit' });
    }, true);
    window.addEventListener('pagehide', function () { command('freeze'); });
    window.addEventListener('pageshow', function () { send({}); render(); });
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { send({}); render(); });
    send({}); render();
    return snapshot();
    """#

    /// The page-side commands. `commandScript` interpolates its argument into script
    /// text, so it takes this closed set and never a string from the socket, the page or the agent.
    enum Command: String, CaseIterable {
        case freeze, play, still, toggle
        // cmux-rbf (#cm-73.46): the frame redraws itself in place.
        case refit
    }

    static func commandScript(_ command: Command) -> String {
        "window.__cmuxMotion && window.__cmuxMotion.command('\(command.rawValue)')"
    }
}

@MainActor
final class FigmaMotionMessageHandler: NSObject, WKScriptMessageHandler {
    let receive: (WKWebView?, Bool, URL?, Any) -> Void
    init(receive: @escaping (WKWebView?, Bool, URL?, Any) -> Void) { self.receive = receive }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message.webView, message.frameInfo.isMainFrame, message.frameInfo.request.url, message.body)
    }
}
