import Foundation
import WebKit

// cmux-rbf #cm-73.39: the read view's page, served from memory under a scheme cmux owns.
//
// Under the old `file://` page, macOS 27.2's WebKit gave Figma's frame no
// cookies after a granted storage-access request, so a file that needs sign-in
// looped on Log in. Under a custom scheme the grant reaches the frame. A custom
// scheme is reachable where `file://` was not, so ``FigmaPreviewPageGuard``
// keeps every route a web page can take away from it.

/// Serves ``FigmaWrapperPage/html`` for exactly `cmux-figma://cmux/figma-embed.html`,
/// whatever its query, and fails any other request on the scheme.
@MainActor
final class FigmaPreviewPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = FigmaPreviewPageSchemeHandler()

    /// What the handler answers for a request: the page as `text/html`, or nothing.
    struct Answer: Equatable {
        let body: Data
        let mimeType: String
    }

    /// The handler's whole decision, as a pure function a test can call.
    nonisolated static func answer(for url: URL?) -> Answer? {
        guard let url, FigmaPaneURL.isSamePage(url, FigmaPaneURL.previewPageURL) else { return nil }
        return Answer(body: Data(FigmaWrapperPage.html.utf8), mimeType: "text/html")
    }

    /// How many requests each web view has made to the scheme, weakly keyed. A test reads it as
    /// the positive sign that a frame did, or did not, reach the page.
    private let requestCounts = NSMapTable<WKWebView, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func requestCount(in webView: WKWebView) -> Int {
        requestCounts.object(forKey: webView)?.intValue ?? 0
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requestCounts.setObject(NSNumber(value: requestCount(in: webView) + 1), forKey: webView)
        guard let url = urlSchemeTask.request.url, let answer = Self.answer(for: url) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url,
            mimeType: answer.mimeType,
            expectedContentLength: answer.body.count,
            textEncodingName: "utf-8"
        ))
        urlSchemeTask.didReceive(answer.body)
        urlSchemeTask.didFinish()
    }

    /// The page is answered in one synchronous pass, so there is nothing to stop.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Who may put the preview page in a web view.
///
/// cmux's own loads, Back/Forward and Reload reach it; nothing a web page
/// starts does. Pure, so each entrance's decision is testable without a
/// running web view.
enum FigmaPreviewPageGuard {

    /// Whether an address is on the preview page's scheme, any host or path.
    static func isPreviewScheme(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == FigmaPaneURL.previewPageScheme
    }

    /// `BrowserNavigationDelegate.decidePolicy` for a `cmux-figma:` navigation:
    /// only in the main frame (a nil target frame is a new window, and is
    /// cancelled), and only as cmux's own trusted load, Back/Forward or Reload.
    static func allowsNavigation(
        targetFrameIsMain: Bool?,
        isTrustedLoad: Bool,
        navigationType: WKNavigationType
    ) -> Bool {
        guard targetFrameIsMain == true else { return false }
        return isTrustedLoad || navigationType == .backForward || navigationType == .reload
    }

    /// Routes a web page starts — `requestNavigation`, `createWebViewWith`,
    /// `openLinkInNewTab`, and the popup's own — refuse the scheme, and any
    /// address ``FigmaPaneURL/isWrapperPage(_:wrapper:)`` recognises, old or new:
    /// the load funnel would turn the old `file://` address into the new one
    /// and mark it trusted.
    static func refusesPageRoute(to url: URL?) -> Bool {
        guard let url else { return false }
        return isPreviewScheme(url) || FigmaPaneURL.isWrapperPage(url, wrapper: FigmaPaneURL.previewPageURL)
    }

    /// `PopupNavigationDelegate`: a popup never shows the preview.
    static func popupAllowsNavigation(to url: URL?) -> Bool {
        !isPreviewScheme(url)
    }
}

extension SessionBrowserPanelSnapshot {
    /// The same snapshot with every legacy `file://` preview address an older
    /// build saved — the current address, Back and Forward, and both sides of
    /// `figmaPages` — moved to the preview page, each query unchanged. Applied
    /// where a saved pane comes in, so restored history and WebKit agree.
    func upgradingLegacyFigmaPreviewPage() -> SessionBrowserPanelSnapshot {
        var snapshot = self
        snapshot.urlString = urlString.map(FigmaPaneURL.upgradingLegacyPage(string:))
        snapshot.backHistoryURLStrings = backHistoryURLStrings?.map(FigmaPaneURL.upgradingLegacyPage(string:))
        snapshot.forwardHistoryURLStrings = forwardHistoryURLStrings?.map(FigmaPaneURL.upgradingLegacyPage(string:))
        if var pages = figmaPages {
            pages.previewURLString = FigmaPaneURL.upgradingLegacyPage(string: pages.previewURLString)
            pages.editorURLString = FigmaPaneURL.upgradingLegacyPage(string: pages.editorURLString)
            snapshot.figmaPages = pages
        }
        return snapshot
    }
}
