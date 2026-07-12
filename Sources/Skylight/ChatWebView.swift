import AppKit
import SwiftUI
import WebKit

/// Factory + navigation policy for subscription-chat web views.
///
/// The web view IS the product surface here: it loads the real claude.ai /
/// chatgpt.com apps on the user's existing subscription. Two constraints shape
/// this file:
///  - Google (and some other IdPs) refuse OAuth inside embedded web views, so
///    identity-provider navigations pop out to the default browser.
///  - Sites gate features on the browser identity, so we present Safari's UA.
@MainActor
enum ChatWebView {
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Hosts that must open in the system browser instead of the embedded view.
    static let popOutHosts: Set<String> = [
        "accounts.google.com",
        "appleid.apple.com",
        "github.com",
    ]

    private static let delegate = Delegate()

    static func make(provider: ChatProvider) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = safariUserAgent
        webView.allowsMagnification = true
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.load(URLRequest(url: provider.homeURL))
        return webView
    }

    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let host = url.host(),
               popOutHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target=_blank links: open externally rather than silently dropping them.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// Hosts an externally-owned WKWebView so the page state survives SwiftUI churn.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
