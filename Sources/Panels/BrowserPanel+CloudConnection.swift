import Foundation
import WebKit

extension BrowserPanel {
    func installCloudDesktopConnectionObserver(on webView: WKWebView) {
        let isCurrent = webViewObservationValidator(for: webView)
        CloudDesktopConnectionObserver.install(on: webView) { [weak self] url, isConnected in
            guard let self, isCurrent() else { return }
            self.cloudAccess.desktopConnectionDidChange(url: url, isConnected: isConnected)
        }
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let serviceURL = cloudAccess.sessionURL(currentURL: currentURL) { return serviceURL.absoluteString }
        // cmux-rbf #cm-73.40 (code review 4, R1): never save a page address from `webView.url` in the redirect window.
        // Reject a revert of this hunk on upstream sync.
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: figmaCheckedLiveURL(of: webView)),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}
