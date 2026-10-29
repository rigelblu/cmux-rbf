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

    // Installed only in a preview web view, including its retained/replacement views.
    // Login and interstitial documents keep the real clock.
    static let clockScript = FigmaPlayScript.script + FigmaPlayScript.stillAddressScript + #"""
    (function () {
      if (window === window.parent || !/(^|\.)figma\.com$/i.test(location.hostname)) return;
      var player = location.pathname.indexOf('/proto/') === 0;
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
        window.parent.postMessage({ cmuxClockReport: true, player: player, drawn: drawn,
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
      window.addEventListener('message', function (e) {
        // Child clock reports travel through their own parent, never an arbitrary window.
        if (e.data && e.data.cmuxClockReport === true) {
          for (var i = 0; i < window.frames.length; i++) {
            if (e.source === window.frames[i]) { window.parent.postMessage(e.data, '*'); return; }
          }
          return;
        }
        if (e.source !== window.parent) return;
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
        if (!player) return;
        if (!document.querySelector('canvas')) { requestAnimationFrame(reportFirstDrawnFrame); return; }
        requestAnimationFrame(function () { drawn = true; report(); });
      }
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
        if (action === 'still') {
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
      if (!f || e.source !== f.contentWindow || !r || r.cmuxClockReport !== true) return;
      if (!/(^|\.)figma\.com$/i.test(r.hostname || '')) return;
      lastReport = r;
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
    window.addEventListener('pagehide', function () { command('freeze'); });
    window.addEventListener('pageshow', function () { send({}); render(); });
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { send({}); render(); });
    send({}); render();
    return snapshot();
    """#

    static func commandScript(_ action: String) -> String {
        "window.__cmuxMotion && window.__cmuxMotion.command('\(action)')"
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
