import SwiftUI

/// Ask every model at once: one composer fans a prompt out to a column per
/// installed provider, each streaming its own native reply side by side.
struct CompareView: View {
    @EnvironmentObject private var state: AppState
    let item: WorkspaceItem

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var providers: [ChatProvider] {
        ChatProvider.allCases.filter { item.compareChildren?[$0.rawValue] != nil }
    }

    private var engines: [ProviderChatEngine] {
        providers.map { state.sessions.compareEngine(for: item, provider: $0) }
    }

    private var anyThinking: Bool {
        engines.contains { $0.isThinking }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(providers) { provider in
                    CompareColumn(
                        provider: provider,
                        engine: state.sessions.compareEngine(for: item, provider: provider)
                    )
                    .frame(maxWidth: .infinity)
                    if provider != providers.last {
                        Divider()
                    }
                }
            }

            // Shared composer.
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask every model…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 8)
                    .focused($focused)
                    .onSubmit(sendAll)
                    .font(.system(size: 14))
                Button(action: sendAll) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.pressable(scale: 0.86))
                .disabled(!canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1))
                    )
            )
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !anyThinking
    }

    private func sendAll() {
        guard canSend else { return }
        let prompt = draft
        draft = ""
        if item.title == nil {
            state.setTitle(ProviderChatEngine.deriveTitle(from: prompt, attachments: []), for: item.id)
        }
        for engine in engines {
            engine.send(prompt, attachments: [])
        }
    }
}

/// One provider's column: brand header + its own streaming transcript.
private struct CompareColumn: View {
    let provider: ChatProvider
    @ObservedObject var engine: ProviderChatEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                BrandIcon(provider: provider, size: 16)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if engine.isThinking {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.messages) { message in
                            MessageRow(message: message, provider: provider)
                                .id(message.id)
                        }
                        if let streaming = engine.streamingText, !streaming.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                BrandIcon(provider: provider, size: 20)
                                RichMessageText(text: streaming)
                            }
                            .id("streaming")
                        } else if engine.isThinking {
                            ThinkingRow(provider: provider).id("streaming")
                        }
                    }
                    .padding(12)
                    .font(.system(size: 12.5))
                }
                .onChange(of: engine.streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
                .onChange(of: engine.messages) {
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .overlay {
                if engine.messages.isEmpty, !engine.isThinking {
                    VStack(spacing: 8) {
                        BrandIcon(provider: provider, size: 30)
                        Text(engine.missingCLI ? "CLI not installed" : "Waiting for your prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
