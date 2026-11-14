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
        guard let url, FigmaPaneURL.isSamePage(url, FigmaPaneURL.legacyServedPageURL) else { return nil }
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
/// cmux's own marked load reaches it. WebKit's own Back/Forward reaches it, and WebKit's own Reload is
/// cancelled and redone through the panel's funnel, only on a history entry that started at a page
/// address; a web page's own move there, a new window, and a site's reload or Back that its server
/// redirects to the address are cancelled (`cm-73.40`). Pure, so each entrance's decision is testable
/// without a running web view.
enum FigmaPreviewPageGuard {

    /// Whether an address is on the preview page's scheme, any host or path.
    static func isPreviewScheme(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == FigmaPaneURL.previewPageScheme
    }

    /// What `decidePolicy` does with a navigation to cmux's page (cmux-rbf #cm-73.40).
    enum Verdict: Equatable {
        /// Not this guard's business: the rest of `decidePolicy` decides.
        case notGuarded
        /// cmux's own load, or Back/Forward on an entry that started at the page: goes on.
        case allow
        /// WebKit's own Reload of an entry that started at the page: cancelled, then the panel loads the
        /// address through its funnel.
        case reloadThroughFunnel
        /// A link, a form, a script's `location`, a new window, or a Reload or Back/Forward on an entry
        /// that started anywhere else: cancelled and recorded.
        case refuse
    }

    /// Whether an address is cmux's page, by address: the older `cmux-figma:` scheme, or the
    /// recogniser's pages (the current `https://www.figma.com` address and the older file).
    static func isPageAddress(_ url: URL, page: URL = FigmaPaneURL.previewPageURL) -> Bool {
        isPreviewScheme(url) || FigmaPaneURL.isWrapperPage(url, wrapper: page)
    }

    /// cmux-rbf #cm-73.40: the address a web view treats as cmux's preview page: its
    /// `CmuxWebView.figmaPreviewPageAddressForTesting` when a test set one, else `FigmaPaneURL.previewPageURL`.
    /// Production never sets the property, so production always gets the constant. The one place that reads the
    /// property: the funnel's trust and simulated load, `decidePolicy`'s verdict and entry check, the response note,
    /// and `BrowserPanel.figmaCheckedLiveURL(of:)` (cmux's Reload, the profile switch, Duplicate Tab, the saved address
    /// and the other live readers) all call this, so a test's stand-in page reaches every one of them.
    @MainActor
    static func pageAddress(for webView: WKWebView?) -> URL {
        (webView as? CmuxWebView)?.figmaPreviewPageAddressForTesting ?? FigmaPaneURL.previewPageURL
    }

    /// cmux-rbf #cm-73.40 (code review 2, R4): whether the history entry a Reload or Back/Forward acts on
    /// started at a page address. Pass `webView.backForwardList.currentItem?.initialURL`. A server
    /// redirect does not change an entry's start, so a site's `/x` whose reload or Back is redirected to
    /// the page address still started at `/x`. Every entry cmux's own simulated load makes starts at the
    /// page, and WebKit's Reload, Back and Forward, with the page cache on or off, and the repair after
    /// Figma's 404 keep it there (both measured in a throwaway WebKit app, code review 2's fix round).
    /// No entry (a brand-new web view) did not start at the page.
    static func entryStartedAtPage(_ initialURL: URL?, page: URL = FigmaPaneURL.previewPageURL) -> Bool {
        guard let initialURL else { return false }
        return isPageAddress(initialURL, page: page)
    }

    /// The one rule `BrowserNavigationDelegate.decidePolicy` applies to a navigation, whatever its address.
    /// A subframe of the `https` address is not guarded: Figma's server answers it with its own 404, and
    /// cmux reads only main frames. The older scheme's subframes stay refused, as in `cm-73.39`.
    /// `entryStartedAtPage` is ``entryStartedAtPage(_:)`` of the entry the navigation acts on; cmux's own
    /// marked load does not consult it. `page` is the web view's page address, `FigmaPreviewPageGuard.pageAddress(for:)`.
    static func verdict(
        for url: URL,
        targetFrameIsMain: Bool?,
        isTrustedLoad: Bool,
        navigationType: WKNavigationType,
        entryStartedAtPage: Bool,
        page: URL = FigmaPaneURL.previewPageURL
    ) -> Verdict {
        guard isPageAddress(url, page: page) else { return .notGuarded }
        if targetFrameIsMain == false, !isPreviewScheme(url) { return .notGuarded }
        guard targetFrameIsMain == true else { return .refuse }
        if navigationType == .reload {
            return isTrustedLoad || entryStartedAtPage ? .reloadThroughFunnel : .refuse // cmux-rbf #cm-73.40
        }
        if isTrustedLoad { return .allow }
        return navigationType == .backForward && entryStartedAtPage ? .allow : .refuse // cmux-rbf #cm-73.40
    }

    /// Routes a web page starts — `requestNavigation`, `createWebViewWith`,
    /// `openLinkInNewTab`, and the popup's own — refuse the scheme, and any
    /// address ``FigmaPaneURL/isWrapperPage(_:wrapper:)`` recognises, old or new:
    /// the load funnel would turn the old `file://` address into the new one
    /// and mark it trusted.
    static func refusesPageRoute(to url: URL?) -> Bool {
        guard let url else { return false }
        return isPageAddress(url)
    }

    /// `PopupNavigationDelegate`: a popup never shows the preview.
    static func popupAllowsNavigation(to url: URL?) -> Bool {
        guard let url else { return true }
        return !isPageAddress(url)
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
