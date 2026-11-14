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

    /// Shared by the frame and cmux's page. A complete ASCII node is the only value allowed into an address.
    static let nodeScript = #"""
    function cmuxFigmaNode(node) {
      if (typeof node !== 'string') return null;
      var match = /^[0-9]+[:-][0-9]+$/.exec(node);
      return match && match[0] === node ? node.replace(':', '-') : null;
    }
    function cmuxAddressWithNode(address, node) {
      var hash = address.indexOf('#'), suffix = hash < 0 ? '' : address.slice(hash);
      if (hash >= 0) address = address.slice(0, hash);
      var mark = address.indexOf('?'), base = mark < 0 ? address : address.slice(0, mark);
      var query = new URLSearchParams(mark < 0 ? '' : address.slice(mark + 1));
      query.set('node-id', node);
      return base + '?' + query.toString() + suffix;
    }
    """#

    // Installed only in a preview web view, including its retained/replacement views.
    // Login and interstitial documents keep the real clock.
    static let clockScript = FigmaPlayScript.script + FigmaPlayScript.stillAddressScript + fitKeyScript + nodeScript + #"""
    (function () {
      if (window === window.parent || !/(^|\.)figma\.com$/i.test(location.hostname)) return;
      // cmux-rbf (#cm-73.40): under .40 the preview's top is https://www.figma.com too, so check
      // pathname starts with /cmux-preview/. When top is Figma's own (editor), its frames get nothing.
      // One of three copies of the page's address: also CLI/FigmaPaneURL.swift and CmuxSettings' BrowserURLAllowlistPolicy.
      // Under another site's page (a plain browser pane on a site that embeds Figma) reading the top's path throws SecurityError.
      var topPath = '';
      try { topPath = (window.top && window.top.location && window.top.location.pathname) || ''; } catch (e) {}
      if (topPath.indexOf('/cmux-preview/') !== 0) return;
      var player = location.pathname.indexOf('/proto/') === 0;
      // cmux-rbf (#cm-73.46, #cm-73.44): which document this is. A back-forward restore keeps it; a re-fit's redraw is a new one.
      var doc = performance.timeOrigin;
      // cmux-rbf (#cm-73.46): a still board reports drawn too, so a re-fit knows when Figma has painted.
      var board = /^\/(design|file)\//.test(location.pathname);
      // cmux-rbf (#cm-73.44, #cm-73.40): cmux's page is the only window this frame takes commands from.
      var parentOrigin = (location.ancestorOrigins && location.ancestorOrigins[0]) || '';
      var up = parentOrigin === 'https://www.figma.com' ? parentOrigin : '*';
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
      // cmux-rbf (#cm-73.41): turn a preview wheel move into one drag, entirely inside Figma's frame.
      var panTarget = null, panFromControl = false, panX = 0, panY = 0, panAxis = 'free', panSteps = 0, panTimer = null;
      function panInput(phase, buttons) {
        var init = { pointerId: 1, pointerType: 'mouse', isPrimary: true,
          button: phase === 'move' ? -1 : 0, buttons: buttons, clientX: panX, clientY: panY,
          bubbles: true, cancelable: true, composed: true };
        panTarget.dispatchEvent(new PointerEvent('pointer' + phase, init));
        panTarget.dispatchEvent(new MouseEvent('mouse' + phase, init));
      }
      function endPan() {
        if (panTimer !== null) { clearTimeout(panTimer); panTimer = null; }
        if (!panTarget) return;
        if (!panTarget.isConnected) panTarget = document.elementFromPoint(panX, panY) || document.documentElement;
        panInput('up', 0);
        window.parent.postMessage({ cmuxPanReport: true, phase: 'end', steps: panSteps }, up);
        panTarget = null; panFromControl = false; panAxis = 'free'; panSteps = 0;
      }
      window.addEventListener('wheel', function (e) {
        if (e.buttons !== 0 || mouseHeld) return; // cmux-rbf (#cm-73.41): never send our pointer release into a real drag.
        if (player || !board || !drawn) return;
        // A zoom step may be a momentum tail: release our pointer before leaving it to Figma.
        if (e.ctrlKey || e.metaKey || e.deltaMode === 2) { endPan(); return; }
        e.preventDefault();
        if (panFromControl) e.stopImmediatePropagation();
        var scale = e.deltaMode === 1 ? 16 : 1;
        var dx = e.deltaX * scale, dy = e.deltaY * scale;
        if (!e.shiftKey) panAxis = 'free';
        else if (panAxis === 'free' && (dx !== 0 || dy !== 0)) panAxis = Math.abs(dx) >= Math.abs(dy) ? 'across' : 'down';
        if (panAxis === 'across') dy = 0;
        if (panAxis === 'down') dx = 0;
        if (!panTarget) {
          if (dx === 0 && dy === 0) return;
          panTarget = document.elementFromPoint(e.clientX, e.clientY);
          // A drag on a control never starts Figma's canvas pan; its original wheel can then pan by Figma's own amount.
          if (panTarget && panTarget.tagName !== 'CANVAS') {
            e.stopImmediatePropagation();
            panTarget = document.querySelector('canvas');
            panFromControl = !!panTarget;
          }
          if (!panTarget) return;
          panX = e.clientX; panY = e.clientY; panSteps = 0;
          panInput('down', 1);
          window.parent.postMessage({ cmuxPanReport: true, phase: 'start', axis: panAxis, dx: dx, dy: dy }, up);
        }
        panX -= dx; panY -= dy; panSteps++;
        panInput('move', 1);
        if (panTimer !== null) clearTimeout(panTimer);
        panTimer = setTimeout(endPan, 150);
      }, { capture: true, passive: false });
      // cmux-rbf (#cm-73.41): constrain Figma's own mouse drag; untrusted copies pass through unchanged.
      var mouseHeld = false, mouseAxis = null, mouseLastX = 0, mouseLastY = 0;
      var mouseLastScreenX = 0, mouseLastScreenY = 0, mouseHeldScreenX = 0, mouseHeldScreenY = 0;
      var mouseHeldX = 0, mouseHeldY = 0, mouseSteps = 0, pendingMouseRelease = null;
      function mouseInputEvent(e) { return e.isTrusted && !player && board && drawn; }
      function endMouseLock() {
        if (mouseAxis) window.parent.postMessage({ cmuxPanReport: true, phase: 'end', steps: mouseSteps }, up);
        mouseAxis = null; mouseSteps = 0;
      }
      function copyMouseInput(e, axis, heldX, heldY, heldScreenX, heldScreenY) {
        e.stopImmediatePropagation(); e.preventDefault();
        // EventInit reads through the real event's getters, including inherited/non-enumerable fields.
        // Bind those getters to the real event so native DOM brand checks still hold.
        var init = new Proxy(e, { get: function (real, key) {
          if (key === 'clientX') return axis === 'down' ? heldX : real.clientX;
          if (key === 'clientY') return axis === 'across' ? heldY : real.clientY;
          if (key === 'screenX') return axis === 'down' ? heldScreenX : real.screenX;
          if (key === 'screenY') return axis === 'across' ? heldScreenY : real.screenY;
          if (key === 'movementX') return axis === 'down' ? 0 : real.movementX;
          if (key === 'movementY') return axis === 'across' ? 0 : real.movementY;
          return Reflect.get(real, key, real);
        }});
        var EventType = e.type.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
        e.target.dispatchEvent(new EventType(e.type, init));
      }
      function beginMouse(e) {
        if (!mouseInputEvent(e)) return;
        if (e.button !== 0 && (e.buttons & 1)) return;
        if (e.type === 'pointerdown') endPan();
        endMouseLock(); pendingMouseRelease = null;
        mouseHeld = e.button === 0; mouseLastX = e.clientX; mouseLastY = e.clientY;
        mouseLastScreenX = e.screenX; mouseLastScreenY = e.screenY;
      }
      function moveMouse(e) {
        if (!mouseInputEvent(e) || !mouseHeld) return;
        if (!(e.buttons & 1) || !e.shiftKey || e.metaKey || e.ctrlKey) {
          endMouseLock(); mouseLastX = e.clientX; mouseLastY = e.clientY;
          mouseLastScreenX = e.screenX; mouseLastScreenY = e.screenY;
          if (!(e.buttons & 1)) mouseHeld = false;
          return;
        }
        if (!mouseAxis) {
          var dx = e.clientX - mouseLastX, dy = e.clientY - mouseLastY;
          if (dx === 0 && dy === 0) return;
          mouseAxis = Math.abs(dx) >= Math.abs(dy) ? 'across' : 'down';
          mouseHeldX = mouseLastX; mouseHeldY = mouseLastY; mouseSteps = 0;
          mouseHeldScreenX = mouseLastScreenX; mouseHeldScreenY = mouseLastScreenY;
          window.parent.postMessage({ cmuxPanReport: true, phase: 'start', axis: 'mouse-' + mouseAxis, dx: dx, dy: dy }, up);
        }
        copyMouseInput(e, mouseAxis, mouseHeldX, mouseHeldY, mouseHeldScreenX, mouseHeldScreenY);
        if (e.type === 'pointermove') mouseSteps++;
        mouseLastX = e.clientX; mouseLastY = e.clientY;
        mouseLastScreenX = e.screenX; mouseLastScreenY = e.screenY;
      }
      function releaseMouse(e) {
        if (!mouseInputEvent(e) || e.button !== 0) return;
        if (e.type === 'mouseup' && pendingMouseRelease) {
          copyMouseInput(e, pendingMouseRelease.axis, pendingMouseRelease.x, pendingMouseRelease.y, pendingMouseRelease.screenX, pendingMouseRelease.screenY);
          pendingMouseRelease = null; mouseHeld = false; return;
        }
        if (mouseAxis) {
          copyMouseInput(e, mouseAxis, mouseHeldX, mouseHeldY, mouseHeldScreenX, mouseHeldScreenY);
          if (e.type === 'pointerup') pendingMouseRelease = { axis: mouseAxis, x: mouseHeldX, y: mouseHeldY,
            screenX: mouseHeldScreenX, screenY: mouseHeldScreenY };
          endMouseLock();
        }
        mouseHeld = false;
      }
      ['pointerdown', 'mousedown'].forEach(function (type) { window.addEventListener(type, beginMouse, true); });
      ['pointermove', 'mousemove'].forEach(function (type) { window.addEventListener(type, moveMouse, true); });
      ['pointerup', 'mouseup'].forEach(function (type) { window.addEventListener(type, releaseMouse, true); });
      window.addEventListener('pointercancel', function (e) {
        if (!mouseInputEvent(e)) return;
        endMouseLock(); mouseHeld = false; pendingMouseRelease = null;
      }, true);
      // WebKit caches the preview page before cmux's freeze message reaches this frame
      // (Scenario 234, 2026-10-29), so the frame holds its clock from its own pagehide.
      window.addEventListener('pagehide', function () { endPan(); clock('freeze'); }); // cmux-rbf (#cm-73.41): never leave a pointer held.
      window.addEventListener('message', function (e) {
        // Child clock reports and fit requests travel through their own parent, never an arbitrary window.
        // cmux-rbf (#cm-73.44): the forwarded copy carries nested: true, set here on the copy so a child can't remove it.
        if (e.data && (e.data.cmuxClockReport === true || e.data.cmuxKey === 'fit' || e.data.cmuxPanReport === true)) { // cmux-rbf (#cm-73.41)
          for (var i = 0; i < window.frames.length; i++) {
            if (e.source !== window.frames[i]) continue;
            if (e.data.cmuxKey === 'fit') { window.parent.postMessage({ cmuxKey: 'fit', nested: true }, up); return; }
            var copy = Object.assign({}, e.data); copy.nested = true;
            window.parent.postMessage(copy, e.data.cmuxPanReport === true ? up : '*'); return; // cmux-rbf (#cm-73.41)
          }
          return;
        }
        if (e.source !== window.parent) return;
        if (parentOrigin === 'https://www.figma.com' && e.origin && e.origin !== 'null' && e.origin !== parentOrigin) return;
        var data = e.data || {};
        if (!data.cmuxClockCommand) return;
        if (data.kind === 'still' || data.kind === 'player') {
          var node = data.node === undefined ? null : cmuxFigmaNode(data.node);
          if (data.node !== undefined && (data.kind !== 'still' || node === null)) return;
          endPan(); // cmux-rbf (#cm-73.41): refit also reaches this branch as kind: still.
          var target = data.kind === 'player' ? cmuxProtoAddress(location.href, 'e5e5e5') : cmuxStillAddress(location.href);
          if (node !== null) target = cmuxAddressWithNode(target, node);
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
          \(nodeScript)
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
    function command(action, node) {
      if (action === 'freeze') {
        if (kind === 'player') { mode = 'freeze'; send({ mode: mode }); }
      } else {
        if (state() === 'loading') return false;
        if (action === 'refit') {
          if (node !== undefined) {
            node = cmuxFigmaNode(node);
            if (node === null) return false;
          }
          // cmux-rbf (#cm-73.46): only a drawn, still /design/ or /file/ page redraws. The kept report goes first,
          // so this reply and the render carry no old drawn report: the next one is the redrawn document's own.
          if (kind !== 'still' || !lastReport || lastReport.drawn !== true || !/^\/(design|file)\//.test(lastReport.path || '')) return false;
          lastReport = null; drawn = false;
          if (node === undefined) send({ kind: 'still' });
          else {
            send({ kind: 'still', node: node });
            source = cmuxAddressWithNode(source, node);
            params = new URLSearchParams(location.search);
            params.set('embed', source);
            history.replaceState(history.state, '', location.pathname + '?' + params.toString() + location.hash);
          }
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
      // cmux-rbf (#cm-73.41): pan telemetry must never become the report fit reads.
      if (r.cmuxPanReport === true) { post({ panReport: r }); return; }
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

    static func commandScript(_ command: Command, node: String? = nil) -> String {
        guard let node else { return "window.__cmuxMotion && window.__cmuxMotion.command('\(command.rawValue)')" }
        guard command == .refit, let node = FigmaFit.normalizedNode(node) else { return "false" }
        return "window.__cmuxMotion && window.__cmuxMotion.command('\(command.rawValue)', '\(node)')"
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
