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
    @Published var currentPath: String = ""

    private let itemID: UUID
    private var urlObservation: NSKeyValueObservation?

    init(provider: ChatProvider, itemID: UUID) {
        self.provider = provider
        self.itemID = itemID
        self.webView = ChatWebView.make(provider: provider)
        super.init()

        let controller = webView.configuration.userContentController
        controller.add(WeakMessageHandler(self), name: "skylight")
        controller.addUserScript(
            WKUserScript(source: Self.harvestScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        loadCache()
        urlObservation = webView.observe(\.url) { [weak self] webView, _ in
            let path = webView.url?.path() ?? ""
            Task { @MainActor [weak self] in
                self?.currentPath = path
            }
        }
    }

    // MARK: History cache (native list appears instantly on relaunch)

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight/webhistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(itemID.uuidString).json")
    }

    private struct CachedConversation: Codable {
        var path: String
        var title: String
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([CachedConversation].self, from: data) else { return }
        conversations = cached.map { WebConversation(path: $0.path, title: $0.title) }
    }

    private func saveCache() {
        let cached = conversations.map { CachedConversation(path: $0.path, title: $0.title) }
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheURL)
        }
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
        if !items.isEmpty, items != conversations {
            conversations = items
            saveCache()
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
    @Binding var showHistory: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Show your past conversations as a native list")

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

// MARK: - Web chat detail: native history column + live web conversation

/// The "intertwine" view: Skylight's own conversation list (populated from the
/// web app's DOM) sits beside the real conversation surface. The user browses
/// history in native UI; clicks navigate the embedded web app.
struct WebChatDetailView: View {
    @ObservedObject var bridge: WebChatBridge
    @State private var showHistory = true
    @State private var query = ""

    private var filtered: [WebConversation] {
        guard !query.isEmpty else { return bridge.conversations }
        return bridge.conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showHistory {
                historyColumn
                    .frame(width: 240)
                Divider()
            }
            WebViewContainer(webView: bridge.webView)
        }
        .toolbar { WebChatToolbar(bridge: bridge, showHistory: $showHistory) }
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if bridge.conversations.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    BrandIcon(provider: bridge.provider, size: 32)
                    Text("No conversations yet")
                        .font(.callout.weight(.medium))
                    Text("Log in to \(bridge.provider.displayName) on the right — your past chats appear here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isCurrent: conversation.path == bridge.currentPath
                            ) {
                                bridge.open(conversation)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConversationRow: View {
    let conversation: WebConversation
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(conversation.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isCurrent
                            ? Color.accentColor.opacity(0.18)
                            : hovering ? Color.primary.opacity(0.06) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
