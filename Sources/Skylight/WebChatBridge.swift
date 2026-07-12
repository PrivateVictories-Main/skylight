import AppKit
import SwiftUI
import WebKit

struct WebConversation: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let title: String
}

/// Owns one subscription-chat web view and "pulls parts of the web UI" into
/// native SwiftUI: it harvests the page's conversation list into native menus,
/// starts new chats, and can hide the site's own chrome (sidebar/header) so
/// only the conversation column renders inside Skylight's frame.
///
/// Everything here works on the page the user is already authorized to see —
/// reading DOM anchors and toggling CSS, the same things a user stylesheet or
/// browser extension does. No private APIs.
@MainActor
final class WebChatBridge: NSObject, ObservableObject {
    let provider: ChatProvider
    let webView: WKWebView

    @Published var conversations: [WebConversation] = []
    @Published var chromeHidden = false

    init(provider: ChatProvider) {
        self.provider = provider
        self.webView = ChatWebView.make(provider: provider)
        super.init()

        let controller = webView.configuration.userContentController
        controller.add(WeakMessageHandler(self), name: "skylight")
        controller.addUserScript(
            WKUserScript(source: Self.harvestScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    // MARK: Native actions driving the web UI

    func newChat() {
        webView.load(URLRequest(url: provider.newChatURL))
    }

    func open(_ conversation: WebConversation) {
        guard var components = URLComponents(url: provider.homeURL, resolvingAgainstBaseURL: false) else { return }
        components.path = conversation.path
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
    }

    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        let css = Self.focusCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let script = hidden
            ? """
            (() => {
              if (document.getElementById('skylight-focus')) return;
              const style = document.createElement('style');
              style.id = 'skylight-focus';
              style.textContent = `\(css)`;
              document.head.appendChild(style);
            })();
            """
            : "document.getElementById('skylight-focus')?.remove();"
        webView.evaluateJavaScript(script)
    }

    // MARK: Page-side scripts

    /// Hide site navigation so only the conversation column shows. Reversible,
    /// user-toggled, and deliberately coarse — selectors get tuned per-site as
    /// the sites evolve.
    private static let focusCSS = """
    nav, header, aside, #sidebar, [data-testid*="sidebar"] { display: none !important; }
    main { margin-left: 0 !important; }
    """

    /// Collect conversation links (claude.ai `/chat/…`, chatgpt.com `/c/…`)
    /// from the page's own sidebar and post them to native.
    private static let harvestScript = """
    (() => {
      const collect = () => {
        const seen = new Set();
        const items = [];
        for (const a of document.querySelectorAll('a[href^="/chat/"], a[href^="/c/"]')) {
          const path = a.getAttribute('href');
          const title = (a.textContent || '').trim();
          if (!path || seen.has(path) || !title) continue;
          seen.add(path);
          items.push({ path, title: title.slice(0, 80) });
          if (items.length >= 40) break;
        }
        window.webkit?.messageHandlers?.skylight?.postMessage({ kind: 'conversations', items });
      };
      collect();
      setInterval(collect, 5000);
    })();
    """

    fileprivate func handle(_ body: Any) {
        guard let dict = body as? [String: Any],
              dict["kind"] as? String == "conversations",
              let raw = dict["items"] as? [[String: Any]]
        else { return }
        let items = raw.compactMap { entry -> WebConversation? in
            guard let path = entry["path"] as? String, let title = entry["title"] as? String else { return nil }
            return WebConversation(path: path, title: title)
        }
        if items != conversations {
            conversations = items
        }
    }
}

/// Breaks the WKUserContentController → handler → web view retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: WebChatBridge?

    init(_ bridge: WebChatBridge) {
        self.bridge = bridge
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            bridge?.handle(message.body)
        }
    }
}

// MARK: - Native toolbar for web chats

struct WebChatToolbar: ToolbarContent {
    @ObservedObject var bridge: WebChatBridge

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                if bridge.conversations.isEmpty {
                    Text("No conversations found — log in first")
                } else {
                    ForEach(bridge.conversations) { conversation in
                        Button(conversation.title) { bridge.open(conversation) }
                    }
                }
            } label: {
                Label("Conversations", systemImage: "clock.arrow.circlepath")
            }
            .help("Previous chats, pulled live from the web app")

            Button {
                bridge.newChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .help("Start a new conversation")

            Toggle(isOn: Binding(
                get: { bridge.chromeHidden },
                set: { bridge.setChromeHidden($0) }
            )) {
                Label("Focus", systemImage: "rectangle.center.inset.filled")
            }
            .help("Hide the site's own sidebar and header")
        }
    }
}
