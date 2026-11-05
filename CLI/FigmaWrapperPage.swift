import Foundation

/// The short page that holds a Figma embed in an `<iframe>`.
///
/// **Why cmux ships a page at all.** Embed Kit needs frame context: measured
/// 2026-09-07, the embed URL loaded top-level redirects through
/// `www.figma.com/embed/interstitial` into the full editor, so the "clean read"
/// surface only exists inside a frame. That is a Figma fact rather than a
/// chrome-free-pane fact, which is why the wrapper belongs to `cm-73.1` and not
/// to `cm-73.4`'s generic flag.
///
/// **Why it reads its own query string** rather than being generated per open:
/// the pane's URL is the file binding, so everything `goto` and a restart need
/// has to be *in* that URL. Making the page static and the URL carry the
/// payload gets both — one page, no per-pane temp files to clean up, and a
/// binding that survives a restart. Since `cm-73.40` the app loads these bytes with
/// `loadSimulatedRequest` at `https://www.figma.com/cmux-preview/figma-embed.html` (`cm-73.39` served them under
/// `cmux-figma://cmux/figma-embed.html`, a handler the app still keeps for old addresses); nothing writes it to disk.
enum FigmaWrapperPage {

    /// The two decisions the page makes about the address it frames, as plain
    /// functions so a test can run them in JavaScriptCore. The page has no DOM
    /// to fake: the functions take a string and return a string.
    static let addressScript = #"""
    function cmuxFramableAddress(raw) {
      return /^https:\/\/embed\.figma\.com(?:[\/?#]|$)/i.test(raw || '') ? raw : null;
    }
    function cmuxThemedAddress(address, dark) {
      var hash = address.indexOf('#');
      if (hash >= 0) { address = address.slice(0, hash); }
      var mark = address.indexOf('?');
      var base = mark >= 0 ? address.slice(0, mark) : address;
      var kept = (mark >= 0 ? address.slice(mark + 1) : '').split('&').filter(function (pair) {
        return pair !== '' && pair.split('=')[0] !== 'theme';
      });
      kept.push('theme=' + (dark ? 'dark' : 'light'));
      return base + '?' + kept.join('&');
    }
    """#

    /// The page itself. Deliberately tiny: cmux adds no loading state, because
    /// Figma's embed paints its own skeleton (grey placeholders, blue progress
    /// bar) and would only be hidden behind a second one.
    ///
    /// **It frames Figma's read-view address (or prototype view when playing motion)**, and it picks
    /// light or dark from the pane each time it loads, so no flag and no
    /// address parameter carries the theme. The background is the one thing
    /// cmux must paint: it is the instant before the iframe starts drawing, and
    /// Figma's skeleton follows the theme.
    static let html = """
    <!doctype html>
    <meta charset="utf-8">
    <title>Figma</title>
    <style>
      html, body { margin: 0; height: 100%; background: #ffffff; }
      @media (prefers-color-scheme: dark) { html, body { background: #1e1e1e; } }
      iframe { border: 0; display: block; width: 100%; height: 100%; }
    </style>
    <script>
    \(addressScript)
    \(FigmaPlayScript.script) // cmux-rbf (#cm-73.37)
    </script>
    <script>
      (function () {
        var params = new URLSearchParams(location.search);
        var dark = matchMedia('(prefers-color-scheme: dark)').matches;
        var src = cmuxFramableAddress(params.get('embed'));
        if (!src) { return; }
        var frame = document.createElement('iframe');
        frame.setAttribute('allowfullscreen', '');
        // cmux-rbf (#cm-73.37): a marked frame opens directly in the frozen player.
        if (params.get('motion') === '1' && /^https:\\/\\/embed\\.figma\\.com\\/(design|file|proto)\\//i.test(src)) {
          frame.name = 'cmux-freeze';
          src = cmuxProtoAddress(src, 'e5e5e5');
        }
        frame.src = cmuxThemedAddress(src, dark);
        var attach = function () { document.body.appendChild(frame); };
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', attach);
        } else {
          attach();
        }
      })();
    </script>
    """
}
