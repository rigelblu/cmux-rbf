import Foundation

/// The five-line page that holds a Figma embed in an `<iframe>`.
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
/// payload gets both — one file on disk, no per-pane temp files to clean up,
/// and a binding that survives a restart.
enum FigmaWrapperPage {

    /// The page itself. Deliberately tiny: cmux adds no loading state, because
    /// Figma's embed paints its own skeleton (grey placeholders, blue progress
    /// bar) and would only be hidden behind a second one.
    ///
    /// The background is the one thing cmux must paint. It is the instant
    /// before the iframe starts drawing, and Figma's skeleton follows the
    /// theme — so a page hardcoded to white flashes white and then goes dark.
    static let html = """
    <!doctype html>
    <meta charset="utf-8">
    <title>Figma</title>
    <style>
      html, body { margin: 0; height: 100%; background: #1e1e1e; }
      iframe { border: 0; display: block; width: 100%; height: 100%; }
    </style>
    <script>
      (function () {
        var params = new URLSearchParams(location.search);
        var light = params.get('theme') === 'light';
        document.documentElement.style.background = light ? '#ffffff' : '#1e1e1e';
        var src = params.get('embed');
        if (!src) { return; }
        var frame = document.createElement('iframe');
        frame.setAttribute('allowfullscreen', '');
        frame.src = src;
        var attach = function () { document.body.appendChild(frame); };
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', attach);
        } else {
          attach();
        }
      })();
    </script>
    """

    /// Write the page if it is missing or out of date, and return its URL.
    ///
    /// Rewritten whenever the contents differ so a stale copy cannot outlive a
    /// change to the page — it is under a kilobyte, so comparing and rewriting
    /// costs nothing worth optimising.
    @discardableResult
    static func install(at url: URL = FigmaPaneURL.wrapperFileURL()) throws -> URL {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != html else { return url }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
